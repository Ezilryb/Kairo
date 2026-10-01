-- /supabase/migrations/20260903000004_realized_pnl.sql
-- =============================================================================
-- Phase 3 — Calculs Financiers : fix du PnL pour les trades avec sortie(s)
-- partielle(s). Le PnL doit cumuler les legs réalisés (sorties
-- partielles + clôture), pas être recalculé sur la quantité restante
-- (qui sous-estime silencieusement les gains et peut même inverser
-- le signe d'un trade gagnant en perdant).
--
-- PROBLÈME IDENTIFIÉ EN REVUE :
-- `trades.capital` et `trades.quantity` représentent l'état RESTANT
-- après chaque sortie partielle (c'est voulu pour
-- `enforce_capital_immutability` et pour savoir combien reste
-- exposé). Mais la version précédente de `pnl_gross(trade)` les
-- utilisait comme si c'étaient les valeurs INITIALES du trade,
-- multipliées par (exit - entry). Résultat : tout PnL réalisé sur
-- une sortie partielle antérieure était perdu du calcul, et le PnL
-- final ne reflétait que la dernière tranche.
--
-- FIX : chaque sortie (partielle ou finale) accumule son propre PnL
-- réalisé dans `trades.realized_pnl_gross`, posé par
-- `record_partial_exit` et `transition_trade` au moment même de la
-- sortie (chaque RPC connaît exactement le prix et la quantité de
-- SA sortie). `pnl_gross(trade)` devient une simple lecture de cette
-- colonne pour un trade closed — plus de recalcul approximatif.
--
-- CONTENU DE CETTE MIGRATION :
--   1. Colonnes trades.initial_quantity / initial_capital (snapshot à
--      la publication, référence stable pour le risque et la taille
--      — distinct de quantity/capital qui diminuent avec les sorties
--      partielles) + trades.realized_pnl_gross (accumulateur, posé à
--      chaque sortie).
--   2. publish_trade(p_trade_id) : nouveau RPC, transition draft→live,
--      pose published_at/opened_at + snapshot initial_quantity/
--      initial_capital = quantity/capital au moment de la publication.
--   3. record_partial_exit étendu : calcule le PnL de LA sortie
--      partielle (pas du trade entier) et l'ajoute à
--      realized_pnl_gross, en plus de réduire quantity/capital comme
--      avant.
--   4. transition_trade étendu : au moment de la clôture, calcule le
--      PnL de la DERNIÈRE tranche (ce qui reste de quantity/capital)
--      et l'ajoute à realized_pnl_gross.
--   5. pnl_gross/rendement_pct/r_multiple réécrits pour lire
--      realized_pnl_gross / initial_capital / initial_quantity au
--      lieu de recalculer depuis quantity/capital restants.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Colonnes
-- -----------------------------------------------------------------------------
alter table public.trades
  add column if not exists initial_quantity numeric(24,8) check (initial_quantity is null or initial_quantity > 0);

comment on column public.trades.initial_quantity is
  'Quantité engagée au moment de la publication (snapshot, ne change jamais après). Référence stable pour le calcul du risque et de la taille de position — distincte de quantity qui diminue avec les sorties partielles. Posée par publish_trade().';

alter table public.trades
  add column if not exists initial_capital numeric(24,8) check (initial_capital is null or initial_capital > 0);

comment on column public.trades.initial_capital is
  'Capital engagé au moment de la publication (snapshot, ne change jamais après). Référence stable pour le calcul du rendement et de la taille de position — distincte de capital qui diminue avec les sorties partielles. Posée par publish_trade().';

alter table public.trades
  add column if not exists realized_pnl_gross numeric(24,8) not null default 0;

comment on column public.trades.realized_pnl_gross is
  'PnL brut réalisé cumulé, accumulé à chaque sortie (partielle ou finale) par record_partial_exit() et transition_trade(). Remplace le recalcul approximatif depuis quantity/capital restants (qui perdait le PnL des sorties partielles antérieures).';

-- -----------------------------------------------------------------------------
-- 2. publish_trade — transition draft → live + snapshot initial_*
-- -----------------------------------------------------------------------------
create or replace function public.publish_trade(p_trade_id uuid)
returns public.trades
language plpgsql
as $$
declare
  v_trade public.trades;
begin
  update public.trades
  set status = 'live',
      published_at = now(),
      opened_at = now(),
      initial_quantity = quantity,
      initial_capital = capital
  where id = p_trade_id
    and user_id = auth.uid()
    and status = 'draft'
  returning * into v_trade;

  if v_trade.id is null then
    raise exception
      'Trade introuvable, déjà publié, ou non autorisé';
  end if;

  return v_trade;
end $$;

comment on function public.publish_trade(uuid) is
  'Transition draft → live. Pose published_at/opened_at côté DB (now()) et snapshote initial_quantity/initial_capital depuis quantity/capital au moment de la publication — référence stable pour le risque, distincte des valeurs restantes post-sorties-partielles.';

-- -----------------------------------------------------------------------------
-- 3. record_partial_exit étendu — accumule le PnL de la sortie
-- -----------------------------------------------------------------------------
create or replace function public.record_partial_exit(
  p_trade_id uuid,
  p_exit_price numeric,
  p_exit_quantity numeric
)
returns public.trades
language plpgsql
security invoker
as $$
declare
  v_trade public.trades;
  v_new_quantity numeric(24,8);
  v_new_capital numeric(24,8);
  v_leg_pnl numeric(24,8);
begin
  if p_exit_price is null or p_exit_price <= 0 then
    raise exception 'p_exit_price doit être strictement positif (whitepaper §06)';
  end if;
  if p_exit_quantity is null or p_exit_quantity <= 0 then
    raise exception 'p_exit_quantity doit être strictement positif (whitepaper §06)';
  end if;

  select * into v_trade
  from public.trades
  where id = p_trade_id
    and user_id = auth.uid()
    and status = 'live'
  for update;

  if v_trade.id is null then
    raise exception
      'Trade introuvable, non autorisé, ou non live (sortie partielle = trade live uniquement)';
  end if;

  if p_exit_quantity >= v_trade.quantity then
    raise exception
      'p_exit_quantity (%) >= quantity (%) : sortie totale, utiliser transition_trade(...,''closed'', p_exit_price) à la place',
      p_exit_quantity, v_trade.quantity;
  end if;

  -- PnL de CETTE sortie uniquement : (exit - entry) * quantité sortie
  -- * multiplicateur de direction (long=+1, short=-1).
  v_leg_pnl := (p_exit_price - v_trade.entry_price)
               * p_exit_quantity
               * public._direction_multiplier(v_trade.direction);

  v_new_quantity := v_trade.quantity - p_exit_quantity;
  v_new_capital := v_trade.capital * (v_new_quantity / v_trade.quantity);

  update public.trades
  set quantity = v_new_quantity,
      capital = v_new_capital,
      exit_price = p_exit_price,
      realized_pnl_gross = realized_pnl_gross + v_leg_pnl
  where id = p_trade_id
  returning * into v_trade;

  return v_trade;
end $$;

-- -----------------------------------------------------------------------------
-- 4. transition_trade étendu — accumule le PnL de la dernière tranche
-- -----------------------------------------------------------------------------
create or replace function public.transition_trade(
  p_trade_id uuid,
  p_new_status public.trade_status,
  p_exit_price numeric default null
)
returns public.trades
language plpgsql
security invoker
as $$
declare
  v_trade public.trades;
  v_old_status public.trade_status;
  v_event_type public.trade_event_type;
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

  -- PnL de la DERNIÈRE tranche : ce qui reste de quantity au moment
  -- de la clôture, au prix de sortie fourni. Ajouté au PnL déjà
  -- accumulé par d'éventuelles sorties partielles antérieures.
  if p_new_status = 'closed' and p_exit_price is not null then
    v_leg_pnl := (p_exit_price - v_trade.entry_price)
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
        when p_new_status = 'closed' and p_exit_price is not null then p_exit_price
        else exit_price
      end,
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

-- -----------------------------------------------------------------------------
-- 5. pnl_gross / rendement_pct / r_multiple réécrits
-- -----------------------------------------------------------------------------
create or replace function public.pnl_gross(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when (p_trade).status = 'closed' then (p_trade).realized_pnl_gross
    else null
  end
$$;

create or replace function public.rendement_pct(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when public.pnl_net(p_trade) is null or (p_trade).initial_capital is null or (p_trade).initial_capital = 0 then null
    else (public.pnl_net(p_trade) / (p_trade).initial_capital) * 100
  end
$$;

create or replace function public.r_multiple(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  with risk as (
    select case
      when (p_trade).stop_loss is not null and (p_trade).initial_quantity is not null then
        abs((p_trade).entry_price - (p_trade).stop_loss) * (p_trade).initial_quantity
      when (p_trade).risk_percent is not null and (p_trade).initial_capital is not null then
        ((p_trade).risk_percent / 100.0) * (p_trade).initial_capital
      else
        null
    end as amount
  )
  select case
    when public.pnl_net(p_trade) is null then null
    when (select amount from risk) is null or (select amount from risk) = 0 then null
    else public.pnl_net(p_trade) / (select amount from risk)
  end
$$;

commit;