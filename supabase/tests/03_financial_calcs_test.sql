-- /supabase/tests/03_financial_calcs_test.sql
-- =============================================================================
-- Tests pgTAP pour la Phase 3 — Calculs Financiers.
-- Conventions identiques à 02_trades_lifecycle_test.sql :
--   - begin/rollback autour du test, plan() en tête, finish() en fin
--   - Chaque test est autosuffisant : setup + assertions dans le même do $$
--   - JAMAIS deux appels à now() comparés sans backdating explicite
--     (cf. leçon 01_schema_test.sql, section "Règle d'or")
--   - SECURITY INVOKER : on pose set_config('request.jwt.claim.sub', ...)
--     avant les appels RPC qui dépendent de auth.uid() (record_partial_exit,
--     transition_trade). Les fonctions agrégées (winrate, etc.) prennent
--     user_id en paramètre : pas besoin de set_config.
--
-- User dédié : 00000000-0000-0000-0000-000000000003 (pas de collision
-- avec 0001 (01_schema_test) ou 0002 (02_trades_lifecycle_test)).
-- Instrument dédié : TESTUSD3.
--
-- Plan : 22 assertions (cf. détail ci-dessous)
-- 1   : record_partial_exit OK
-- 2   : record_partial_exit sortie totale REFUSÉE
-- 3   : record_partial_exit trade non live REFUSÉ
-- 4   : transition_trade + p_exit_price OK
-- 5   : transition_trade + p_exit_price sur archived REFUSÉ
-- 6   : transition_trade sans p_exit_price : rétrocompat
-- 7   : pnl_gross 4 directions + 2 null
-- 8   : pnl_net
-- 9   : rendement_pct
-- 10  : r_multiple
-- 11  : winrate
-- 12  : profit_factor
-- 13  : expectancy
-- 14  : max_drawdown
-- 15  : fee_profiles seed
-- 16a : _direction_multiplier(long)
-- 16b : _direction_multiplier(short)
-- 17  : mae/mfe nullables
-- 18  : record_partial_exit trade d'un autre user REFUSÉ
-- 19  : record_partial_exit p_exit_price <= 0 REFUSÉ
-- 20  : test combiné partial_exit + close : realized_pnl_gross cumule
-- 21  : publish_trade snapshot initial_quantity/initial_capital
-- =============================================================================

begin;

-- Setup : instrument + user de la suite
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD3', 'Test Asset 3', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000003'::uuid, 'test+setup3@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000003'::uuid, 'test_setup3')
on conflict (id) do nothing;

select plan(22);

-- ============================================================================
-- Test 1 : record_partial_exit OK — réduit quantity/capital proportionnellement
-- ============================================================================
-- Trade live, quantity=4, capital=400. Sortie de 1 unité à 110.
--   - exit_price = 110
--   - new_quantity = 4 - 1 = 3
--   - new_capital = 400 * (3/4) = 300
--   - 1 trade_event partial_exit créé avec exit_price dans le jsonb
--   - realized_pnl_gross = (110-100)*1*1 = 10 (cumul du leg)
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_result public.trades;
       v_event_count int;
       v_event jsonb;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 4, 400, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         4, 400
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       select * into v_result from public.record_partial_exit(v_trade_id, 110, 1);
       if v_result.quantity <> 3 then
         raise exception 'quantity doit être 3, trouvé %', v_result.quantity;
       end if;
       if v_result.capital <> 300 then
         raise exception 'capital doit être 300, trouvé %', v_result.capital;
       end if;
       if v_result.exit_price is null or v_result.exit_price <> 110 then
         raise exception 'exit_price doit être 110, trouvé %', v_result.exit_price;
       end if;
       if v_result.realized_pnl_gross <> 10 then
         raise exception 'realized_pnl_gross doit être 10 (leg=(110-100)*1*1), trouvé %', v_result.realized_pnl_gross;
       end if;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'partial_exit';
       if v_event_count <> 1 then
         raise exception 'attendu 1 trade_event partial_exit, trouvé %', v_event_count;
       end if;
       -- Vérifier que exit_price est dans le jsonb de l'event
       select new_values into v_event
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'partial_exit';
       if v_event->>'exit_price' is null or (v_event->>'exit_price')::numeric <> 110 then
         raise exception 'exit_price absent ou incorrect dans new_values: %', v_event;
       end if;
     end $$ $$,
  'record_partial_exit réduit qty/capital + pose exit_price + event avec exit_price + realized_pnl_gross += leg'
);

-- ============================================================================
-- Test 2 : record_partial_exit — sortie totale REFUSÉE (pousse vers transition_trade)
-- ============================================================================
-- p_exit_quantity >= quantity → on lève pour éviter que l'UI utilise ce
-- RPC pour clôturer un trade.
-- Le message commence par 'p_exit_quantity (%) >= quantity (%) :...',
-- donc le pattern est 'p_exit_quantity%'.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 2, 200, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         2, 200
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       perform public.record_partial_exit(v_trade_id, 110, 2);
     end $$ $$,
  'p_exit_quantity%',
  'record_partial_exit refuse les sorties totales (p_exit_quantity >= quantity)'
);

-- ============================================================================
-- Test 3 : record_partial_exit — trade non live (closed) REFUSÉ
-- ============================================================================
-- Le WHERE filtre status = 'live'. Un trade closed/forgotten/draft ne
-- peut pas avoir de sortie partielle.
-- Le message commence par 'Trade introuvable, non autorisé, ou non live...',
-- donc le pattern est 'Trade introuvable%'.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 2, 200, 'closed',
         now() - interval '1 hour', now() - interval '1 hour',
         now() - interval '10 minutes', 110,
         2, 200
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       perform public.record_partial_exit(v_trade_id, 120, 1);
     end $$ $$,
  'Trade introuvable%',
  'record_partial_exit refuse les trades non live'
);

-- ============================================================================
-- Test 4 : transition_trade avec p_exit_price — clôture OK, exit_price posé
-- ============================================================================
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_result public.trades;
       v_event jsonb;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       select * into v_result from public.transition_trade(v_trade_id, 'closed'::public.trade_status, 115);
       if v_result.status <> 'closed' then
         raise exception 'status doit être closed, trouvé %', v_result.status;
       end if;
       if v_result.closed_at is null then
         raise exception 'closed_at doit être posé';
       end if;
       if v_result.exit_price <> 115 then
         raise exception 'exit_price doit être 115, trouvé %', v_result.exit_price;
       end if;
       if v_result.realized_pnl_gross <> 15 then
         raise exception 'realized_pnl_gross doit être 15 (leg=(115-100)*1*1), trouvé %', v_result.realized_pnl_gross;
       end if;
       -- Vérifier que l'event 'closed' contient exit_price dans le jsonb
       select new_values into v_event
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'closed';
       if v_event->>'exit_price' is null or (v_event->>'exit_price')::numeric <> 115 then
         raise exception 'exit_price absent ou incorrect dans new_values de l''event closed: %', v_event;
       end if;
     end $$ $$,
  'transition_trade closed + p_exit_price pose exit_price + realized_pnl_gross += leg + event contient exit_price'
);

-- ============================================================================
-- Test 5 : transition_trade avec p_exit_price pour une transition non-closed → REFUSÉ
-- ============================================================================
-- Garde-fou : p_exit_price n'a de sens que pour une clôture. Si fourni
-- pour archived/live/forgotten, on lève.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 110,
         1, 100
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       perform public.transition_trade(v_trade_id, 'archived'::public.trade_status, 999);
     end $$ $$,
  'p_exit_price ne peut être fourni%',
  'transition_trade refuse p_exit_price pour une transition non-closed'
);

-- ============================================================================
-- Test 6 : transition_trade RÉTROCOMPAT — sans p_exit_price, exit_price non touché
-- ============================================================================
-- Les callers UI existants (TradeTransitionButton Phase 2) appellent sans
-- p_exit_price. Comportement précédent : exit_price n'est pas posé (sauf
-- s'il y en avait un avant via sortie partielle).
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_result public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       -- Pas de p_exit_price fourni
       select * into v_result from public.transition_trade(v_trade_id, 'closed'::public.trade_status);
       if v_result.status <> 'closed' then
         raise exception 'status doit être closed';
       end if;
       if v_result.exit_price is not null then
         raise exception 'exit_price doit rester NULL (pas de p_exit_price fourni), trouvé %', v_result.exit_price;
       end if;
     end $$ $$,
  'transition_trade sans p_exit_price : exit_price reste NULL (rétrocompat)'
);

-- ============================================================================
-- Test 7 : pnl_gross — 4 directions + 2 cas null
-- ============================================================================
-- Après le fix, pnl_gross(trade) = realized_pnl_gross si status = closed,
-- NULL sinon. Plus de calcul trompeur depuis (exit - entry) * quantity.
-- On insère directement des trades closed avec realized_pnl_gross posé
-- manuellement (= valeur attendue par le calcul historique) pour
-- vérifier que pnl_gross() la retourne correctement. Le test du
-- pipeline complet (partial_exit + close) est le test 20.
-- (1) long, exit > entry, quantity=1, leg=(110-100)*1*1=+10, realized=10
-- (2) long, exit < entry, leg=(90-100)*1*1=-10, realized=-10
-- (3) short, exit < entry, leg=(90-100)*1*(-1)=+10, realized=10
-- (4) short, exit > entry, leg=(110-100)*1*(-1)=-10, realized=-10
-- (5) exit_price NULL → status live, realized=0 → pnl_gross=NULL
-- (6) status non closed (forgotten) → pnl_gross=NULL
select lives_ok(
  $$ do $$
     declare
       v_long_win public.trades;
       v_long_lose public.trades;
       v_short_win public.trades;
       v_short_lose public.trades;
       v_no_exit public.trades;
       v_forgotten_trade public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 110,
         1, 100, 10
       ) returning * into v_long_win;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 90,
         1, 100, -10
       ) returning * into v_long_lose;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'short', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 90,
         1, 100, 10
       ) returning * into v_short_win;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'short', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 110,
         1, 100, -10
       ) returning * into v_short_lose;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100
       ) returning * into v_no_exit;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'forgotten',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '10 days', 110,
         1, 100, 10
       ) returning * into v_forgotten_trade;
       -- Long win : realized=10 → pnl_gross=10
       if public.pnl_gross(v_long_win) <> 10 then
         raise exception 'long+exit>entry : attendu 10, trouvé %', public.pnl_gross(v_long_win);
       end if;
       -- Long lose : realized=-10 → pnl_gross=-10
       if public.pnl_gross(v_long_lose) <> -10 then
         raise exception 'long+exit<entry : attendu -10, trouvé %', public.pnl_gross(v_long_lose);
       end if;
       -- Short win : realized=10 → pnl_gross=10
       if public.pnl_gross(v_short_win) <> 10 then
         raise exception 'short+exit<entry : attendu 10, trouvé %', public.pnl_gross(v_short_win);
       end if;
       -- Short lose : realized=-10 → pnl_gross=-10
       if public.pnl_gross(v_short_lose) <> -10 then
         raise exception 'short+exit>entry : attendu -10, trouvé %', public.pnl_gross(v_short_lose);
       end if;
       -- status live → pnl_gross NULL
       if public.pnl_gross(v_no_exit) is not null then
         raise exception 'status live doit donner pnl_gross NULL, trouvé %', public.pnl_gross(v_no_exit);
       end if;
       -- status forgotten → pnl_gross NULL
       if public.pnl_gross(v_forgotten_trade) is not null then
         raise exception 'status forgotten doit donner pnl_gross NULL, trouvé %', public.pnl_gross(v_forgotten_trade);
       end if;
     end $$ $$,
  'pnl_gross : 4 realized_pnl_gross + status non closed donnent NULL (basé sur realized_pnl_gross après le fix)'
);

-- ============================================================================
-- Test 8 : pnl_net — realised_pnl_gross - fees - slippage, nullables traités comme 0
-- ============================================================================
-- Trade : long, realized=20, fees=2, slippage=1 → net = 20 - 2 - 1 = 17
-- Trade : long, realized=20, fees=NULL, slippage=NULL → net = 20 (coalesce 0)
select lives_ok(
  $$ do $$
     declare
       v_with_fees public.trades;
       v_no_fees public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, fees, slippage, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 120, 2, 1,
         1, 100, 20
       ) returning * into v_with_fees;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, fees, slippage, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 120, null, null,
         1, 100, 20
       ) returning * into v_no_fees;
       if public.pnl_net(v_with_fees) <> 17 then
         raise exception 'pnl_net avec fees=2, slippage=1 : attendu 17, trouvé %', public.pnl_net(v_with_fees);
       end if;
       if public.pnl_net(v_no_fees) <> 20 then
         raise exception 'pnl_net avec fees/slippage null : attendu 20 (coalesce 0), trouvé %', public.pnl_net(v_no_fees);
       end if;
     end $$ $$,
  'pnl_net : realized_pnl_gross - fees - slippage, nullables traités comme 0'
);

-- ============================================================================
-- Test 9 : rendement_pct — pnl_net / initial_capital * 100
-- ============================================================================
-- Trade : long, realized=20, initial_capital=100 → rendement = 20/100*100 = 20%
-- On utilise initial_capital (pas capital restant), conformément au fix.
select lives_ok(
  $$ do $$
     declare
       v_trade public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 120,
         1, 100, 20
       ) returning * into v_trade;
       if abs(public.rendement_pct(v_trade) - 20) > 0.0001 then
         raise exception 'rendement_pct : attendu 20, trouvé %', public.rendement_pct(v_trade);
       end if;
     end $$ $$,
  'rendement_pct : pnl_net / initial_capital * 100 (basé sur capital initial, pas restant)'
);

-- ============================================================================
-- Test 10 : r_multiple — pnl_net / risk_amount (basé sur initial_quantity)
-- ============================================================================
-- Trade : long, entry=100, exit=120, qty=1, stop_loss=90, realized=20
-- risk = |100-90|*initial_quantity(1) = 10, R = 20/10 = 2.0
-- Et fallback : sans stop_loss mais avec risk_percent=2 → risk=2*initial_capital
-- Note : on utilise initial_quantity et initial_capital, pas les valeurs
-- restantes (cf. migration 004 fix).
select lives_ok(
  $$ do $$
     declare
       v_with_sl public.trades;
       v_with_pct public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 90, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 120,
         1, 100, 20
       ) returning * into v_with_sl;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, risk_percent, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 2.0, 'closed',
         now() - interval '2 hour', now() - interval '2 hour',
         now() - interval '1 hour', 120,
         1, 100, 20
       ) returning * into v_with_pct;
       if abs(public.r_multiple(v_with_sl) - 2.0) > 0.0001 then
         raise exception 'R avec stop_loss : attendu 2.0, trouvé %', public.r_multiple(v_with_sl);
       end if;
       if abs(public.r_multiple(v_with_pct) - 10.0) > 0.0001 then
         raise exception 'R avec risk_percent : attendu 10.0, trouvé %', public.r_multiple(v_with_pct);
       end if;
     end $$ $$,
  'r_multiple : pnl_net / risk_amount (basé sur initial_quantity/initial_capital, pas restant)'
);

-- ============================================================================
-- Test 11 : winrate — % de trades gagnants parmi les closed
-- ============================================================================
-- 3 trades closed : 2 gagnants, 1 perdant → 66.66...%
-- 0 trade → NULL
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000003'::uuid;
       v_winrate numeric;
       v_null_winrate numeric;
       v_count int;
     begin
       -- Nettoyer les trades du test user pour avoir un état propre
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       -- 2 gagnants
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour', 110,
               1, 100, 10);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 105,
               1, 100, 5);
       -- 1 perdant
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '30 minutes', 90,
               1, 100, -10);
       v_winrate := public.winrate(v_user_id);
       if abs(v_winrate - (200.0/3.0)) > 0.0001 then
         raise exception 'winrate : attendu 66.66..., trouvé %', v_winrate;
       end if;
       -- 0 trade closed pour un user frais
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       v_null_winrate := public.winrate(v_user_id);
       if v_null_winrate is not null then
         raise exception 'winrate sans trade : attendu NULL, trouvé %', v_null_winrate;
       end if;
     end $$ $$,
  'winrate : 2/3 trades gagnants = 66.66%, 0 trade = NULL'
);

-- ============================================================================
-- Test 12 : profit_factor — sum(gains) / |sum(pertes)|
-- ============================================================================
-- Trades closed : gains 30+20=50, pertes |−10|=10 → PF = 50/10 = 5.0
-- Que des gagnants → NULL
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000003'::uuid;
       v_pf numeric;
       v_null_pf numeric;
     begin
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       -- gains : +30 et +20
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour', 130,
               1, 100, 30);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 120,
               1, 100, 20);
       -- perte : -10
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '30 minutes', 90,
               1, 100, -10);
       v_pf := public.profit_factor(v_user_id);
       if abs(v_pf - 5.0) > 0.0001 then
         raise exception 'profit_factor : attendu 5.0, trouvé %', v_pf;
       end if;
       -- Que des gagnants → NULL
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 110,
               1, 100, 10);
       v_null_pf := public.profit_factor(v_user_id);
       if v_null_pf is not null then
         raise exception 'profit_factor sans perte : attendu NULL, trouvé %', v_null_pf;
       end if;
     end $$ $$,
  'profit_factor : sum(gains)/|sum(pertes)|, NULL si que des gagnants'
);

-- ============================================================================
-- Test 13 : expectancy — winrate * avg_win + (1-winrate) * avg_loss
-- ============================================================================
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000003'::uuid;
       v_exp numeric;
       v_only_wins numeric;
       v_only_losses numeric;
     begin
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       -- 2 gagnants
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour', 120,
               1, 100, 20);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 110,
               1, 100, 10);
       -- 1 perdant
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '30 minutes', 70,
               1, 100, -30);
       v_exp := public.expectancy(v_user_id);
       if abs(v_exp) > 0.0001 then
         raise exception 'expectancy : attendu 0, trouvé %', v_exp;
       end if;
       -- Que des gagnants : +20, +30 → avg_win=25, expectancy=25
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour', 120,
               1, 100, 20);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 130,
               1, 100, 30);
       v_only_wins := public.expectancy(v_user_id);
       if abs(v_only_wins - 25) > 0.0001 then
         raise exception 'expectancy que gagnants : attendu 25, trouvé %', v_only_wins;
       end if;
       -- Que des perdants : -10, -20 → avg_loss=-15, expectancy=-15
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour', 90,
               1, 100, -10);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 80,
               1, 100, -20);
       v_only_losses := public.expectancy(v_user_id);
       if abs(v_only_losses - (-15)) > 0.0001 then
         raise exception 'expectancy que perdants : attendu -15, trouvé %', v_only_losses;
       end if;
     end $$ $$,
  'expectancy : winrate*avg_win + (1-winrate)*avg_loss, gère les cas limites'
);

-- ============================================================================
-- Test 14 : max_drawdown — pire drawdown sur equity curve
-- ============================================================================
-- Scénario : 3 trades closed ordonnés par closed_at croissant. fees=NULL et
-- slippage=NULL → pnl_net = realized_pnl_gross (coalesce 0). La fonction
-- calcule l'equity cumulée, le peak glissant, et retourne
-- max(peak - equity) sur toute la courbe.
--
--   # | closed_at | realized | equity cumulée | peak courant | drawdown
--   1 | -3h       | +50      | 50             | 50           | 0
--   2 | -2h       | +30      | 80             | 80           | 0
--   3 | -1h       | -70      | 10             | 80           | 70
--
-- max_drawdown attendu = 70 (PAS 100 — l'écart de 30 vient du fait que
-- le 3e trade a exit_price=30, donc le calcul (30-100)*1*1=-70 reste
-- cohérent avec lui-même, mais ne représente pas une perte sèche
-- jusqu'à zéro).
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000003'::uuid;
       v_dd numeric;
       v_null_dd numeric;
     begin
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '3 hour', 150,
               1, 100, 50);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour', 130,
               1, 100, 30);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, exit_price, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, (select id from public.instruments where symbol = 'TESTUSD3'), 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour', 30,
               1, 100, -70);
       v_dd := public.max_drawdown(v_user_id);
       if abs(v_dd - 70) > 0.0001 then
         raise exception 'max_drawdown : attendu 70, trouvé %', v_dd;
       end if;
       -- 0 trade
       delete from public.trade_events where user_id = v_user_id;
       delete from public.trades where user_id = v_user_id;
       v_null_dd := public.max_drawdown(v_user_id);
       if v_null_dd is not null then
         raise exception 'max_drawdown sans trade : attendu NULL, trouvé %', v_null_dd;
       end if;
     end $$ $$,
  'max_drawdown : pire drawdown sur equity curve, NULL si 0 trade'
);

-- ============================================================================
-- Test 15 : fee_profiles seed — 16 lignes attendues
-- ============================================================================
select is(
  $$ select count(*)::int from public.fee_profiles $$,
  16::int,
  'fee_profiles seed : 16 lignes attendues (binance + kraken × 4 asset_class × 2 order_type)'
);

-- ============================================================================
-- Test 16a : _direction_multiplier(long) = +1
-- ============================================================================
select is(
  $$ select public._direction_multiplier('long'::public.trade_direction) $$,
  1::int,
  '_direction_multiplier(long) = +1'
);

-- ============================================================================
-- Test 16b : _direction_multiplier(short) = -1
-- ============================================================================
select is(
  $$ select public._direction_multiplier('short'::public.trade_direction) $$,
  -1::int,
  '_direction_multiplier(short) = -1'
);

-- ============================================================================
-- Test 17 : mae / mfe nullables par défaut
-- ============================================================================
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_mae numeric;
       v_mfe numeric;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100
       )
       returning id into v_trade_id;
       select mae, mfe into v_mae, v_mfe
       from public.trades where id = v_trade_id;
       if v_mae is not null then
         raise exception 'mae doit être NULL par défaut, trouvé %', v_mae;
       end if;
       if v_mfe is not null then
         raise exception 'mfe doit être NULL par défaut, trouvé %', v_mfe;
       end if;
     end $$ $$,
  'mae et mfe sont NULL par défaut (colonnes prêtes, valeurs en attente Phase 5)'
);

-- ============================================================================
-- Test 18 : record_partial_exit — trade d'un autre user (RLS + WHERE) → REFUSÉ
-- ============================================================================
-- Le WHERE user_id = auth.uid() doit bloquer même si la RLS laisse passer.
-- Message commence par 'Trade introuvable...' (le trade existe mais
-- auth.uid() ne matche pas le user_id du trade).
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000002',
         true
       );
       perform public.record_partial_exit(v_trade_id, 110, 0.5);
     end $$ $$,
  'Trade introuvable%',
  'record_partial_exit refuse les trades d''un autre user (WHERE user_id = auth.uid())'
);

-- ============================================================================
-- Test 19 : record_partial_exit — p_exit_price <= 0 → REFUSÉ
-- ============================================================================
-- Message : 'p_exit_price doit être strictement positif (whitepaper §06)'
-- Pattern : 'p_exit_price doit être strictement positif%' (le % capte le
-- suffixe entre parenthèses)
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       perform public.record_partial_exit(v_trade_id, 0, 0.5);
     end $$ $$,
  'p_exit_price doit être strictement positif%',
  'record_partial_exit refuse p_exit_price <= 0'
);

-- ============================================================================
-- Test 20 : COMBINÉ — record_partial_exit PUIS transition_trade(closed)
--               sur le même trade. Vérifie que realized_pnl_gross cumule
--               correctement les legs et que pnl_gross / rendement_pct /
--               r_multiple sont exacts sur le total.
-- ============================================================================
-- C'EST LE TEST CRITIQUE qui aurait attrapé le bug de fond identifié
-- en revue : sans realized_pnl_gross, pnl_gross calculait
-- (exit - entry) * quantity_restante, ce qui sous-estimait
-- silencieusement les gains et pouvait inverser le signe.
--
-- Scénario (repris du retour du chef) :
--   long, entry=100, initial_quantity=10, initial_capital=1000, stop_loss=95
--   - record_partial_exit(v_trade_id, 120, 4) :
--       leg = (120-100)*4*1 = +80
--       realized_pnl_gross = 0 + 80 = 80
--       quantity → 6, capital → 600
--   - transition_trade(v_trade_id, 'closed', 90) :
--       leg_final = (90-100)*6*1 = -60 (sur la quantité restante)
--       realized_pnl_gross = 80 + (-60) = 20
--       status → closed, exit_price → 90
--   - pnl_gross = realized_pnl_gross = +20 (gagnant !)
--     L'ancien calcul aurait donné (90-100)*6*1 = -60 (perdant !) — bug
--   - rendement_pct = 20/initial_capital(1000)*100 = +2%
--     L'ancien calcul aurait donné -60/capital(600)*100 = -10% — bug
--   - r_multiple avec stop_loss=95 :
--       risk = |100-95|*initial_quantity(10) = 50 (PAS quantity=6)
--       R = 20/50 = +0.4
--     L'ancien calcul aurait donné risk = 5*6 = 30 → R = 20/30 = 0.67
--     (gonflé car la quantity restante sous-estime le risque)
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_after_partial public.trades;
       v_after_close public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 95, 10, 1000, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         10, 1000
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       -- 1. Sortie partielle : 4 unités à 120, leg=+80
       select * into v_after_partial from public.record_partial_exit(v_trade_id, 120, 4);
       if v_after_partial.realized_pnl_gross <> 80 then
         raise exception 'après partial_exit : realized=80 attendu, trouvé %', v_after_partial.realized_pnl_gross;
       end if;
       if v_after_partial.quantity <> 6 then
         raise exception 'après partial_exit : quantity=6 attendu, trouvé %', v_after_partial.quantity;
       end if;
       if v_after_partial.capital <> 600 then
         raise exception 'après partial_exit : capital=600 attendu, trouvé %', v_after_partial.capital;
       end if;
       if v_after_partial.initial_quantity <> 10 then
         raise exception 'initial_quantity ne doit pas changer (toujours 10), trouvé %', v_after_partial.initial_quantity;
       end if;
       if v_after_partial.initial_capital <> 1000 then
         raise exception 'initial_capital ne doit pas changer (toujours 1000), trouvé %', v_after_partial.initial_capital;
       end if;
       -- 2. Clôture finale : exit 90 sur les 6 restantes, leg=-60
       select * into v_after_close from public.transition_trade(v_trade_id, 'closed'::public.trade_status, 90);
       -- realized_pnl_gross total = 80 + (-60) = +20
       if v_after_close.realized_pnl_gross <> 20 then
         raise exception 'après close : realized=20 attendu (80 + -60), trouvé %', v_after_close.realized_pnl_gross;
       end if;
       if v_after_close.status <> 'closed' then
         raise exception 'status doit être closed';
       end if;
       if v_after_close.exit_price <> 90 then
         raise exception 'exit_price doit être 90, trouvé %', v_after_close.exit_price;
       end if;
       -- 3. pnl_gross = realized = +20 (gagnant, PAS -60 comme avant le fix)
       if public.pnl_gross(v_after_close) <> 20 then
         raise exception 'pnl_gross : 20 attendu (réalisé cumulé), trouvé % (bug du fix si négatif)', public.pnl_gross(v_after_close);
       end if;
       -- 4. rendement_pct = 20/initial_capital(1000)*100 = +2%
       if abs(public.rendement_pct(v_after_close) - 2.0) > 0.0001 then
         raise exception 'rendement_pct : 2.0 attendu, trouvé % (basé sur initial_capital)', public.rendement_pct(v_after_close);
       end if;
       -- 5. r_multiple : risk = |100-95|*initial_quantity(10) = 50, R = 20/50 = 0.4
       if abs(public.r_multiple(v_after_close) - 0.4) > 0.0001 then
         raise exception 'r_multiple : 0.4 attendu (basé sur initial_quantity), trouvé %', public.r_multiple(v_after_close);
       end if;
     end $$ $$,
  'COMBINÉ partial_exit+close : realized_pnl_gross cumule, pnl_gross=20, rendement=2%, r_multiple=0.4 (le test qui aurait attrapé le bug)'
);

-- ============================================================================
-- Test 21 : publish_trade — snapshot initial_quantity/initial_capital
-- ============================================================================
-- Comble le trou de couverture identifié en revue : aucun des 20
-- tests précédents n'appelait publish_trade(), ce qui a laissé passer
-- une régression subtile (utilisation de `old.quantity`/`old.capital`
-- dans un UPDATE, OLD/NEW n'existent qu'en trigger — bug critique
-- qui aurait cassé soit l'application de la migration, soit chaque
-- publication en prod, et aurait fait échouer rétroactivement les
-- tests 7 et 8 de 02_trades_lifecycle_test.sql).
--
-- INSERT d'un draft avec quantity=7, capital=700. publish_trade doit
-- snapshoter ces valeurs dans initial_quantity/initial_capital, poser
-- status='live' + published_at + opened_at, le tout dans un seul
-- UPDATE atomique.
--
-- Note : publish_trade est SECURITY INVOKER (PostgreSQL default,
-- aucune SECURITY clause dans la migration 002 originelle), donc
-- il faut set_config le JWT claim avant l'appel.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_result public.trades;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status)
       values (
         '00000000-0000-0000-0000-000000000003'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD3'),
         'long', 100, 7, 700, 'draft'
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000003',
         true
       );
       select * into v_result from public.publish_trade(v_trade_id);
       if v_result.status <> 'live' then
         raise exception 'status doit être live, trouvé %', v_result.status;
       end if;
       if v_result.published_at is null then
         raise exception 'published_at doit être posé';
       end if;
       if v_result.opened_at is null then
         raise exception 'opened_at doit être posé';
       end if;
       -- Le snapshot : initial_quantity et initial_capital doivent
       -- refléter quantity et capital au moment de la publication
       -- (7 et 700 respectivement dans ce test).
       if v_result.initial_quantity <> 7 then
         raise exception 'initial_quantity doit être 7 (snapshot), trouvé %', v_result.initial_quantity;
       end if;
       if v_result.initial_capital <> 700 then
         raise exception 'initial_capital doit être 700 (snapshot), trouvé %', v_result.initial_capital;
       end if;
     end $$ $$,
  'publish_trade : draft → live + snapshot initial_quantity=7, initial_capital=700'
);

select * from finish();
rollback;
