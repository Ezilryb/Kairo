-- /supabase/tests/05_market_data_test.sql
-- =============================================================================
-- Tests pgTAP pour la Phase 5 — Market Data & Graphismes (whitepaper §08).
-- Couvre UNIQUEMENT le RPC set_trade_excursion (le seul bout SQL de la
-- phase). Le MarketDataProvider, les composants chart/replay et l'endpoint
-- /api/trades/[id]/mae-mfe sont testés via le protocole de test manuel
-- (docs/TESTING_PHASE5.md) — pas de pgTAP possible sur du TypeScript.
--
-- Conventions identiques à 03_financial_calcs_test.sql / 04_analytics_test.sql :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Chaque test autosuffisant (setup + assertions dans le même do $$)
--   - SECURITY INVOKER : on pose set_config('request.jwt.claim.sub', ...)
--     avant l'appel RPC
--
-- Users dédiés :
--   00000000-0000-0000-0000-000000000006 — user A (proprio principal)
--   00000000-0000-0000-0000-000000000007 — user B (test RLS / autre proprio)
-- Instrument dédié : TESTUSD5 (crypto pour MAE/MFE).
--
-- Plan : 5 assertions
-- 1 : trade inexistant → REFUSÉ
-- 2 : trade non closed (live) → REFUSÉ
-- 3 : trade d'un autre user (RLS) → REFUSÉ
-- 4 : trade d'un autre user en is_public=false (RLS privé) → REFUSÉ
-- 5 : trade closed valide → MAE/MFE persistés OK
-- =============================================================================

begin;

-- Setup : instrument + 2 users de la suite
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD5', 'Test Asset 5', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000006'::uuid, 'test+setup6@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000006'::uuid, 'test_setup6')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000007'::uuid, 'test+setup7@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000007'::uuid, 'test_setup7')
on conflict (id) do nothing;

select plan(5);

-- ============================================================================
-- Test 1 : trade inexistant → REFUSÉ
-- ============================================================================
select throws_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000006'::uuid;
     begin
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       perform public.set_trade_excursion(
         '00000000-0000-0000-0000-deadbeef0000'::uuid,  -- UUID inexistant
         10.5, 25.3
       );
     end $$ $$,
  'Trade introuvable%',
  'set_trade_excursion refuse un trade_id inexistant'
);

-- ============================================================================
-- Test 2 : trade non closed (status=live) → REFUSÉ
-- ============================================================================
select throws_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000006'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD5');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'live',
               now() - interval '1 hour', now() - interval '1 hour',
               1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       perform public.set_trade_excursion(v_trade_id, 5.0, 15.0);
     end $$ $$,
  'Trade introuvable, non autorisé, ou non closed%',
  'set_trade_excursion refuse un trade encore live (status != ''closed'')'
);

-- ============================================================================
-- Test 3 : trade d'un autre user (check explicite user_id = auth.uid)
-- ============================================================================
-- User A crée un trade CLOSED, user B essaie de poser mae/mfe.
-- Mécanisme exercé : le check explicite `IF v_user_id <> auth.uid()` du
-- RPC. Le trade ici n'a pas `is_public=false` (donc la RLS laisse passer
-- le SELECT — politique `is_public OR auth.uid() = user_id`), donc le
-- SELECT retourne bien 1 row ; c'est ensuite le `v_user_id <> auth.uid()`
-- qui raise. Le test 4 ci-dessous couvre l'autre couche (RLS privée).
-- Les deux tests sont complémentaires : chacun exerce une des deux
-- couches de défense (SQL explicite vs RLS).
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000006'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000007'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD5');
       -- User A crée un trade CLOSED (is_public=true par défaut)
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 20)
       returning id into v_trade_id;
       -- User B essaie d'écrire mae/mfe sur le trade de A
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       perform public.set_trade_excursion(v_trade_id, 5.0, 15.0);
     end $$ $$,
  'Trade introuvable%',
  'set_trade_excursion refuse un trade d''un autre user (check explicite user_id = auth.uid, RLS laisse passer le SELECT car is_public=true)'
);

-- ============================================================================
-- Test 4 : trade d'un autre user en is_public=false (privé) → REFUSÉ
-- ============================================================================
-- Variante du test 3 : le trade est explicitement privé (is_public=false).
-- Même user B ne doit pas pouvoir y toucher via RLS (le SELECT retourne 0 row).
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000006'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000007'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD5');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, is_public, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               false, 1, 100, 20)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       perform public.set_trade_excursion(v_trade_id, 5.0, 15.0);
     end $$ $$,
  'Trade introuvable%',
  'set_trade_excursion refuse un trade privé d''un autre user (RLS bloque)'
);

-- ============================================================================
-- Test 5 : trade closed valide → MAE/MFE persistés OK
-- ============================================================================
-- User A crée un trade CLOSED, user A pose mae/mfe → doit réussir.
-- On vérifie ensuite que les colonnes mae/mfe sont bien remplies.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000006'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_mae numeric;
       v_mfe numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD5');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 20)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       perform public.set_trade_excursion(v_trade_id, 12.5, 35.7);
       -- Vérifier que mae/mfe sont bien persistés
       select mae, mfe into v_mae, v_mfe
       from public.trades where id = v_trade_id;
       if v_mae <> 12.5 then
         raise exception 'mae doit être 12.5, trouvé %', v_mae;
       end if;
       if v_mfe <> 35.7 then
         raise exception 'mfe doit être 35.7, trouvé %', v_mfe;
       end if;
     end $$ $$,
  'set_trade_excursion persiste mae=12.5 et mfe=35.7 sur un trade CLOSED valide'
);

select * from finish();
rollback;
