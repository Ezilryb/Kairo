-- /supabase/migrations/20260901000003_trade_transitions.sql
-- =============================================================================
-- Phase 2 — Point D : RPCs pour les transitions de statut de trade.
--
-- Cadrage : 3 transitions manuelles (close, archive, reactivate) + 1
-- bascule automatique (live → forgotten via job Vercel Cron, 5 jours
-- d'inactivité). Toutes les event_types nécessaires sont déjà déclarés
-- dans l'enum `trade_event_type` (Phase 0) : 'closed', 'archived',
-- 'reactivated', 'marked_forgotten'. Pas d'enum à étendre.
--
-- Deux RPCs distincts, pas un unifié :
--
-- 1. `transition_trade(p_trade_id, p_new_status)` — SECURITY INVOKER
--    pour les actions manuelles (l'utilisateur clique sur un bouton).
--    Valide que la transition demandée fait partie de la table de
--    transitions autorisées (LIVE→CLOSED, LIVE→FORGOTTEN,
--    FORGOTTEN→LIVE, FORGOTTEN→CLOSED, CLOSED→ARCHIVED), pose
--    closed_at = now() si transition vers closed, historise dans
--    trade_events avec l'event_type correspondant. La RLS UPDATE
--    s'applique via SECURITY INVOKER, le user doit être authentifié
--    et propriétaire du trade.
--
-- 2. `mark_forgotten_trades()` — SECURITY DEFINER pour le job OUBLIÉ.
--    Bypasse la RLS (c'est un job système, pas un user authentifié),
--    fait le bulk update avec un WHERE qui matche exactement l'index
--    `trades_last_activity_idx` (filtré sur status = 'live'). Boucle
--    explicite avec `for update` pour la traçabilité ligne par ligne
--    (un event 'marked_forgotten' par trade basculé). `set search_path
--    = public` est obligatoire pour SECURITY DEFINER (bonne pratique
--    anti-hijacking).
--
-- Le calcul temporel (`now() - interval '5 days'`) se fait TOUJOURS
-- côté DB, jamais via une date calculée côté JS/TS. Même réflexe que
-- pour publish_trade (Point C/D) : si on passait `new Date() - 5j`
-- depuis le client, une horloge navigateur mal réglée produirait le
-- même genre de bug que celui qu'on vient de corriger.
--
-- Le trigger `log_sl_tp_changes` (Phase 0) fire sur tout UPDATE non-
-- draft et pose `last_activity_at := now()` automatiquement. Donc les
-- transitions manuelles (qui partent toutes de 'live' ou 'forgotten',
-- jamais de 'draft') repoussent l'activité sans qu'on ait à le faire
-- explicitement. Et la bascule OUBLIÉ elle-même fire aussi le trigger
-- (old.status = 'live'), ce qui n'a aucun impact (le trade est
-- justement en train d'être basculé parce qu'il était inactif).
--
-- GRANT EXECUTE : Postgres accorde EXECUTE à PUBLIC par défaut, le
-- rôle `authenticated` (PostgREST) peut donc appeler transition_trade
-- sans GRANT explicite. mark_forgotten_trades, en revanche, est un
-- job système appelé uniquement par Vercel Cron via la service_role
-- key — on REVOKE explicitement le droit à PUBLIC et on GRANT
-- uniquement à service_role (cf. plus bas dans cette migration).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Fix #1 (intégrité) : log_sl_tp_changes ne doit pas écraser
-- last_activity_at quand le trade bascule vers 'forgotten'.
-- -----------------------------------------------------------------------------
-- Bug identifié en revue du Point D : la version actuelle de
-- log_sl_tp_changes (migration initiale, Phase 0) pose
-- `new.last_activity_at := now()` INCONDITIONNELLEMENT, en dehors
-- du bloc `if old.status <> 'draft'`. Conséquence : quand
-- mark_forgotten_trades fait `UPDATE set status = 'forgotten'`, ce
-- trigger fire et écrase last_activity_at à l'instant présent. Le
-- trade passe bien en forgotten, mais la date de dernière activité
-- réelle (5+ jours dans le passé) est perdue — la colonne ment.
--
-- Impact : §07 du whitepaper (Analyse Psychologique Intégrée) et
-- l'AI Bias Detector (idées post-MVP) reposent sur ce genre de délai
-- réel entre inactivité et prise de conscience. Une fois le bug en
-- prod sur de vrais trades, la valeur est perdue définitivement
-- pour chaque trade traité — pas rattrapable rétroactivement.
--
-- Fix : conditionner la mise à jour de last_activity_at. Le trade
-- qui BASCULE vers forgotten est précisément un trade INACTIF, sa
-- vraie date d'inactivité est la donnée qu'on veut conserver. Tous
-- les autres UPDATE non-draft (live→live partial exit, live→closed,
-- forgotten→live, closed→archived) continuent à mettre à jour
-- last_activity_at normalement, c'est le comportement voulu.
--
-- Note : on est sur create or replace, la signature ne change pas,
-- le trigger trades_log_sl_tp_changes continue à appeler la même
-- fonction — pas de réenregistrement de trigger nécessaire.
create or replace function public.log_sl_tp_changes()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.status <> 'draft' then
    if new.stop_loss is distinct from old.stop_loss then
      insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
      values (old.id, old.user_id, 'sl_modified',
              jsonb_build_object('stop_loss', old.stop_loss),
              jsonb_build_object('stop_loss', new.stop_loss));
    end if;
    if new.take_profit is distinct from old.take_profit then
      insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
      values (old.id, old.user_id, 'tp_modified',
              jsonb_build_object('take_profit', old.take_profit),
              jsonb_build_object('take_profit', new.take_profit));
    end if;
  end if;
  -- Ne pas rafraîchir last_activity_at quand le trade BASCULE vers
  -- 'forgotten' : cette transition représente précisément l'ABSENCE
  -- d'activité (5+ jours d'inactivité) — la stamper à now() effacerait
  -- silencieusement la vraie date de dernière activité réelle, dont
  -- Phase 4 / §07 / AI Bias Detector auront besoin. Tous les autres
  -- cas (live→live partial exit, live→closed, forgotten→live,
  -- closed→archived, etc.) continuent à mettre à jour l'activité.
  if new.status <> 'forgotten' then
    new.last_activity_at := now();
  end if;
  return new;
end $$;


-- -----------------------------------------------------------------------------
-- transition_trade : transitions manuelles (close, archive, reactivate)
-- -----------------------------------------------------------------------------
-- SECURITY INVOKER : la fonction s'exécute avec les droits de l'appelant,
-- la RLS UPDATE sur trades s'applique. Le user_id dans le WHERE filtre
-- les trades d'autres users — défense en profondeur + pattern appliqué
-- partout dans le projet.
--
-- Table de transitions autorisées (cf. cadrage Phase 2 Point D + whitepaper
-- §04) :
--   - live      → closed        (clôture manuelle)
--   - live      → forgotten     (n'est PAS manuel en pratique, c'est le
--                                job qui le fait, mais on autorise au
--                                niveau SQL — l'UI n'expose pas le bouton)
--   - forgotten → live          (réactivation)
--   - forgotten → closed        (clôture depuis oublié, le user a retrouvé
--                                son trade et décide de le clôturer)
--   - closed    → archived      (archivage)
-- Tout autre couple (status, p_new_status) lève une exception explicite.
--
-- closed_at : posé automatiquement à now() si on transitionne vers
-- 'closed'. Idempotent : si on rejoue une transition vers closed,
-- closed_at sera mis à jour (de toute façon, on ne devrait pas
-- pouvoir rejouer une transition déjà faite — la table ci-dessus
-- interdit 'closed' → 'closed').
create or replace function public.transition_trade(
  p_trade_id uuid,
  p_new_status public.trade_status
)
returns public.trades
language plpgsql
security invoker
as $$
declare
  v_trade public.trades;
  v_old_status public.trade_status;
  v_event_type public.trade_event_type;
begin
  -- 1. Lock + lecture du trade. `for update` empêche une race entre
  --    deux clics simultanés sur le même bouton (rare mais possible).
  --    Le `user_id = auth.uid()` filtre les trades d'autres users,
  --    redondant avec la RLS mais explicite (défense en profondeur).
  select * into v_trade
  from public.trades
  where id = p_trade_id and user_id = auth.uid()
  for update;

  if v_trade.id is null then
    raise exception 'Trade introuvable ou non autorisé';
  end if;

  v_old_status := v_trade.status;

  -- 2. Validation de la transition. Plutôt qu'un CHECK sur la table
  --    (qui ne verrait que new.status, pas old), on valide en SQL
  --    dans le RPC — c'est l'endroit où on a accès aux deux.
  if not (
    (v_old_status = 'live'      and p_new_status in ('closed', 'forgotten'))
    or (v_old_status = 'forgotten' and p_new_status in ('live', 'closed'))
    or (v_old_status = 'closed'    and p_new_status = 'archived')
  ) then
    raise exception
      'Transition non autorisée : % → % (whitepaper §04)',
      v_old_status, p_new_status;
  end if;

  -- 3. Mapping new_status → event_type. Pas d'enum à étendre, tous
  --    les event_types sont déjà déclarés dans la migration initiale.
  v_event_type := case p_new_status
    when 'live'      then 'reactivated'::public.trade_event_type
    when 'closed'    then 'closed'::public.trade_event_type
    when 'archived'  then 'archived'::public.trade_event_type
    when 'forgotten' then 'marked_forgotten'::public.trade_event_type
  end;

  -- 4. UPDATE du trade. closed_at = now() si on transitionne vers
  --    'closed', sinon on conserve l'éventuel closed_at précédent
  --    (cas d'une réactivation oubliée, défensif).
  update public.trades
  set status = p_new_status,
      closed_at = case
        when p_new_status = 'closed' then now()
        else closed_at
      end
  where id = p_trade_id
  returning * into v_trade;

  -- 5. Historisation dans trade_events. old_values/new_values capturent
  --    uniquement le champ status (les autres champs ne changent pas
  --    lors d'une transition). `created_at` du trade_event est posé
  --    par le default now() de la table.
  insert into public.trade_events
    (trade_id, user_id, event_type, old_values, new_values)
  values
    (v_trade.id, v_trade.user_id, v_event_type,
     jsonb_build_object('status', v_old_status),
     jsonb_build_object('status', p_new_status));

  return v_trade;
end $$;


-- -----------------------------------------------------------------------------
-- mark_forgotten_trades : bascule bulk OUBLIÉ (5 jours d'inactivité)
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER : job système (Vercel Cron via service_role), bypasse
-- la RLS. `set search_path = public` est obligatoire (bonne pratique
-- SECURITY DEFINER anti-hijacking, déjà appliqué pour
-- log_sl_tp_changes, log_partial_exits, etc.).
--
-- WHERE : `status = 'live' AND last_activity_at < now() - interval '5
-- days'` — matche exactement l'index partiel `trades_last_activity_idx`
-- (filtré sur status = 'live'). Le planner utilisera l'index pour le
-- scan, ce qui est crucial quand le nombre de trades par user
-- augmentera (analytics Phase 4, etc.).
--
-- Boucle explicite avec `for update` : un UPDATE bulk avec RETURNING
-- + INSERT serait plus concis, mais la boucle permet de logger
-- chaque event individuellement et de compter le nombre exact de
-- trades affectés. Le volume attendu (trades oubliés) est faible
-- même à grande échelle — la boucle n'est pas un goulot d'étranglement.
--
-- last_activity_at : pas touché. Le trigger `log_sl_tp_changes` fire
-- sur tout UPDATE non-draft et le pose à now() automatiquement, mais
-- ici on s'en fiche — le trade vient d'être basculé précisément parce
-- qu'il était inactif, et un re-trigger de last_activity_at n'aurait
-- aucun effet de bord.
create or replace function public.mark_forgotten_trades()
returns integer  -- nombre de trades basculés, pour observabilité
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_trade record;
begin
  for v_trade in
    select id, user_id
    from public.trades
    where status = 'live'
      and last_activity_at < now() - interval '5 days'
    for update
  loop
    update public.trades
    set status = 'forgotten'
    where id = v_trade.id;

    insert into public.trade_events
      (trade_id, user_id, event_type, old_values, new_values)
    values
      (v_trade.id, v_trade.user_id, 'marked_forgotten',
       jsonb_build_object('status', 'live'),
       jsonb_build_object('status', 'forgotten'));

    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

-- -----------------------------------------------------------------------------
-- Fix #2 (contrôle d'accès) : restreindre mark_forgotten_trades au
-- service_role uniquement.
-- -----------------------------------------------------------------------------
-- Bug identifié en revue du Point D : SECURITY DEFINER + EXECUTE
-- accordé à PUBLIC par défaut = n'importe quel compte authentifié
-- peut appeler supabase.rpc('mark_forgotten_trades') depuis le
-- navigateur et déclencher le bulk update sur tous les users (la
-- RLS est bypassee par SECURITY DEFINER).
--
-- Impact réel limité (la fonction ne peut basculer que des trades
-- objectivement inactifs depuis 5+ jours, pas de faux positif
-- possible, pas de dommage réel exploitable), mais ce n'est pas
-- l'intention. Coûte 2 lignes à fermer proprement.
--
-- `transition_trade` (l'autre RPC de cette migration) garde son
-- EXECUTE par défaut — c'est voulu, n'importe quel user authentifié
-- peut transitionner SES PROPRES trades (RLS + filtre user_id
-- déjà en place).
revoke execute on function public.mark_forgotten_trades() from public;
grant execute on function public.mark_forgotten_trades() to service_role;
