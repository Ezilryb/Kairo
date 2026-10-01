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
-- une sortie partielle est silencieusement perdu, et le signe
-- global peut s'inverser (un trade gagnant classé perdant).
--
-- Exemple concret du bug (repris du retour du chef) :
--   long, entry=100, initial_quantity=10, initial_capital=1000
--   - Sortie partielle à 120 sur 4 unités → gain = (120-100)*4 = +80
--     quantity → 6, capital → 600 (voulu, c'est l'état restant)
--   - Clôture finale à 90 sur 6 unités → gain = (90-100)*6 = -60
--   - PnL réel total = 80 + (-60) = +20 (gagnant)
--   - pnl_gross() avant fix : (90-100)*6 = -60 (perdant !) — bug
--   - pnl_gross() après fix : realized_pnl_gross = 80 + (-60) = 20
--
-- FIX : on persiste dans la table `trades` trois champs qui sont
-- posés/mis à jour incrémentalement par les RPC métier :
--   1. initial_quantity  : snapshot à la publication (publish_trade)
--   2. initial_capital   : snapshot à la publication (publish_trade)
--   3. realized_pnl_gross: accumulateur, += leg_pnl à chaque
--                          sortie partielle ET à la clôture finale
--                          (record_partial_exit, transition_trade)
-- Et pnl_gross(trade) devient simplement realized_pnl_gross si le
-- trade est closed, NULL sinon. Plus de recalcul trompeur depuis
-- (exit - entry) * quantity.
--
-- rendement_pct et r_multiple sont aussi redéfinis pour utiliser
-- initial_capital et initial_quantity (la base de référence du
-- risque, pas l'état restant qui change après chaque sortie).
--
-- POSITION DANS LA CHAÎNE : cette migration vient APRÈS
-- 20260903000003_financial_calcs.sql, parce que _direction_multiplier
-- (helper de pnl_gross original) y est défini et qu'on le réutilise
-- pour calculer les leg_pnl. Convention du projet : on ne modifie
-- jamais une migration déjà appliquée. Tout fix passe par une
-- nouvelle migration.
--
-- BACKFILL DES TRADES EXISTANTS : realized_pnl_gross NOT NULL
-- DEFAULT 0. Pour les trades déjà en base AVANT cette migration
-- (les tests des fichiers 01/02 et les éventuels trades de dev),
-- la valeur sera 0, ce qui produira un pnl_gross = 0 au lieu du
-- PnL historique correct. Le projet n'est pas encore en production
-- (Phase 3 fraîche), donc pas de backfill à faire ici. Quand
-- l'app sera en prod avec de vrais trades historiques, il faudra
-- un script de backfill qui recalcule realized_pnl_gross depuis
-- les trade_events — à ajouter dans le TODO doc le moment venu.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Nouvelles colonnes
-- -----------------------------------------------------------------------------
-- initial_quantity et initial_capital : snapshot à la publication.
-- Nullable car un trade créé en draft avant cette migration n'a pas
-- encore de snapshot ; publish_trade les pose au passage draft → live.
-- realized_pnl_gross : accumulateur, NOT NULL DEFAULT 0 pour éviter
-- toute ambiguïté (un trade sans aucune sortie a realized_pnl_gross = 0).
alter table public.trades
  add column if not exists initial_quantity numeric(24,8) check (initial_quantity is null or initial_quantity > 0);

comment on column public.trades.initial_quantity is
  'Snapshot de quantity au moment de la publication (publish_trade). Référence pour le calcul du risque et du PnL — ne change pas après les sorties partielles. NULL tant que le trade n''est pas passé en live.';

alter table public.trades
  add column if not exists initial_capital numeric(24,8) check (initial_capital is null or initial_capital >= 0);

comment on column public.trades.initial_capital is
  'Snapshot de capital au moment de la publication. Référence pour le calcul du rendement — ne change pas après les sorties partielles.';

alter table public.trades
  add column if not exists realized_pnl_gross numeric(24,8) not null default 0;

comment on column public.trades.realized_pnl_gross is
  'Accumulateur du PnL brut réalisé. += (exit - entry) * leg_quantity * direction à chaque sortie partielle (record_partial_exit) et à la clôture finale (transition_trade vers closed). DEFAULT 0 pour les trades sans aucune sortie.';

-- -----------------------------------------------------------------------------
-- 2. publish_trade : pose le snapshot initial
-- -----------------------------------------------------------------------------
-- On snapshot quantity et capital au moment du passage draft → live.
-- La fonction publique n'est pas rétro-influencée (elle ne change
-- pas de signature), juste son corps qui fait un UPDATE plus complet.
--
-- Subtilité SQL : dans un UPDATE ... SET, une référence de colonne
-- non qualifiée (juste `quantity`, sans préfixe `old.` ou `new.`)
-- fait référence à la valeur AVANT modification de la ligne en
-- cours — c'est le comportement standard de PostgreSQL, pas un
-- piège. OLD et NEW n'existent qu'en contexte trigger (row-level
-- functions fired by triggers). publish_trade est un RPC normal,
-- pas un trigger, donc on écrit juste `quantity` et `capital`
-- pour récupérer le snapshot avant que les colonnes quantity/capital
-- elles-mêmes ne soient (potentiellement) modifiées par une clause
-- SET antérieure dans le même UPDATE. Ici on ne modifie ni quantity
-- ni capital dans ce UPDATE, donc la valeur lue est trivialement
-- celle de la ligne actuelle au moment de l'UPDATE.
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

-- -----------------------------------------------------------------------------
-- 3. record_partial_exit : cumule le leg_pnl dans realized_pnl_gross
-- -----------------------------------------------------------------------------
-- Le leg_pnl est calculé sur la quantité sortie (p_exit_quantity) et
-- le prix de sortie fourni (p_exit_price). Le sens (long/short) est
-- appliqué via _direction_multiplier (helper de la migration 003).
-- realized_pnl_gross += v_leg_pnl dans le même UPDATE que la réduction
-- de quantity/capital.
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

  v_new_quantity := v_trade.quantity - p_exit_quantity;
  v_new_capital := v_trade.capital * (v_new_quantity / v_trade.quantity);

  -- Leg PnL = (exit - entry) * leg_quantity * signe(direction).
  -- C'est le gain (ou la perte) réalisé sur cette sortie spécifique.
  v_leg_pnl := (p_exit_price - v_trade.entry_price)
               * p_exit_quantity
               * public._direction_multiplier(v_trade.direction);

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
-- 4. transition_trade : cumule le leg final dans realized_pnl_gross
-- -----------------------------------------------------------------------------
-- À la clôture, on calcule le leg final sur la quantité RESTANTE
-- (v_trade.quantity, lu avant l'UPDATE) et on l'ajoute à
-- realized_pnl_gross. Si p_exit_price est fourni (cas normal), on
-- l'utilise ; sinon, on retombe sur l'exit_price déjà posé par une
-- éventuelle sortie partielle précédente (defensive — un trade peut
-- avoir été clôturé sans nouvelle saisie d'exit_price).
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

-- -----------------------------------------------------------------------------
-- 5. pnl_gross(trade) — simplifié, basé sur realized_pnl_gross
-- -----------------------------------------------------------------------------
-- Avant : (exit_price - entry_price) * quantity * direction — faux
-- pour les trades avec sortie(s) partielle(s) car quantity est
-- RESTANTE après les sorties.
-- Après : realized_pnl_gross si status = 'closed', NULL sinon.
-- realized_pnl_gross est l'accumulateur alimenté par record_partial_exit
-- (à chaque sortie partielle) et transition_trade (à la clôture finale).
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

comment on function public.pnl_gross(public.trades) is
  'PnL brut d''un trade closed = realized_pnl_gross (accumulateur alimenté par les RPC record_partial_exit et transition_trade). NULL pour les trades non closed. Avant le fix, on recalculait depuis (exit - entry) * quantity, ce qui sous-estimait silencieusement les gains sur les trades avec sortie(s) partielle(s).';

-- -----------------------------------------------------------------------------
-- 6. rendement_pct(trade) — utilise initial_capital, pas capital
-- -----------------------------------------------------------------------------
-- Le rendement doit être rapporté au capital ENGAGÉ INITIAL, pas
-- au capital restant après sorties partielles. Sinon, un trade
-- qui sort à 50% de gain et clôture à 0 a un rendement de 0% au
-- lieu de 50% (divisé par le capital final nul — ou encore pire,
-- le capital final est calculé au prorata de la quantity, donc
-- un trade à +100% global apparaîtrait à +100% aussi, mais un
-- trade à -50% global apparaîtrait à -50% et non -50% du capital
-- initial — même signe mais mauvaise magnitude).
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

comment on function public.rendement_pct(public.trades) is
  'Rendement en % par rapport au capital engagé INITIAL. pnl_net / initial_capital * 100. NULL si non closed ou initial_capital NULL/0.';

-- -----------------------------------------------------------------------------
-- 7. r_multiple(trade) — utilise initial_quantity et initial_capital
-- -----------------------------------------------------------------------------
-- Le risque est défini à l'ENTRÉE : c'est ce que l'user a accepté
-- de risquer quand il a publié le trade. Il ne change pas après
-- les sorties partielles. Si on utilise la quantity restante, le
-- risque calculé baisse à chaque sortie (sous-évaluation du
-- dénominateur → R-multiple gonflé artificiellement).
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
comment on function public.r_multiple(public.trades) is
  'R-multiple = pnl_net / risk_amount. risk = |entry - stop_loss| * initial_quantity, sinon risk_percent/100 * initial_capital. Le risque est défini à l''entrée et ne change pas après les sorties partielles. NULL si pas de stop_loss ni risk_percent, ou si pnl_net NULL.';

-- pnl_net n'a pas besoin d'être modifié : il compose pnl_gross -
-- fees - slippage, et pnl_gross est maintenant realized_pnl_gross
-- quand status = 'closed'. Comportement inchangé pour les trades
-- sans sortie partielle (realized_pnl_gross = leg de clôture = la
-- formule précédente, au signe près).

commit;
