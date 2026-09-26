-- /supabase/migrations/20260903000001_exit_price_and_partial_exit_rpc.sql
-- =============================================================================
-- Phase 3 — Calculs Financiers : gap d'architecture (exit_price + RPC
-- record_partial_exit + extensions ciblées de log_partial_exits et
-- transition_trade).
--
-- PROBLÈME POSÉ : la Phase 2 a verrouillé le capital post-publication et
-- autorisé la sortie partielle (réduction de capital/quantity). Le
-- trigger log_partial_exits historise ces variations dans trade_events.
-- Mais AUCUN prix de sortie n'est capturé. Sans exit_price, le PnL
-- est incalculable côté DB, ce qui rend la Phase 3 (PnL, rendement,
-- R-multiple, winrate, etc.) impossible à sourcer côté serveur — et
-- un calcul côté client ouvrirait la porte au trafiquage des stats
-- affichées sur les profils publics (whitepaper §09).
--
-- CONTENU DE CETTE MIGRATION (ajouts ciblés, pas de réécriture) :
--   1. Colonnes sur trades :
--      - exit_price numeric(24,8) nullable : prix de la dernière sortie
--        connue (clôture finale ou dernière sortie partielle). Informatif
--        au niveau de la ligne, l'historique complet reste dans
--        trade_events (event partial_exit / closed).
--      - mae numeric(24,8) nullable : Maximum Adverse Excursion.
--      - mfe numeric(24,8) nullable : Maximum Favorable Excursion.
--        Les deux derniers restent NULL tant que le MarketDataProvider
--        (Phase 5) n'est pas livré — leur calcul dépend de l'historique
--        de bougies par instrument. Colonnes préparées en avance pour
--        éviter une migration de schéma le jour où la Phase 5 arrive.
--        NE PAS leur donner de valeur approximative en attendant
--        (la consigne du cadrage est explicite, c'est ce qui distingue
--        un "champ prêt" d'un "champ qui ment").
--   2. record_partial_exit(p_trade_id, p_exit_price, p_exit_quantity) :
--      RPC SECURITY INVOKER qui remplace l'update brut de capital/quantity
--      depuis l'UI. Calcule la nouvelle quantity/capital proportionnellement
--      à la sortie, pose exit_price dans le même UPDATE. Filtre
--      user_id = auth.uid() ET status = 'live' (défense en profondeur
--      + RLS). Refuse les sorties totales (p_exit_quantity >= quantity)
--      pour pousser vers transition_trade(p_exit_price).
--   3. log_partial_exits : create or replace qui AJOUTE exit_price dans
--      old_values/new_values du jsonb. Le trigger trades_log_partial_exits
--      continue à appeler la même fonction (pas de réenregistrement).
--   4. transition_trade : create or replace avec un 3e paramètre
--      p_exit_price numeric DEFAULT NULL. Quand p_new_status = 'closed'
--      et p_exit_price fourni, posé sur trades.exit_price et inclus
--      dans l'event 'closed'. Rétrocompatible : l'appel sans
--      p_exit_price (tous les callers UI actuels) reste fonctionnel.
--
-- MAE/MFE : voir aussi la TODO_TECHNIQUE.md section "Phase 6" pour la
-- note explicite. Pas de calcul approximatif en attendant Phase 5.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Colonnes
-- -----------------------------------------------------------------------------

-- exit_price : prix de la dernière sortie connue. Nullable : un trade
-- en draft ou live sans sortie n'a pas d'exit_price. Posé par
-- record_partial_exit (sortie partielle) ou par transition_trade
-- avec p_exit_price (clôture finale).
alter table public.trades
  add column if not exists exit_price numeric(24,8) check (exit_price is null or exit_price > 0);

comment on column public.trades.exit_price is
  'Prix de la dernière sortie connue (clôture finale ou dernière sortie partielle). Posé par record_partial_exit (sortie partielle) ou transition_trade avec p_exit_price (clôture). NULL tant qu''aucune sortie n''a été enregistrée.';

-- mae / mfe : colonnes prêtes, valeur NULL tant que le calcul
-- (Phase 5 MarketDataProvider) n'est pas implémenté. Le check permet
-- NULL ou >= 0 (les deux sont des distances, jamais négatives).
alter table public.trades
  add column if not exists mae numeric(24,8) check (mae is null or mae >= 0);

comment on column public.trades.mae is
  'Maximum Adverse Excursion. NULL : calcul dépend de l''historique de bougies par instrument (Phase 5 MarketDataProvider), pas encore implémenté. NE PAS donner de valeur approximative en attendant.';

alter table public.trades
  add column if not exists mfe numeric(24,8) check (mfe is null or mfe >= 0);

comment on column public.trades.mfe is
  'Maximum Favorable Excursion. NULL : calcul dépend de l''historique de bougies par instrument (Phase 5 MarketDataProvider), pas encore implémenté. NE PAS donner de valeur approximative en attendant.';

-- -----------------------------------------------------------------------------
-- 2. record_partial_exit
-- -----------------------------------------------------------------------------
-- SECURITY INVOKER : la RLS UPDATE s'applique. Le WHERE filtre
-- user_id = auth.uid() ET status = 'live' (défense en profondeur).
--
-- Calcul de la nouvelle exposure : on réduit quantity et capital au
-- prorata de la quantité sortie. Le capital engagé reflète l'exposition
-- RESTANTE, pas le PnL réalisé — le PnL est calculé hors trade via les
-- fonctions de la migration 03_financial_calcs.
--
-- Refuse les sorties totales (p_exit_quantity >= quantity) : c'est une
-- clôture, pas une sortie partielle, on pousse vers transition_trade.
-- Évite que l'UI utilise ce RPC par erreur pour clôturer un trade.
--
-- exit_price est posé sur la ligne (information au niveau du trade) ET
-- capturé dans trade_events via le trigger log_partial_exits étendu
-- (historique complet, plusieurs sorties partielles possibles).
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
begin
  -- Validation des inputs — toute valeur <= 0 ou NULL est rejetée
  -- avant même de toucher la base, feedback immédiat côté UI.
  if p_exit_price is null or p_exit_price <= 0 then
    raise exception 'p_exit_price doit être strictement positif (whitepaper §06)';
  end if;
  if p_exit_quantity is null or p_exit_quantity <= 0 then
    raise exception 'p_exit_quantity doit être strictement positif (whitepaper §06)';
  end if;

  -- Lock + lecture. WHERE user_id = auth.uid() ET status = 'live' :
  -- - user_id filtre les trades d'autres users (défense en profondeur,
  --   redondant avec la RLS mais explicite)
  -- - status = 'live' : on ne peut pas sortir d'une position draft,
  --   oubliée, clôturée ou archivée (sortie partielle = trade vivant)
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

  -- Sortie totale : ce n'est pas le bon RPC. On pousse vers
  -- transition_trade(p_exit_price) qui pose status=closed et
  -- exit_price dans le même UPDATE.
  if p_exit_quantity >= v_trade.quantity then
    raise exception
      'p_exit_quantity (%) >= quantity (%) : sortie totale, utiliser transition_trade(...,''closed'', p_exit_price) à la place',
      p_exit_quantity, v_trade.quantity;
  end if;

  -- Réduction proportionnelle : nouvelle quantity, nouveau capital
  -- réduit au prorata. Le ratio capital/quantity reste constant
  -- (l'exposition par unité ne change pas, seule la taille change).
  v_new_quantity := v_trade.quantity - p_exit_quantity;
  v_new_capital := v_trade.capital * (v_new_quantity / v_trade.quantity);

  -- UPDATE atomique : quantity + capital + exit_price. Le trigger
  -- log_partial_exits étendu (ci-dessous) capture l'event
  -- partial_exit avec exit_price dans old/new_values.
  update public.trades
  set quantity = v_new_quantity,
      capital = v_new_capital,
      exit_price = p_exit_price
  where id = p_trade_id
  returning * into v_trade;

  return v_trade;
end $$;

-- -----------------------------------------------------------------------------
-- 3. log_partial_exits étendu (ajout exit_price dans le jsonb)
-- -----------------------------------------------------------------------------
-- create or replace : la signature ne change pas, le trigger
-- trades_log_partial_exits continue à appeler la même fonction —
-- pas de réenregistrement nécessaire. Seul le contenu du jsonb
-- change : on AJOUTE exit_price (3e clé). Les anciens events
-- partial_exit (sans exit_price) restent lisibles — c'est du
-- jsonb, les clés manquantes ne cassent rien à la lecture.
create or replace function public.log_partial_exits()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.status = 'live' then
    if new.capital < old.capital or new.quantity < old.quantity then
      insert into public.trade_events
        (trade_id, user_id, event_type, old_values, new_values)
      values
        (old.id, old.user_id, 'partial_exit',
         jsonb_build_object(
           'capital', old.capital,
           'quantity', old.quantity,
           'exit_price', old.exit_price
         ),
         jsonb_build_object(
           'capital', new.capital,
           'quantity', new.quantity,
           'exit_price', new.exit_price
         ));
    end if;
  end if;
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- 4. transition_trade étendu (3e paramètre p_exit_price optionnel)
-- -----------------------------------------------------------------------------
-- create or replace : rétrocompatible — les callers UI existants
-- (TradeTransitionButton) appellent sans p_exit_price, ce qui
-- donne le comportement précédent (pas de pose d'exit_price).
-- Quand p_new_status = 'closed' ET p_exit_price fourni, on pose
-- l'exit_price et on l'inclut dans le jsonb de l'event 'closed'.
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
begin
  -- Lock + lecture. `for update` empêche une race entre deux clics
  -- simultanés. user_id = auth.uid() filtre les trades d'autres
  -- users (défense en profondeur, redondant avec la RLS).
  select * into v_trade
  from public.trades
  where id = p_trade_id and user_id = auth.uid()
  for update;

  if v_trade.id is null then
    raise exception 'Trade introuvable ou non autorisé';
  end if;

  v_old_status := v_trade.status;

  -- Table de transitions autorisées (cf. migration 03 de la Phase 2
  -- + whitepaper §04). Le live → forgotten est autorisé au niveau SQL
  -- mais pas exposé en UI (job OUBLIÉ uniquement).
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

  -- Validation croisée : p_exit_price ne fait sens que pour une
  -- clôture (closed). Si fourni pour une autre transition, on lève
  -- — évite qu'un caller passe un exit_price par erreur sur un
  -- 'archived' par exemple.
  if p_exit_price is not null and p_new_status <> 'closed' then
    raise exception
      'p_exit_price ne peut être fourni que pour une clôture (new_status=closed, reçu %)',
      p_new_status;
  end if;

  -- UPDATE du trade :
  -- - closed_at = now() si on transitionne vers 'closed'
  -- - exit_price : posé si p_exit_price fourni ET transition vers
  --   'closed', sinon on conserve l'éventuel exit_price précédent
  --   (cas défensif d'une clôture depuis forgotten, ou après une
  --   sortie partielle antérieure)
  update public.trades
  set status = p_new_status,
      closed_at = case
        when p_new_status = 'closed' then now()
        else closed_at
      end,
      exit_price = case
        when p_new_status = 'closed' and p_exit_price is not null then p_exit_price
        else exit_price
      end
  where id = p_trade_id
  returning * into v_trade;

  -- Historisation dans trade_events. old_values capture le status
  -- précédent. new_values capture le nouveau status, plus exit_price
  -- si posé (uniquement sur clôture avec p_exit_price fourni).
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

commit;
