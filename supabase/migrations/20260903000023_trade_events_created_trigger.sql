-- /supabase/migrations/20260903000023_trade_events_created_trigger.sql
-- =============================================================================
-- Phase 10 (clôture) — événements "created" et "published" pour trade_events.
-- =============================================================================
-- Constat : la timeline PoP (composant TradeEventsTimeline, Phase 9) était
-- incomplète. Aucun trigger ne pose l'événement initial "created" à
-- l'INSERT du trade, ni l'événement "published" au passage draft → live.
-- Conséquence : un trade créé puis publié n'a aucun event avant sa
-- première action (clôture, modif SL/TP, etc.), ce qui rend la
-- timeline PoP illisible.
--
-- Cette migration :
--   1. Ajoute 2 colonnes à trade_events : is_backfilled, metadata.
--   2. Repasse transition_trade en SECURITY DEFINER. UN SEUL delta vs
--      version actuelle en prod (corps = migration 004 + ajouts 001) :
--      `security invoker` → `security definer` + `set search_path = public`
--      (juste après `language plpgsql`). Le reste du corps — calcul du
--      leg final v_final_exit_price / v_leg_pnl, cumul realized_pnl_gross,
--      CASE exit_price, jsonb new_values avec exit_price, validation
--      croisée p_exit_price, table de transitions, commentaires internes
--      — est strictement identique au pg_get_functiondef de prod.
--      Le WHERE `id = p_trade_id and user_id = auth.uid()` protège
--      déjà contre les accès tiers en mode DEFINER : la RLS est bypassée
--      mais le prédicat SQL est évalué normalement, donc un user B ne
--      peut pas transitionner le trade de user A et reçoit le même
--      message "Trade introuvable ou non autorisé" qu'un trade
--      inexistant.
--
--      Note sourcing : le corps a été copié verbatim du pg_get_functiondef
--      de prod du 09/10/2026 (pas des fichiers 001 ou 003 du repo, qui
--      sont périmés — la dernière redéfinition vient de la migration 004
--      _realized_pnl.sql). Règle TODO_TECHNIQUE : ne JAMAIS redéfinir une
--      fonction à partir d'un fichier du repo choisi par grep — toujours
--      pg_get_functiondef de prod.
--   3. Crée 2 triggers sur trades, avec drop trigger if exists pour
--      idempotence au re-run. AFTER INSERT (event "created" + event
--      "published" si new.status <> 'draft' avec metadata.direct_insert_
--      live=true) et AFTER UPDATE WHEN old.status='draft' AND new.status=
--      'live' (event "published"). SECURITY DEFINER pour bypass RLS
--      INSERT sur trade_events. Pas de GRANT EXECUTE aux rôles standards :
--      les fonctions sont invoquées par Postgres sur DML avec les droits
--      du propriétaire (SECURITY DEFINER), pas par un rôle applicatif.
--      REVOKE par cohérence.
--   4. Backfill idempotent : event "created" pour chaque trade existant
--      (timestamp = trades.created_at), event "published" pour chaque
--      trade avec published_at NOT NULL. Marqués is_backfilled=true avec
--      metadata.source='migration_023' + original_timestamp ISO.
--   5. DROP policy INSERT sur trade_events et REVOKE des droits
--      d'écriture (INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES)
--      pour anon et authenticated. service_role garde ses pleins droits.
--      SELECT reste accordé (timeline PoP fonctionne côté client).
--
-- Dry-run : remplacer le `commit;` final par `rollback;` pour voir les
-- éventuelles erreurs sans rien appliquer.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. ALTER TABLE : colonnes is_backfilled et metadata
-- -----------------------------------------------------------------------------
alter table public.trade_events
  add column if not exists is_backfilled boolean not null default false,
  add column if not exists metadata jsonb;

comment on column public.trade_events.is_backfilled is
  'TRUE pour les events créés par le backfill migration_023, FALSE pour les events créés en temps réel par les triggers.';

comment on column public.trade_events.metadata is
  'Contexte libre de l''event (jsonb). Pour les events backfillés : {source, original_timestamp}. Pour les events "published" créés par un INSERT direct sans passer par draft : {direct_insert_live: true}. NULL pour les events natifs sans contexte particulier.';


-- -----------------------------------------------------------------------------
-- 2. transition_trade : passage en SECURITY DEFINER (UN SEUL delta)
-- -----------------------------------------------------------------------------
-- Diff vs prod (corps copié verbatim du pg_get_functiondef du 09/10/2026) :
-- uniquement `security invoker` → `security definer` + `set search_path
-- = public` ajoutées juste après `language plpgsql`. Tout le reste
-- (signature à 3 paramètres p_trade_id, p_new_status, p_exit_price,
-- returns, declare, corps complet, calcul v_final_exit_price / v_leg_pnl,
-- cumul realized_pnl_gross, CASE exit_price, jsonb new_values avec
-- exit_price, validation croisée p_exit_price, table de transitions,
-- commentaires internes) est strictement identique.
create or replace function public.transition_trade(
  p_trade_id uuid,
  p_new_status public.trade_status,
  p_exit_price numeric default null
)
returns public.trades
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trade public.trades;
  v_old_status public.trade_status;
  v_event_type public.trade_event_type;
  v_final_exit_price numeric(24,8);
  v_leg_pnl numeric(24,8);
begin
  select * into v_trade
  from public.trades
  where id = p_trade_id and user_id = auth.uid()
  for update;

  if v_trade.id is null then
    raise exception 'Trade introuvable ou non autorisé';
  end if;

  v_old_status := v_trade.status;

  if not (
    (v_old_status = 'live'        and p_new_status in ('closed', 'forgotten'))
    or (v_old_status = 'forgotten' and p_new_status in ('live', 'closed'))
    or (v_old_status = 'closed'    and p_new_status = 'archived')
  ) then
    raise exception
      'Transition non autorisée : % → % (whitepaper §04)',
      v_old_status, p_new_status;
  end if;

  v_event_type := case p_new_status
    when 'live'      then 'reactivated'::public.trade_event_type
    when 'closed'    then 'closed'::public.trade_event_type
    when 'archived'  then 'archived'::public.trade_event_type
    when 'forgotten' then 'marked_forgotten'::public.trade_event_type
  end;

  if p_exit_price is not null and p_new_status <> 'closed' then
    raise exception
      'p_exit_price ne peut être fourni que pour une clôture (new_status=closed, reçu %)',
      p_new_status;
  end if;

  -- Si on clôture, on calcule le leg final sur la quantité restante.
  -- v_final_exit_price = p_exit_price si fourni, sinon l'exit_price
  -- déjà posé (cas d'une clôture sans nouvelle saisie après une
  -- sortie partielle). Si aucun des deux n'est disponible (clôture
  -- sans exit_price du tout), v_leg_pnl reste 0 — le trade n'a pas
  -- de PnL calculable. C'est rare en pratique (l'UI force la saisie
  -- d'un exit_price à la clôture), mais on reste défensif.
  if p_new_status = 'closed' then
    v_final_exit_price := coalesce(p_exit_price, v_trade.exit_price);
    if v_final_exit_price is not null then
      v_leg_pnl := (v_final_exit_price - v_trade.entry_price)
                   * v_trade.quantity
                   * public._direction_multiplier(v_trade.direction);
    else
      v_leg_pnl := 0;
    end if;
  else
    v_leg_pnl := 0;
  end if;

  update public.trades
  set status = p_new_status,
      closed_at = case
        when p_new_status = 'closed' then now()
        else closed_at
      end,
      exit_price = case
        when p_new_status = 'closed' and p_exit_price is not null then p_exit_price
        else exit_price
      end,
      -- Cumul du leg final dans realized_pnl_gross. Si on n'est pas
      -- en train de clôturer, v_leg_pnl = 0 donc l'UPDATE est sans
      -- effet sur la colonne (cohérence : realized_pnl_gross ne
      -- change que sur les legs réalisés, pas sur les transitions
      -- qui ne sont pas des sorties).
      realized_pnl_gross = realized_pnl_gross + v_leg_pnl
  where id = p_trade_id
  returning * into v_trade;

  insert into public.trade_events
    (trade_id, user_id, event_type, old_values, new_values)
  values
    (v_trade.id, v_trade.user_id, v_event_type,
     jsonb_build_object('status', v_old_status),
     case
       when p_new_status = 'closed' and p_exit_price is not null then
         jsonb_build_object('status', p_new_status, 'exit_price', p_exit_price)
       else
         jsonb_build_object('status', p_new_status)
     end);

  return v_trade;
end $$;

-- Exécution : limiter à authenticated (seul appelant applicatif connu).
-- Le RPC transition_trade EST appelable par un client (vs les fonctions
-- de trigger qui ne le sont pas, cf. sections 3 et 4). Signature à
-- 3 paramètres : (uuid, trade_status, numeric).
revoke execute on function public.transition_trade(uuid, public.trade_status, numeric) from public, anon;
grant execute on function public.transition_trade(uuid, public.trade_status, numeric) to authenticated;


-- -----------------------------------------------------------------------------
-- 3. Trigger log_trade_created : événement "created" à l'INSERT d'un trade
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER : insère dans trade_events sans être freiné par la
-- policy INSERTION (que la migration 023 va dropper) ni par les GRANT
-- table-level. Les fonctions de trigger sont appelées par Postgres sur
-- l'événement DML avec les droits du propriétaire — pas par un rôle
-- applicatif. REVOKE EXECUTE explicite pour fermer l'accès en cas
-- d'appel manuel via .rpc() (cohérence avec mark_forgotten_trades).
--
-- Branche live (cas anormal direct INSERT) : on teste new.status <>
-- 'draft' (et non = 'live') pour couvrir tous les statuts autres que
-- draft (live, closed, forgotten, archived). Si un trade est inséré
-- directement avec un statut != 'draft' (chemin anormal qui devrait
-- être interdit par le trigger BEFORE INSERT du round 10.0), on
-- historise l'event 'published' avec metadata.direct_insert_live=true.
-- La branche sera inatteignable après le round 10.0, mais gardée
-- comme défense en profondeur.
create or replace function public.log_trade_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.trade_events
    (trade_id, user_id, event_type, is_backfilled, metadata)
  values
    (new.id, new.user_id, 'created'::public.trade_event_type, false, null);

  if new.status <> 'draft' then
    insert into public.trade_events
      (trade_id, user_id, event_type, is_backfilled, metadata)
    values
      (new.id, new.user_id, 'published'::public.trade_event_type, false,
       jsonb_build_object('direct_insert_live', true));
  end if;

  return new;
end $$;

revoke execute on function public.log_trade_created() from public, anon, authenticated;

-- drop trigger if exists pour idempotence au re-run de la migration
-- (checklist : exécution reproductible sans erreur).
drop trigger if exists trades_log_created on public.trades;

create trigger trades_log_created
  after insert on public.trades
  for each row execute function public.log_trade_created();


-- -----------------------------------------------------------------------------
-- 4. Trigger log_trade_published : événement "published" au passage draft → live
-- -----------------------------------------------------------------------------
-- WHEN old.status='draft' AND new.status='live' : garantit qu'on ne fire
-- pas pour les autres transitions (live→live partiel exit,
-- live→closed, live→forgotten, etc.). Couvre l'appel à publish_trade
-- (RPC) et tout autre chemin applicatif qui ferait un UPDATE direct
-- draft→live (console devtools, futur bypass).
create or replace function public.log_trade_published()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.trade_events
    (trade_id, user_id, event_type, is_backfilled, metadata)
  values
    (new.id, new.user_id, 'published'::public.trade_event_type, false, null);

  return new;
end $$;

revoke execute on function public.log_trade_published() from public, anon, authenticated;

-- drop trigger if exists pour idempotence au re-run de la migration.
drop trigger if exists trades_log_published on public.trades;

create trigger trades_log_published
  after update on public.trades
  for each row
  when (old.status = 'draft' and new.status = 'live')
  execute function public.log_trade_published();


-- -----------------------------------------------------------------------------
-- 5. Backfill : events "created" pour tous les trades existants
-- -----------------------------------------------------------------------------
-- Idempotent : `where not exists ... event_type = 'created'` garantit
-- qu'un re-run n'insère pas de doublons (un trade ne peut avoir qu'un
-- seul event 'created' — événement initial unique par définition).
-- Timestamp = trades.created_at pour respecter l'historique réel.
insert into public.trade_events
  (trade_id, user_id, event_type, is_backfilled, metadata, created_at)
select
  t.id, t.user_id, 'created'::public.trade_event_type, true,
  jsonb_build_object('source', 'migration_023', 'original_timestamp', t.created_at),
  t.created_at
from public.trades t
where not exists (
  select 1 from public.trade_events e
  where e.trade_id = t.id and e.event_type = 'created'
);


-- -----------------------------------------------------------------------------
-- 6. Backfill : events "published" pour les trades déjà publiés
-- -----------------------------------------------------------------------------
-- Idempotent (where not exists). Filtre t.published_at is not null :
-- un trade en draft n'a pas de published_at, rien à historiser.
insert into public.trade_events
  (trade_id, user_id, event_type, is_backfilled, metadata, created_at)
select
  t.id, t.user_id, 'published'::public.trade_event_type, true,
  jsonb_build_object('source', 'migration_023', 'original_timestamp', t.published_at),
  t.published_at
from public.trades t
where t.published_at is not null
  and not exists (
    select 1 from public.trade_events e
    where e.trade_id = t.id and e.event_type = 'published'
  );


-- -----------------------------------------------------------------------------
-- 7. DROP policy INSERT sur trade_events
-- -----------------------------------------------------------------------------
-- La policy Phase 0 "trade_events: insertion par le propriétaire du trade"
-- autorisait un client authentifié à insérer un event sur son propre
-- trade. Incompatible avec l'immutabilité PoP : un client pourrait
-- fabriquer un historique. Les events ne doivent être posés QUE par les
-- triggers (et le backfill 023). Le SELECT reste actif pour la timeline.
drop policy if exists "trade_events: insertion par le propriétaire du trade"
  on public.trade_events;


-- -----------------------------------------------------------------------------
-- 8. REVOKE des droits non-SELECT sur trade_events
-- -----------------------------------------------------------------------------
-- service_role garde ses pleins droits (utilisé par Vercel Cron, exports
-- RGPD, etc.). SELECT reste implicitement accordé (pas dans le REVOKE),
-- donc les clients authentifiés peuvent toujours lire via la timeline
-- PoP. TRUNCATE est volontairement inclus : RLS n'intercepte pas TRUNCATE.
revoke insert, update, delete, truncate, trigger, references
  on public.trade_events
  from anon, authenticated;


commit;