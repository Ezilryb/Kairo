-- /supabase/migrations/20260903000026_cloture_avec_prix_obligatoire.sql
-- =============================================================================
-- Version finale. Migration 026.
-- Phase 10 : clôture avec prix de sortie obligatoire.
-- Trois deltas, tous relatifs au calcul et à la consultation du résultat d'un
-- trade :
--   1. transition_trade : prix de sortie strictement positif obligatoire
--      à la clôture (refuse p_exit_price IS NULL ou <= 0). Le coalesce
--      historique avec l'exit_price déjà posé est supprimé : on ne se
--      replie plus sur une valeur éventuellement obsolète issue d'une
--      sortie partielle antérieure.
--      a. ajout du bloc IF de garde en tête de la branche 'closed'
--      b. remplacement `coalesce(p_exit_price, v_trade.exit_price)`
--         par `p_exit_price` (la garde garantit > 0)
--      c. suppression de la branche `if v_final_exit_price is not null
--         then ... else v_leg_pnl := 0` (toujours non NULL après la
--         garde)
--   2. pnl_gross : un trade archivé compte. Le whitepaper §04 définit
--      l'archivage comme une simple conservation post-clôture, pas un
--      changement d'état économique. Le défaut actuel (status = 'closed'
--      only) faisait disparaître les archivés de sum_pnl, winrate,
--      profit_factor, expectancy et max_drawdown — corrigé ici, avec
--      extension aux statistiques dédiée (migration 027).
--   3. Nouvelle RPC SECURITY INVOKER public.trade_metrics(p_trade_id uuid)
--      pour exposer le résultat à un client sans dépendre de PostgREST
--      (les fonctions pnl_* prennent un composite type, inatteignable
--      via .rpc()). Point d'entrée unique pour l'UI (carte Résultat +
--      Risque), testable en pgTAP, protégé par user_id = auth.uid().
--
-- Garde de précondition : un bloc do lit pg_get_functiondef de
-- transition_trade et pnl_gross. La migration avorte (raise exception)
-- si l'état réel en prod diverge du point de départ attendu (cf. leçon
-- TODO_TECHNIQUE « pg_get_functiondef = source de vérité »).
--
-- Sémantique r_multiple (corps prod inchangé dans cette migration) :
-- montant de risque = |entry_price - stop_loss| * initial_quantity si
-- stop_loss ET initial_quantity non nuls, sinon (risk_percent/100) *
-- initial_capital si risk_percent ET initial_capital non nuls, sinon
-- NULL ; résultat = pnl_net / risque (NULL si risque nul ou absent).
-- Le stop loss prime sur risk_percent. Conséquence UI : un trade avec
-- risk_percent saisi (sans stop_loss) affiche un R-multiple, mais
-- trade_metrics.risk_pct reste NULL (risk_pct ne connaît que le stop
-- loss). C'est volontaire.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0. Garde de précondition : transition_trade = corps prod attendu
-- -----------------------------------------------------------------------------
-- La migration 026 modifie transition_trade. Elle suppose que le corps
-- actuel en prod est conforme au corps de production relevé par
-- pg_get_functiondef (SECURITY DEFINER + contient le cumul
-- realized_pnl_gross). Si ce n'est plus le cas, la migration avorte
-- plutôt que de redéfinir silencieusement sur un état inattendu.
do $precondition$
declare
  v_def text;
  v_pnl_def text;
begin
  select pg_get_functiondef(
    'public.transition_trade(uuid, public.trade_status, numeric)'::regprocedure
  ) into v_def;

  if v_def is null then
    raise exception
      '026 avortée : public.transition_trade(uuid, public.trade_status, numeric) introuvable en prod. État de base inattendu.';
  end if;

  if position('security definer' in lower(v_def)) = 0 then
    raise exception
      '026 avortée : public.transition_trade n''est pas SECURITY DEFINER. Le corps de production relevé par pg_get_functiondef ne correspond pas — revoir manuellement avant de continuer.';
  end if;

  if position('realized_pnl_gross = realized_pnl_gross + v_leg_pnl' in v_def) = 0 then
    raise exception
      '026 avortée : le corps actuel de public.transition_trade ne contient pas le cumul realized_pnl_gross = realized_pnl_gross + v_leg_pnl. Le corps réel diverge — re-fournir le pg_get_functiondef avant de continuer.';
  end if;

  -- Garde supplémentaire pour pnl_gross : état attendu : corps de
  -- production relevé par pg_get_functiondef. Si le corps a déjà été
  -- modifié, la migration avorte (raise exception ci-dessous) — le
  -- delta 026 sur pnl_gross ne s'applique pas silencieusement sur un
  -- état inattendu.
  select pg_get_functiondef(
    'public.pnl_gross(public.trades)'::regprocedure
  ) into v_pnl_def;

  if v_pnl_def is null then
    raise exception
      '026 avortée : public.pnl_gross(public.trades) introuvable en prod. État de base inattendu.';
  end if;

  if position('status = ''closed''' in v_pnl_def) = 0 then
    raise exception
      '026 avortée : le corps actuel de public.pnl_gross ne contient pas status = ''closed''. Le delta attendu (status in (''closed'', ''archived'')) ne s''applique pas sur l''état réel — revoir manuellement.';
  end if;
end $precondition$;


-- -----------------------------------------------------------------------------
-- 1. transition_trade : prix obligatoire à la clôture
-- -----------------------------------------------------------------------------
-- Diff vs corps de production relevé par pg_get_functiondef :
--   * ajout du bloc IF de garde en tête de la branche 'closed'
--     (refuse p_exit_price NULL ou <= 0)
--   * remplacement `coalesce(p_exit_price, v_trade.exit_price)` par
--     `p_exit_price` (puisque la garde garantit > 0)
--   * suppression de `if v_final_exit_price is not null then ... else
--     v_leg_pnl := 0` (toujours non NULL après la garde)
--   * corps du calcul leg simplifié en conséquence
-- Le reste (signature, lock, table de transitions, validation p_exit_price
-- sur new_status <> 'closed', UPDATE trade, EVENT jsonb, return) est
-- identique.
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

  -- 026 : prix de sortie strictement positif obligatoire à la clôture.
  -- Avant, le calcul leg se repliait sur coalesce(p_exit_price,
  -- v_trade.exit_price), ce qui masquait une saisie absente par un
  -- prix éventuellement obsolète issu d'une sortie partielle. Désormais,
  -- toute clôture doit fournir explicitement son prix de sortie ; la
  -- garde garantit > 0 et le coalesce disparaît.
  if p_new_status = 'closed' then
    if p_exit_price is null or p_exit_price <= 0 then
      raise exception
        'transition_trade refusé : un prix de sortie strictement positif est obligatoire pour clôturer un trade. Saisissez p_exit_price (numeric, > 0).';
    end if;
  end if;

  -- Si on clôture, on calcule le leg final sur la quantité restante.
  -- v_final_exit_price = p_exit_price (garanti > 0 par la garde). Le
  -- calcul utilise la `quantity` courante : les sorties partielles
  -- antérieures (record_partial_exit) ont déjà réduit `quantity` au
  -- prorata, donc cette quantité est bien la portion restante.
  if p_new_status = 'closed' then
    v_final_exit_price := p_exit_price;
    v_leg_pnl := (v_final_exit_price - v_trade.entry_price)
                 * v_trade.quantity
                 * public._direction_multiplier(v_trade.direction);
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
        when p_new_status = 'closed' then p_exit_price
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
  values (v_trade.id, v_trade.user_id, v_event_type,
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
-- Idem corps de production relevé par pg_get_functiondef : pas de
-- changement sur les droits d'exécution, déjà retirés de public/anon
-- et accordés à authenticated.
revoke execute on function public.transition_trade(uuid, public.trade_status, numeric) from public, anon;
grant execute on function public.transition_trade(uuid, public.trade_status, numeric) to authenticated;


-- -----------------------------------------------------------------------------
-- 2. pnl_gross : un trade archivé compte
-- -----------------------------------------------------------------------------
-- Corps copié verbatim du corps de production relevé par
-- pg_get_functiondef, avec un seul delta : `status = 'closed'` →
-- `status in ('closed', 'archived')`. Le reste (signature
-- `pnl_gross(p_trade public.trades) returns numeric`, LANGUAGE sql,
-- STABLE, sans SECURITY DEFINER — donc INVOKER par défaut) est
-- strictement identique. Les statistiques (sum_pnl, winrate,
-- profit_factor, expectancy, max_drawdown) seront étendues en
-- migration 027 avec les corps prod transmis à ce moment.
--
-- Droits : AUCUN changement dans cette migration. create or replace
-- conserve les GRANT existants, et authenticated garde son droit
-- explicite. Retirer anon/public casserait les appels à pnl_net,
-- rendement_pct, r_multiple, sum_pnl, winrate ou recent_trades_with_pnl
-- exécutés sans session (profil public consulté par un visiteur) :
-- ces fonctions s'exécutent avec le rôle de l'appelant et invoquent
-- pnl_gross en chaîne.
create or replace function public.pnl_gross(p_trade public.trades)
returns numeric
language sql
stable
as $$
  select case when (p_trade).status in ('closed', 'archived')
              then (p_trade).realized_pnl_gross
              else null end
$$;


-- -----------------------------------------------------------------------------
-- 3. Nouvelle RPC public.trade_metrics(p_trade_id uuid)
-- -----------------------------------------------------------------------------
-- SECURITY INVOKER : le filtre t.user_id = auth.uid() protège contre
-- l'accès tiers (un autre utilisateur authentifié reçoit zéro ligne, ce
-- qui distingue trade_metrics d'une fuite d'information). Les fonctions
-- pnl_* / rendement_pct / r_multiple sont SECURITY INVOKER ; la chaîne
-- d'appel reste INVOKER de bout en bout.
--
-- Colonnes :
--   status         : statut courant du trade (utile pour conditionner
--                    l'affichage côté client : la carte Résultat ne
--                    s'affiche que pour 'closed' ou 'archived')
--   exit_price     : prix de sortie si posé (sinon NULL — trade en cours)
--   pnl_gross      : résultat brut (realized_pnl_gross si clôturé/archivé,
--                    sinon NULL)
--   pnl_net        : pnl_gross - fees - slippage (idem)
--   rendement_pct  : pnl_net / initial_capital * 100 (idem)
--   r_multiple     : pnl_net / risque_unitaire (idem)
--   risk_pct       : |entry - stop_loss| * initial_quantity ÷
--                    initial_capital * 100, NULL si pas de stop_loss ou
--                    capital nul. Calculé inline car aucune fonction
--                    risk_pct n'existe en prod.
--   fees_known     : true si fees IS NOT NULL (saisie réelle)
--   slippage_known : true si slippage IS NOT NULL
--
-- Pas de SECURITY DEFINER (lecture filtrée par user_id suffit).
create or replace function public.trade_metrics(p_trade_id uuid)
returns table (
  status public.trade_status,
  exit_price numeric,
  pnl_gross numeric,
  pnl_net numeric,
  rendement_pct numeric,
  r_multiple numeric,
  risk_pct numeric,
  fees_known boolean,
  slippage_known boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    t.status,
    t.exit_price,
    public.pnl_gross(t),
    public.pnl_net(t),
    public.rendement_pct(t),
    public.r_multiple(t),
    case
      when t.stop_loss is null then null
      when coalesce(t.initial_capital, t.capital) is null
        or coalesce(t.initial_capital, t.capital) = 0 then null
      else
        abs(t.entry_price - t.stop_loss)
        * coalesce(t.initial_quantity, t.quantity)
        / coalesce(t.initial_capital, t.capital)
        * 100
    end,
    t.fees is not null,
    t.slippage is not null
  from public.trades t
  where t.id = p_trade_id
    and t.user_id = auth.uid()
$$;

-- Droits : retrait pour public et anon, accord à authenticated. Le
-- pattern (revoke from public,anon + grant to authenticated) est
-- documenté dans `20260903000024_restore_missing_objects.sql` pour
-- la fonction mark_forgotten_trades — même leçon appliquée ici.
revoke execute on function public.trade_metrics(uuid) from public, anon;
grant execute on function public.trade_metrics(uuid) to authenticated;


-- Recharge le cache PostgREST pour que la nouvelle RPC trade_metrics
-- soit visible de l'API sans attendre la prochaine relecture du schéma.
-- Sans ce notify, la première lecture côté site peut renvoyer
-- « function public.trade_metrics(uuid) does not exist » même après
-- un COMMIT réussi.
notify pgrst, 'reload schema';


commit;