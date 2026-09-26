-- /supabase/tests/04_analytics_test.sql
-- =============================================================================
-- Tests pgTAP pour la Phase 4 — Analytics Engine avancé (whitepaper §07).
-- Conventions identiques à 03_financial_calcs_test.sql :
--   - begin/rollback autour du test, plan() en tête, finish() en fin
--   - Chaque test est autosuffisant : setup + assertions dans le même do $$
--   - JAMAIS deux appels à now() comparés sans backdating explicite
--   - SECURITY INVOKER : on pose set_config('request.jwt.claim.sub', ...)
--     avant les appels RPC qui dépendent de auth.uid() (analytics_crosstab
--     en particulier). plan_adherence_score lit le trade en argument, pas
--     via auth.uid() — pas de set_config nécessaire.
--
-- Users dédiés :
--   00000000-0000-0000-0000-000000000004 — test user principal (cf. 03 = 0003)
--   00000000-0000-0000-0000-000000000005 — autre user pour les tests RLS
--     (cf. 02 = 0002)
-- Instrument dédié : TESTUSD4.
--
-- Plan : 30 assertions (cf. détail ci-dessous)
-- A. Colonnes setup / timeframe (4 tests)
-- 1  : setup + timeframe NULL par défaut
-- 2  : setup accepte texte libre (chaîne unicode)
-- 3  : timeframe valeur valide '1h' OK
-- 4  : timeframe valeur invalide REFUSÉ (throws_ok)
-- B. Trigger log_entry_price_changes (3 tests)
-- 5  : modif entry_price sur live dans fenêtre 60s → 1 event entry_modified
-- 6  : modif sur draft / valeur identique / autres colonnes → 0 event
-- 7  : modif entry_price après 60s → REFUSÉ par enforce_entry_price_immutability
-- C. Helpers privés (3 tests)
-- 8  : _trading_session — 7 cas (3 buckets + 4 frontières)
-- 9  : _day_of_week — 1 cas de référence
-- 10 : _duration_bucket — 6 cas (5 buckets + unknown)
-- D. plan_adherence_score (8 tests)
-- 11 : trade live → NULL
-- 12 : trade parfait (0 modif, SL OK, pas de mistake) = 100
-- 13 : 1 entry_modified = 90
-- 14 : 2 entry_modified = 80
-- 15 : 1 sl_modified = 90
-- 16 : sans stop_loss = 75
-- 17 : mistake sl_non_respecte + stop_loss NOT NULL = 75
-- 18 : combinaison (entry 1 + sl 2 + tp 1 + stop_loss NULL) = 35
-- E. analytics_crosstab (10 tests)
-- 19 : 0 trade
-- 20 : sans filtre, count + winrate corrects
-- 21 : filtre par direction
-- 22 : filtre par instrument (test isolé : TESTUSD4=0, TESTUSD4B=1)
-- 23 : filtre par session
-- 24 : filtre par setup
-- 25 : filtre par timeframe
-- 26 : filtre par p_since
-- 29 : filtre par p_day_of_week
-- 30 : filtre par p_duration_bucket
-- F. RLS sur analytics_crosstab (2 tests)
-- 27 : user B ne voit PAS les trades privés de user A
-- 28 : user A voit TOUS ses trades (privés + publics)
-- =============================================================================

begin;

-- Setup : instrument + 2 users de la suite (user A = 0004, user B = 0005)
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD4', 'Test Asset 4', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000004'::uuid, 'test+setup4@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000004'::uuid, 'test_setup4')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000005'::uuid, 'test+setup5@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000005'::uuid, 'test_setup5')
on conflict (id) do nothing;

select plan(30);

-- ============================================================================
-- A. COLONNES setup / timeframe
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 1 : setup + timeframe NULL par défaut
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_setup text;
       v_timeframe public.trade_timeframe;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'closed',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100, 0
       )
       returning id into v_trade_id;
       select setup, timeframe into v_setup, v_timeframe
       from public.trades where id = v_trade_id;
       if v_setup is not null then
         raise exception 'setup doit être NULL par défaut, trouvé %', v_setup;
       end if;
       if v_timeframe is not null then
         raise exception 'timeframe doit être NULL par défaut, trouvé %', v_timeframe;
       end if;
     end $$ $$,
  'setup + timeframe sont NULL par défaut'
);

-- ----------------------------------------------------------------------------
-- Test 2 : setup accepte texte libre (chaîne unicode)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_setup text;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital, realized_pnl_gross, setup)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'closed',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100, 0,
         'pullback EMA20 — range H4 cassé'
       )
       returning id into v_trade_id;
       select setup into v_setup from public.trades where id = v_trade_id;
       if v_setup <> 'pullback EMA20 — range H4 cassé' then
         raise exception 'setup doit accepter texte libre, trouvé %', v_setup;
       end if;
     end $$ $$,
  'setup accepte texte libre (chaîne unicode avec tirets et espaces)'
);

-- ----------------------------------------------------------------------------
-- Test 3 : timeframe valeur valide '1h' OK
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_timeframe public.trade_timeframe;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital, realized_pnl_gross, timeframe)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'closed',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100, 0,
         '1h'
       )
       returning id into v_trade_id;
       select timeframe into v_timeframe from public.trades where id = v_trade_id;
       if v_timeframe <> '1h' then
         raise exception 'timeframe doit être 1h, trouvé %', v_timeframe;
       end if;
     end $$ $$,
  'timeframe accepte valeur valide ''1h'''
);

-- ----------------------------------------------------------------------------
-- Test 4 : timeframe valeur invalide '2h' REFUSÉ
-- ----------------------------------------------------------------------------
-- L'enum trade_timeframe ne contient pas '2h' (seulement 1m, 5m, 15m, 30m,
-- 1h, 4h, 1d, 1w). L'INSERT doit lever.
select throws_ok(
  $$ do $$
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital, realized_pnl_gross, timeframe)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'closed',
         now() - interval '1 hour', now() - interval '1 hour',
         1, 100, 0,
         '2h'
       );
     end $$ $$,
  'invalid input value for enum%',
  'timeframe refuse valeur invalide (2h n''est pas dans l''enum trade_timeframe)'
);

-- ============================================================================
-- B. TRIGGER log_entry_price_changes
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 5 : modif entry_price sur live dans fenêtre 60s → 1 event
-- ----------------------------------------------------------------------------
-- Le trade doit être live (status != 'draft'), published_at posé, et la
-- modif faite avant published_at + 60s. Le trigger log_entry_price_changes
-- doit créer 1 event de type entry_modified avec old/new entry_price.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_event_count int;
       v_event jsonb;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'live',
         now() - interval '10 seconds', now() - interval '10 seconds',
         1, 100
       )
       returning id into v_trade_id;
       -- Modif entry_price dans la fenêtre 60s (10s après publish)
       update public.trades
       set entry_price = 101
       where id = v_trade_id;
       -- Vérifier qu'un event entry_modified a été créé
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'entry_modified';
       if v_event_count <> 1 then
         raise exception 'attendu 1 event entry_modified, trouvé %', v_event_count;
       end if;
       -- Vérifier old_values.entry_price = 100 et new_values.entry_price = 101
       select new_values into v_event
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'entry_modified';
       if (v_event->>'entry_price')::numeric <> 101 then
         raise exception 'new_values.entry_price doit être 101, trouvé %', v_event->>'entry_price';
       end if;
     end $$ $$,
  'modif entry_price sur live dans fenêtre 60s → 1 event entry_modified (old=100, new=101)'
);

-- ----------------------------------------------------------------------------
-- Test 6 : draft / valeur identique / autres colonnes → 0 event
-- ----------------------------------------------------------------------------
-- On groupe 3 cas qui doivent tous donner 0 event entry_modified :
--   (a) trade en draft : filtre old.status <> 'draft' bloque
--   (b) UPDATE entry_price vers la même valeur : filtre is distinct from bloque
--   (c) UPDATE stop_loss (pas entry_price) : pas de modif entry_price
select lives_ok(
  $$ do $$
     declare
       v_trade_draft_id uuid;
       v_trade_idem_id uuid;
       v_trade_sl_id uuid;
       v_event_count int;
     begin
       -- (a) Trade draft : UPDATE entry_price ne doit PAS logger
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'draft',
         1, 100
       )
       returning id into v_trade_draft_id;
       update public.trades set entry_price = 105 where id = v_trade_draft_id;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_draft_id and event_type = 'entry_modified';
       if v_event_count <> 0 then
         raise exception 'cas (a) draft : attendu 0 event, trouvé %', v_event_count;
       end if;
       -- (b) Trade live, UPDATE entry_price vers la même valeur : 0 event
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'live',
         now() - interval '5 seconds', now() - interval '5 seconds',
         1, 100
       )
       returning id into v_trade_idem_id;
       update public.trades set entry_price = 100 where id = v_trade_idem_id;  -- même valeur
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_idem_id and event_type = 'entry_modified';
       if v_event_count <> 0 then
         raise exception 'cas (b) valeur identique : attendu 0 event, trouvé %', v_event_count;
       end if;
       -- (c) Trade live, UPDATE stop_loss (pas entry_price) : 0 event entry_modified
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 90, 1, 100, 'live',
         now() - interval '5 seconds', now() - interval '5 seconds',
         1, 100
       )
       returning id into v_trade_sl_id;
       update public.trades set stop_loss = 88 where id = v_trade_sl_id;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_sl_id and event_type = 'entry_modified';
       if v_event_count <> 0 then
         raise exception 'cas (c) modif SL : attendu 0 event entry_modified, trouvé %', v_event_count;
       end if;
     end $$ $$,
  '3 cas qui ne doivent PAS logger d''event entry_modified : draft, valeur identique, modif SL seule'
);

-- ----------------------------------------------------------------------------
-- Test 7 : modif entry_price APRÈS 60s → REFUSÉ
-- ----------------------------------------------------------------------------
-- enforce_entry_price_immutability bloque en BEFORE UPDATE, donc log_entry_price_changes
-- (AFTER UPDATE) ne se déclenche jamais.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'live',
         now() - interval '2 minutes', now() - interval '2 minutes',
         1, 100
       )
       returning id into v_trade_id;
       update public.trades set entry_price = 110 where id = v_trade_id;
     end $$ $$,
  'entry_price est immuable%',
  'modif entry_price après 60s refusée par enforce_entry_price_immutability'
);

-- ============================================================================
-- C. HELPERS PRIVÉS (_trading_session, _day_of_week, _duration_bucket)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 8 : _trading_session — 7 cas (3 buckets + 4 frontières)
-- ----------------------------------------------------------------------------
-- Buckets UTC fixes non chevauchants :
--   - asia   : 00:00 - 07:59
--   - europe : 08:00 - 15:59
--   - us     : 16:00 - 23:59
-- Frontières à tester : 07:59 (asia), 08:00 (europe), 15:59 (europe), 16:00 (us).
select lives_ok(
  $$ do $$
     declare
       v_s text;
     begin
       -- Milieux de buckets
       v_s := public._trading_session('2026-09-05 03:00:00+00'::timestamptz);  -- 03:00 UTC = asia
       if v_s <> 'asia' then raise exception '03:00 UTC doit être asia, trouvé %', v_s; end if;
       v_s := public._trading_session('2026-09-05 12:00:00+00'::timestamptz);  -- 12:00 UTC = europe
       if v_s <> 'europe' then raise exception '12:00 UTC doit être europe, trouvé %', v_s; end if;
       v_s := public._trading_session('2026-09-05 20:00:00+00'::timestamptz);  -- 20:00 UTC = us
       if v_s <> 'us' then raise exception '20:00 UTC doit être us, trouvé %', v_s; end if;
       -- Frontières
       v_s := public._trading_session('2026-09-05 07:59:00+00'::timestamptz);  -- limite asia
       if v_s <> 'asia' then raise exception '07:59 UTC doit être asia, trouvé %', v_s; end if;
       v_s := public._trading_session('2026-09-05 08:00:00+00'::timestamptz);  -- bascule europe
       if v_s <> 'europe' then raise exception '08:00 UTC doit être europe, trouvé %', v_s; end if;
       v_s := public._trading_session('2026-09-05 15:59:00+00'::timestamptz);  -- limite europe
       if v_s <> 'europe' then raise exception '15:59 UTC doit être europe, trouvé %', v_s; end if;
       v_s := public._trading_session('2026-09-05 16:00:00+00'::timestamptz);  -- bascule us
       if v_s <> 'us' then raise exception '16:00 UTC doit être us, trouvé %', v_s; end if;
     end $$ $$,
  '_trading_session : 3 buckets (03/12/20 UTC) + 4 frontières (07:59/08:00/15:59/16:00 UTC)'
);

-- ----------------------------------------------------------------------------
-- Test 9 : _day_of_week — 1 cas de référence
-- ----------------------------------------------------------------------------
-- 2026-01-04 est un dimanche selon le calendrier grégorien. dow = 0.
select is(
  $$ select public._day_of_week('2026-01-04 12:00:00+00'::timestamptz) $$,
  0::int,
  '_day_of_week(2026-01-04 dimanche) = 0'
);

-- ----------------------------------------------------------------------------
-- Test 10 : _duration_bucket — 6 cas
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_b text;
     begin
       v_b := public._duration_bucket(null);                          -- unknown
       if v_b <> 'unknown' then raise exception 'NULL doit être unknown, trouvé %', v_b; end if;
       v_b := public._duration_bucket(interval '5 minutes');         -- lt_15m
       if v_b <> 'lt_15m' then raise exception '5min doit être lt_15m, trouvé %', v_b; end if;
       v_b := public._duration_bucket(interval '30 minutes');        -- 15m_1h
       if v_b <> '15m_1h' then raise exception '30min doit être 15m_1h, trouvé %', v_b; end if;
       v_b := public._duration_bucket(interval '2 hours');           -- 1h_4h
       if v_b <> '1h_4h' then raise exception '2h doit être 1h_4h, trouvé %', v_b; end if;
       v_b := public._duration_bucket(interval '12 hours');          -- 4h_1d
       if v_b <> '4h_1d' then raise exception '12h doit être 4h_1d, trouvé %', v_b; end if;
       v_b := public._duration_bucket(interval '3 days');            -- gt_1d
       if v_b <> 'gt_1d' then raise exception '3d doit être gt_1d, trouvé %', v_b; end if;
     end $$ $$,
  '_duration_bucket : 5 buckets (lt_15m, 15m_1h, 1h_4h, 4h_1d, gt_1d) + ''unknown'' pour NULL'
);

-- ============================================================================
-- D. plan_adherence_score
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 11 : trade live → NULL
-- ----------------------------------------------------------------------------
select is(
  $$ select public.plan_adherence_score(t.*) from public.trades t
     where t.user_id = '00000000-0000-0000-0000-000000000004'::uuid
       and t.status = 'live' limit 1 $$,
  null::integer,
  'plan_adherence_score(trade live) = NULL'
);

-- ----------------------------------------------------------------------------
-- Test 12 : trade parfait = 100
-- ----------------------------------------------------------------------------
-- 0 entry_modified, 0 sl_modified, 0 tp_modified, SL présent, pas de mistake.
-- On insère un trade "parfait" pour ce test (self-contained : pas de dépendance
-- aux fixtures des autres tests).
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 90, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, 20
       )
       returning id into v_trade_id;
       -- Aucun event injecté, pas de mistake
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 100 then
         raise exception 'attendu 100 (entry=25 + sl=25 + tp=25 + risk=25), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(trade parfait, 0 modif, SL présent, pas de mistake) = 100'
);

-- ----------------------------------------------------------------------------
-- Test 13 : 1 entry_modified = 90 (entry=15, sl=25, tp=25, risk=25)
-- ----------------------------------------------------------------------------
-- On insère un trade closed avec 1 event entry_modified, puis on calcule.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 90, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, 20
       )
       returning id into v_trade_id;
       -- Injecter 1 event entry_modified directement (pas de modif réelle,
       -- on simule l'historique)
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
       values (
         v_trade_id,
         '00000000-0000-0000-0000-000000000004'::uuid,
         'entry_modified',
         '{"entry_price": 100}'::jsonb,
         '{"entry_price": 102}'::jsonb
       );
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 90 then
         raise exception 'attendu 90 (entry=15 + sl=25 + tp=25 + risk=25), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(1 entry_modified) = 90'
);

-- ----------------------------------------------------------------------------
-- Test 14 : 2 entry_modified = 80 (entry=5, sl=25, tp=25, risk=25)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 90, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, 20
       )
       returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
       values (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'entry_modified',
               '{"entry_price": 100}'::jsonb, '{"entry_price": 102}'::jsonb),
              (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'entry_modified',
               '{"entry_price": 102}'::jsonb, '{"entry_price": 103}'::jsonb);
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 80 then
         raise exception 'attendu 80 (entry=5 + sl=25 + tp=25 + risk=25), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(2 entry_modified) = 80'
);

-- ----------------------------------------------------------------------------
-- Test 15 : 1 sl_modified = 90 (entry=25, sl=15, tp=25, risk=25)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 90, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, 20
       )
       returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
       values (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'sl_modified',
               '{"stop_loss": 90}'::jsonb, '{"stop_loss": 88}'::jsonb);
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 90 then
         raise exception 'attendu 90 (entry=25 + sl=15 + tp=25 + risk=25), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(1 sl_modified) = 90'
);

-- ----------------------------------------------------------------------------
-- Test 16 : sans stop_loss = 75 (entry=25, sl=25, tp=25, risk=0)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, 20
       )
       returning id into v_trade_id;
       -- Pas d'event, stop_loss NULL
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 75 then
         raise exception 'attendu 75 (entry=25 + sl=25 + tp=25 + risk=0 car stop_loss NULL), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(sans stop_loss) = 75 (risk=0)'
);

-- ----------------------------------------------------------------------------
-- Test 17 : mistake sl_non_respecte + stop_loss NOT NULL = 75 (risk=0)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, stop_loss, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross, mistake_type)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 90, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, -20, 'sl_non_respecte'
       )
       returning id into v_trade_id;
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 75 then
         raise exception 'attendu 75 (entry=25 + sl=25 + tp=25 + risk=0 car mistake), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(mistake=sl_non_respecte, stop_loss NOT NULL) = 75 (risk=0)'
);

-- ----------------------------------------------------------------------------
-- Test 18 : combinaison (entry 1 + sl 2 + tp 1 + stop_loss NULL) = 35
--   entry=15, sl=5, tp=15, risk=0 → 15+5+15+0 = 35
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_score int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (
         '00000000-0000-0000-0000-000000000004'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD4'),
         'long', 100, 1, 100, 'closed',
         now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
         1, 100, 20
       )
       returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
       values (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'entry_modified',
               '{"entry_price": 100}'::jsonb, '{"entry_price": 102}'::jsonb),
              (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'sl_modified',
               '{"stop_loss": 90}'::jsonb, '{"stop_loss": 88}'::jsonb),
              (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'sl_modified',
               '{"stop_loss": 88}'::jsonb, '{"stop_loss": 85}'::jsonb),
              (v_trade_id, '00000000-0000-0000-0000-000000000004'::uuid, 'tp_modified',
               '{"take_profit": 120}'::jsonb, '{"take_profit": 125}'::jsonb);
       v_score := public.plan_adherence_score(t.*) from public.trades t where t.id = v_trade_id;
       if v_score <> 35 then
         raise exception 'attendu 35 (entry=15 + sl=5 + tp=15 + risk=0), trouvé %', v_score;
       end if;
     end $$ $$,
  'plan_adherence_score(combinaison entry 1 + sl 2 + tp 1 + stop_loss NULL) = 35'
);

-- ============================================================================
-- E. analytics_crosstab
-- ============================================================================
-- On nettoie les trades du user 0004 avant les tests E pour avoir un état
-- propre (sinon les trades des tests D faussent les compteurs).
-- Les events sont en ON DELETE CASCADE, donc nettoyer les trades suffit.

-- ----------------------------------------------------------------------------
-- Test 19 : 0 trade → count=0, winrate/avg = NULL
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_count bigint;
       v_wr numeric;
       v_avg_r numeric;
       v_avg_rdt numeric;
     begin
       delete from public.trades where user_id = v_user_id;
       -- set_config requis : SECURITY INVOKER + le RLS lit auth.uid()
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count, winrate, avg_r_multiple, avg_rendement_pct
         into v_count, v_wr, v_avg_r, v_avg_rdt
       from public.analytics_crosstab(v_user_id);
       if v_count <> 0 then raise exception 'count doit être 0, trouvé %', v_count; end if;
       if v_wr is not null then raise exception 'winrate doit être NULL, trouvé %', v_wr; end if;
       if v_avg_r is not null then raise exception 'avg_r_multiple doit être NULL, trouvé %', v_avg_r; end if;
       if v_avg_rdt is not null then raise exception 'avg_rendement_pct doit être NULL, trouvé %', v_avg_rdt; end if;
     end $$ $$,
  'analytics_crosstab : 0 trade → count=0, winrate/avg_r_multiple/avg_rendement_pct = NULL'
);

-- ----------------------------------------------------------------------------
-- Test 20 : sans filtre, count + winrate corrects
-- ----------------------------------------------------------------------------
-- 3 trades closed : 2 gagnants (PnL net > 0), 1 perdant → winrate = 66.66...%
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count bigint;
       v_wr numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       -- 2 gagnants
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '2 hour',
               1, 100, 10),
              (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '1 hour',
               1, 100, 5);
       -- 1 perdant
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '30 minutes',
               1, 100, -10);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count, winrate into v_count, v_wr
       from public.analytics_crosstab(v_user_id);
       if v_count <> 3 then raise exception 'count doit être 3, trouvé %', v_count; end if;
       if abs(v_wr - (200.0/3.0)) > 0.0001 then
         raise exception 'winrate doit être 66.66..., trouvé %', v_wr;
       end if;
     end $$ $$,
  'analytics_crosstab sans filtre : 3 trades closed, 2 gagnants → count=3, winrate≈66.66%'
);

-- ----------------------------------------------------------------------------
-- Test 21 : filtre par direction='long' → exclut les shorts
-- ----------------------------------------------------------------------------
-- On garde les 3 trades de test 20 (tous 'long') + on ajoute 1 'short' perdant.
-- Filtre direction='long' → count=3, pas 4.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'short', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '10 minutes',
               1, 100, -5);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count
       from public.analytics_crosstab(v_user_id, null, 'long'::public.trade_direction);
       if v_count <> 3 then raise exception 'count(long) doit être 3, trouvé %', v_count; end if;
     end $$ $$,
  'analytics_crosstab filtre direction=long : exclut le short ajouté → count=3'
);

-- ----------------------------------------------------------------------------
-- Test 22 : filtre par instrument
-- ----------------------------------------------------------------------------
-- On crée un 2e instrument, on DELETE les trades existants (pour isoler ce
-- test), puis on ajoute 1 trade closed sur le 2e instrument. Filtre
-- instrument_id = TESTUSD4 → 0 trade ; instrument_id = TESTUSD4B → 1 trade.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_a uuid;
       v_inst_b uuid;
       v_count_a bigint;
       v_count_b bigint;
     begin
       v_inst_a := (select id from public.instruments where symbol = 'TESTUSD4');
       insert into public.instruments (symbol, name, asset_class)
       values ('TESTUSD4B', 'Test Asset 4B', 'crypto')
       on conflict (symbol, exchange) do nothing;
       v_inst_b := (select id from public.instruments where symbol = 'TESTUSD4B');
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_b, 'long', 100, 1, 100, 'closed',
               now() - interval '3 hour', now() - interval '3 hour', now() - interval '10 minutes',
               1, 100, 10);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_a
       from public.analytics_crosstab(v_user_id, v_inst_a);
       select trade_count into v_count_b
       from public.analytics_crosstab(v_user_id, v_inst_b);
       if v_count_a <> 0 then raise exception 'count(TESTUSD4) doit être 0, trouvé %', v_count_a; end if;
       if v_count_b <> 1 then raise exception 'count(TESTUSD4B) doit être 1, trouvé %', v_count_b; end if;
     end $$ $$,
  'analytics_crosstab filtre instrument : TESTUSD4=0, TESTUSD4B=1 (test isolé par DELETE préalable)'
);

-- ----------------------------------------------------------------------------
-- Test 23 : filtre par session
-- ----------------------------------------------------------------------------
-- 1 trade opened à 10:00 UTC = europe, 1 trade opened à 22:00 UTC = us.
-- Filtre session='europe' → 1 trade, filtre session='us' → 1 trade.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count_eu bigint;
       v_count_us bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       -- Trade opened à 10:00 UTC = europe
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               '2026-09-05 09:30:00+00'::timestamptz, '2026-09-05 10:00:00+00'::timestamptz, '2026-09-05 11:00:00+00'::timestamptz,
               1, 100, 10);
       -- Trade opened à 22:00 UTC = us
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               '2026-09-05 21:30:00+00'::timestamptz, '2026-09-05 22:00:00+00'::timestamptz, '2026-09-05 23:00:00+00'::timestamptz,
               1, 100, 10);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_eu
       from public.analytics_crosstab(v_user_id, null, null, 'europe');
       select trade_count into v_count_us
       from public.analytics_crosstab(v_user_id, null, null, 'us');
       if v_count_eu <> 1 then raise exception 'count(europe) doit être 1, trouvé %', v_count_eu; end if;
       if v_count_us <> 1 then raise exception 'count(us) doit être 1, trouvé %', v_count_us; end if;
     end $$ $$,
  'analytics_crosstab filtre session : opened 10:00 UTC=europe (1), opened 22:00 UTC=us (1)'
);

-- ----------------------------------------------------------------------------
-- Test 24 : filtre par setup
-- ----------------------------------------------------------------------------
-- 1 trade avec setup='breakout', 1 trade avec setup='pullback'.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count_breakout bigint;
       v_count_pullback bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross, setup)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 10, 'breakout'),
              (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 5, 'pullback');
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_breakout
       from public.analytics_crosstab(v_user_id, null, null, null, 'breakout');
       select trade_count into v_count_pullback
       from public.analytics_crosstab(v_user_id, null, null, null, 'pullback');
       if v_count_breakout <> 1 then raise exception 'count(breakout) doit être 1, trouvé %', v_count_breakout; end if;
       if v_count_pullback <> 1 then raise exception 'count(pullback) doit être 1, trouvé %', v_count_pullback; end if;
     end $$ $$,
  'analytics_crosstab filtre setup : breakout=1, pullback=1'
);

-- ----------------------------------------------------------------------------
-- Test 25 : filtre par timeframe
-- ----------------------------------------------------------------------------
-- 1 trade timeframe='15m', 1 trade timeframe='4h'.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count_15m bigint;
       v_count_4h bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross, timeframe)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 10, '15m'),
              (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 5, '4h');
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_15m
       from public.analytics_crosstab(v_user_id, null, null, null, null, '15m'::public.trade_timeframe);
       select trade_count into v_count_4h
       from public.analytics_crosstab(v_user_id, null, null, null, null, '4h'::public.trade_timeframe);
       if v_count_15m <> 1 then raise exception 'count(15m) doit être 1, trouvé %', v_count_15m; end if;
       if v_count_4h <> 1 then raise exception 'count(4h) doit être 1, trouvé %', v_count_4h; end if;
     end $$ $$,
  'analytics_crosstab filtre timeframe : 15m=1, 4h=1'
);

-- ----------------------------------------------------------------------------
-- Test 26 : filtre par p_since
-- ----------------------------------------------------------------------------
-- 1 trade closed il y a 3h, 1 trade closed il y a 30 minutes.
-- p_since = il y a 1h → seul le trade récent est inclus.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count_recent bigint;
       v_count_all bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '4 hour', now() - interval '4 hour', now() - interval '3 hour',
               1, 100, 10),
              (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '1 hour', now() - interval '1 hour', now() - interval '30 minutes',
               1, 100, 5);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_all
       from public.analytics_crosstab(v_user_id);
       select trade_count into v_count_recent
       from public.analytics_crosstab(v_user_id, null, null, null, null, null, now() - interval '1 hour');
       if v_count_all <> 2 then raise exception 'count sans p_since doit être 2, trouvé %', v_count_all; end if;
       if v_count_recent <> 1 then raise exception 'count(p_since=1h) doit être 1, trouvé %', v_count_recent; end if;
     end $$ $$,
  'analytics_crosstab filtre p_since : sans=2, p_since=1h=1 (exclut le trade closed il y a 3h)'
);

-- ============================================================================
-- F. RLS sur analytics_crosstab
-- ============================================================================
-- Rappel : is_public default=true, RLS = is_public OR user_id=auth.uid().
-- Setup : user A (0004) a 1 trade privé (is_public=false) + 1 trade public.
-- user B (0005) appelle analytics_crosstab(A_id) → ne doit voir que le public.
-- user A (0004) appelle analytics_crosstab(A_id) → doit voir les 2.

-- ----------------------------------------------------------------------------
-- Test 27 : user B ne voit PAS les trades privés de user A
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000005'::uuid;
       v_inst_id uuid;
       v_count bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_a;
       -- 1 trade public + 1 trade privé pour user A
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross, is_public)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 10, true),
              (v_user_a, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hour', now() - interval '2 hour', now() - interval '1 hour',
               1, 100, 5, false);
       -- Bascule en user B via set_config
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       select trade_count into v_count
       from public.analytics_crosstab(v_user_a);
       -- B ne doit voir que le trade public → count=1, pas 2
       if v_count <> 1 then
         raise exception 'user B doit voir 1 trade public de A (RLS), trouvé %', v_count;
       end if;
     end $$ $$,
  'RLS : user B (0005) appelle analytics_crosstab(user A) → ne voit que le trade public, count=1 (pas 2)'
);

-- ----------------------------------------------------------------------------
-- Test 28 : user A voit TOUS ses trades (privés + publics)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_count bigint;
     begin
       -- Bascule en user A
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select trade_count into v_count
       from public.analytics_crosstab(v_user_a);
       -- A doit voir ses 2 trades (privé + public) → count=2
       if v_count <> 2 then
         raise exception 'user A doit voir ses 2 trades, trouvé %', v_count;
       end if;
     end $$ $$,
  'RLS : user A (0004) appelle analytics_crosstab(user A) → voit ses 2 trades (privé+public), count=2'
);

-- ============================================================================
-- G. EXTENSION analytics_crosstab : p_day_of_week + p_duration_bucket
--    (Phase 4 — migration 010, 2 dimensions du cadrage §07 ajoutées après coup)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 29 : filtre par p_day_of_week
-- ----------------------------------------------------------------------------
-- 1 trade ouvert samedi 2026-09-05 (dow=6), 1 trade ouvert dimanche
-- 2026-09-06 (dow=0). Filtre p_day_of_week=6 → 1, =0 → 1.
-- Note : 2026-09-05 = samedi, 2026-09-06 = dimanche (cohérent avec
-- test 9 qui fixe 2026-01-04 = dimanche : +244 jours pile = samedi).
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count_sat bigint;
       v_count_sun bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       -- Trade ouvert samedi 2026-09-05 10:00 UTC
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               '2026-09-04 09:30:00+00'::timestamptz, '2026-09-05 10:00:00+00'::timestamptz, '2026-09-05 11:00:00+00'::timestamptz,
               1, 100, 10);
       -- Trade ouvert dimanche 2026-09-06 10:00 UTC
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               '2026-09-05 09:30:00+00'::timestamptz, '2026-09-06 10:00:00+00'::timestamptz, '2026-09-06 11:00:00+00'::timestamptz,
               1, 100, 10);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_sat
       from public.analytics_crosstab(v_user_id, null, null, null, null, null, null, 6);
       select trade_count into v_count_sun
       from public.analytics_crosstab(v_user_id, null, null, null, null, null, null, 0);
       if v_count_sat <> 1 then raise exception 'count(samedi) doit être 1, trouvé %', v_count_sat; end if;
       if v_count_sun <> 1 then raise exception 'count(dimanche) doit être 1, trouvé %', v_count_sun; end if;
     end $$ $$,
  'analytics_crosstab filtre day_of_week : samedi=1 (dow=6), dimanche=1 (dow=0)'
);

-- ----------------------------------------------------------------------------
-- Test 30 : filtre par p_duration_bucket
-- ----------------------------------------------------------------------------
-- 1 trade avec durée 5min (lt_15m), 1 trade avec durée 2h (1h_4h).
-- Filtre p_duration_bucket='lt_15m' → 1, ='1h_4h' → 1.
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000004'::uuid;
       v_inst_id uuid;
       v_count_lt15m bigint;
       v_count_1h4h bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD4');
       delete from public.trades where user_id = v_user_id;
       -- Trade durée 5 minutes (lt_15m) : opened 10:00, closed 10:05
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               '2026-09-05 09:00:00+00'::timestamptz, '2026-09-05 10:00:00+00'::timestamptz, '2026-09-05 10:05:00+00'::timestamptz,
               1, 100, 5);
       -- Trade durée 2 heures (1h_4h) : opened 10:00, closed 12:00
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, closed_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'closed',
               '2026-09-05 08:00:00+00'::timestamptz, '2026-09-05 10:00:00+00'::timestamptz, '2026-09-05 12:00:00+00'::timestamptz,
               1, 100, 10);
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       select trade_count into v_count_lt15m
       from public.analytics_crosstab(v_user_id, null, null, null, null, null, null, null, 'lt_15m');
       select trade_count into v_count_1h4h
       from public.analytics_crosstab(v_user_id, null, null, null, null, null, null, null, '1h_4h');
       if v_count_lt15m <> 1 then raise exception 'count(lt_15m) doit être 1, trouvé %', v_count_lt15m; end if;
       if v_count_1h4h <> 1 then raise exception 'count(1h_4h) doit être 1, trouvé %', v_count_1h4h; end if;
     end $$ $$,
  'analytics_crosstab filtre duration_bucket : lt_15m=1 (5min), 1h_4h=1 (2h)'
);

select * from finish();
rollback;
