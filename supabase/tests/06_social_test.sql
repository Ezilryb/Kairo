-- /supabase/tests/06_social_test.sql
-- =============================================================================
-- Tests pgTAP pour la Phase 6 — Réseau Social (whitepaper §03 + §09).
-- Couvre les 3 migrations :
--   - 20260903000012_likes.sql            (table likes + RLS)
--   - 20260903000013_privacy_masking.sql  (3 fonctions trade_visible_*)
--   - 20260903000014_feed.sql             (get_feed)
--
-- Conventions identiques aux fichiers de test précédents :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Chaque test autosuffisant (setup + assertions dans le même do $$)
--   - SECURITY INVOKER : on pose set_config('request.jwt.claim.sub', ...)
--     avant l'appel RPC
--   - lives_ok + IF ... RAISE EXCEPTION pour les tests avec setup + assert
--     (pattern validé dans 03_financial_calcs_test.sql / 04_analytics_test.sql).
--     is()/ok() ne sont PAS interchangeables avec lives_ok() quand il y a
--     du setup préalable : un bloc DO est void et ne peut pas faire
--     RETURN <valeur>, donc les assertions doivent vivre DANS le bloc DO.
--   - Chaque test STRICTEMENT autosuffisant : tout état partagé entre
--     tests (ex : users.is_public basculé en false dans un test) doit
--     être re-établi explicitement dans les tests qui en dépendent.
--     Idempotent — un update qui pose déjà la valeur ne fait rien.
--
-- Users dédiés :
--   00000000-0000-0000-0000-000000000008 — user A (consultant principal du feed)
--   00000000-0000-0000-0000-000000000009 — user B (suivi par A, profil
--                                            basculement public ↔ privé selon
--                                            les tests)
--   00000000-0000-0000-0000-00000000000a — user C (non suivi, sert au test
--                                            d'exclusion du feed)
-- Instrument dédié : TESTUSD6 (crypto pour simplifier).
--
-- Plan : 20 assertions
-- A. likes (7 tests) :
--    1  : insert par soi-même sur trade public → OK (lives_ok)
--    2  : insert par A sur trade PUBLIC de B → OK (lives_ok)
--    3  : insert par A sur trade PRIVÉ (is_public=false) de B → throws (throws_ok)
--    4  : double like (même user, même trade) → throws UNIQUE (throws_ok)
--    5  : like "au nom de" (user_id mismatch) → throws RLS with check (throws_ok)
--    6  : unlike par soi-même → OK (lives_ok)
--    7  : unlike par un autre → no-op silencieux (DELETE filtré par USING,
--        0 ligne affectée, PAS d'exception — confirmé via lives_ok qui
--        vérifie que la ligne est toujours là. Voir leçon RLS WITH CHECK
--        vs USING dans docs/TODO_TECHNIQUE.md.)
-- B. privacy masking (7 tests, tous lives_ok) :
--    8  : trade_visible_capital : proprio → 100
--    9  : trade_visible_capital : profil public → 100
--    10 : trade_visible_capital : profil privé → NULL
--    11 : trade_visible_quantity : profil privé → NULL
--    12 : trade_visible_pnl_absolute : profil privé → NULL
--    13 : trade_visible_pnl_absolute : proprio, trade non closed → NULL
--    14 : rendement_pct reste visible pour profil privé (passthrough §09)
-- C. feed (6 tests, tous lives_ok sauf 20) :
--    15 : get_feed sans follower → 0 rows
--    16 : get_feed avec 1 follower, 1 trade public → 1 row
--    17 : get_feed : trade PRIVÉ du follower exclu (filtre CTE t.is_public = true)
--    18 : get_feed : pagination par p_before (3 trades, p_limit=1)
--    19 : get_feed : trade d'un non-follower exclu
--    20 : get_feed : p_user_id ≠ auth.uid() → throws (throws_ok)
--
-- Note sur les tests privacy (B) : pnl_net(trade) retourne NULL si
-- status <> 'closed'. Pour tester que trade_visible_pnl_absolute propage
-- un NULL "légitime" (test 13) et non un NULL "masqué", chaque test
-- privacy setup un trade closed avec realized_pnl_gross > 0 quand le
-- test vise la valeur ou le masquage d'un PnL. realised_pnl_gross est
-- l'accumulateur de pnl_gross depuis la migration 004.
--
-- Note IS DISTINCT FROM vs <> : <> avec NULL renvoie NULL (jamais TRUE),
-- donc un IF v_result <> NULL ne se déclencherait jamais. IS DISTINCT FROM
-- gère correctement les comparaisons impliquant NULL (TRUE si différent,
-- y compris NULL vs non-NULL). C'est l'opérateur à utiliser dans les raises
-- des tests 8/9 (valeur non-NULL attendue) et 10-13 (NULL attendue).
-- =============================================================================

begin;

-- ============================================================================
-- Setup : 3 users + 1 instrument dédié
-- ============================================================================
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD6', 'Test Asset 6', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000008'::uuid, 'test+setup8@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000008'::uuid, 'test_setup8')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000009'::uuid, 'test+setup9@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000009'::uuid, 'test_setup9')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000000a'::uuid, 'test+setupa@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000000a'::uuid, 'test_setupa')
on conflict (id) do nothing;

select plan(20);

-- ============================================================================
-- A. LIKES (7 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 1 : like par soi-même sur son propre trade public → OK
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_id);
     end $$ $$,
  'like par soi-même sur son propre trade public inséré OK'
);

-- ----------------------------------------------------------------------------
-- Test 2 : like par A sur trade PUBLIC de B → OK (A peut SELECT le trade de B)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_a);
     end $$ $$,
  'like par A sur trade PUBLIC de B inséré OK'
);

-- ----------------------------------------------------------------------------
-- Test 3 : like par A sur trade PRIVÉ (is_public=false) de B → throws
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, is_public, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), false, 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_a);
     end $$ $$,
  'new row violates row-level security policy%',
  'like par A sur trade PRIVÉ de B refusé (RLS SELECT trades bloque INSERT likes)'
);

-- ----------------------------------------------------------------------------
-- Test 4 : double like (même user, même trade) → throws (UNIQUE)
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_id);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_id);
     end $$ $$,
  'duplicate key value violates unique constraint%',
  'double like refusé par contrainte UNIQUE (trade_id, user_id)'
);

-- ----------------------------------------------------------------------------
-- Test 5 : like "au nom de" (user_id mismatch) → throws (RLS with check)
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_b);
     end $$ $$,
  'new row violates row-level security policy%',
  'like au nom d''un autre user refusé (WITH CHECK auth.uid() = user_id)'
);

-- ----------------------------------------------------------------------------
-- Test 6 : unlike par soi-même → OK
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_id uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_like_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_id, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_id::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_id)
         returning id into v_like_id;
       delete from public.likes where id = v_like_id;
     end $$ $$,
  'unlike par soi-même OK (DELETE autorisé par RLS)'
);

-- ----------------------------------------------------------------------------
-- Test 7 : unlike par un autre user → no-op silencieux (DELETE filtré par USING)
-- ----------------------------------------------------------------------------
-- INSERT/UPDATE avec WITH CHECK : si la nouvelle ligne ne satisfait pas la
-- condition, Postgres lève "new row violates row-level security policy".
-- SELECT/UPDATE/DELETE avec USING : la clause USING filtre silencieusement
-- les lignes visibles (comme un WHERE implicite). Une ligne qui ne passe
-- pas USING n'est simplement pas sélectionnée → 0 ligne affectée, AUCUNE
-- exception levée. Donc unlike par B sur le like de A est un no-op
-- silencieux, pas une erreur — on vérifie ici que la ligne est toujours
-- là (et qu'on n'a pas perdu de vue une subtilité).
-- Référence : 01_schema_test.sql test 3.7/3.8 lèvent via un trigger
-- RAISE EXCEPTION, pas via la RLS elle-même. Ici, RLS pure sans trigger.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_like_id uuid;
       v_remaining_count int;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       -- A like le trade (public par défaut)
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.likes (trade_id, user_id) values (v_trade_id, v_user_a)
         returning id into v_like_id;
       -- B tente d'unlike le like de A : la policy DELETE
       -- (USING auth.uid() = user_id) filtre silencieusement la ligne,
       -- 0 ligne affectée, AUCUNE exception (≠ INSERT/UPDATE WITH CHECK).
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       delete from public.likes where id = v_like_id;
       -- Le trade reste public (is_public=true par défaut), donc B peut
       -- toujours SELECT le like de A (policy SELECT dépend de la
       -- visibilité du trade, pas de qui a liké) — on vérifie qu'il est
       -- toujours là. Si la ligne avait été supprimée, c'est qu'on a
       -- involontairement ouvert une faille.
       select count(*) into v_remaining_count from public.likes where id = v_like_id;
       if v_remaining_count <> 1 then
         raise exception
           'unlike par B sur le like de A : attendu 1 ligne restante (delete filtré par RLS), trouvé %',
           v_remaining_count;
       end if;
     end $$ $$,
  'unlike du like d''un autre user est un no-op silencieux (DELETE filtré par USING, 0 ligne affectée, pas d''exception)'
);

-- ============================================================================
-- B. PRIVACY MASKING (7 tests, tous lives_ok)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 8 : trade_visible_capital : proprio → 100
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, opened_at, closed_at, published_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hours', now() - interval '1 hour',
               now() - interval '2 hours', 1, 100, 20)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.trade_visible_capital(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is distinct from 100 then
         raise exception 'trade_visible_capital (proprio) : attendu 100, trouvé %', v_result;
       end if;
     end $$ $$,
  'trade_visible_capital : le propriétaire voit initial_capital (= 100)'
);

-- ----------------------------------------------------------------------------
-- Test 9 : trade_visible_capital : profil public → 100
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, opened_at, closed_at, published_at, is_public, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hours', now() - interval '1 hour',
               now() - interval '2 hours', true, 1, 100, 20)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.trade_visible_capital(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is distinct from 100 then
         raise exception 'trade_visible_capital (profil public) : attendu 100, trouvé %', v_result;
       end if;
     end $$ $$,
  'trade_visible_capital : profil public du proprio → valeur visible'
);

-- ----------------------------------------------------------------------------
-- Test 10 : trade_visible_capital : profil privé → NULL
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, opened_at, closed_at, published_at, is_public, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hours', now() - interval '1 hour',
               now() - interval '2 hours', true, 1, 100, 20)
       returning id into v_trade_id;
       update public.users set is_public = false where id = v_user_b;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.trade_visible_capital(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is not null then
         raise exception 'trade_visible_capital (profil privé) : attendu NULL, trouvé %', v_result;
       end if;
     end $$ $$,
  'trade_visible_capital : profil privé → NULL (chiffre masqué)'
);

-- ----------------------------------------------------------------------------
-- Test 11 : trade_visible_quantity : profil privé → NULL
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, opened_at, closed_at, published_at, is_public, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hours', now() - interval '1 hour',
               now() - interval '2 hours', true, 1, 1, 20)
       returning id into v_trade_id;
       -- Auto-suffisance : on pose is_public=false explicitement (le
       -- test 10 le fait aussi, mais on ne dépend pas de son ordre).
       update public.users set is_public = false where id = v_user_b;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.trade_visible_quantity(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is not null then
         raise exception 'trade_visible_quantity (profil privé) : attendu NULL, trouvé %', v_result;
       end if;
     end $$ $$,
  'trade_visible_quantity : profil privé → NULL (taille masquée)'
);

-- ----------------------------------------------------------------------------
-- Test 12 : trade_visible_pnl_absolute : profil privé → NULL
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, opened_at, closed_at, published_at, is_public, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hours', now() - interval '1 hour',
               now() - interval '2 hours', true, 1, 100, 20)
       returning id into v_trade_id;
       -- Auto-suffisance : voir test 11.
       update public.users set is_public = false where id = v_user_b;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.trade_visible_pnl_absolute(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is not null then
         raise exception 'trade_visible_pnl_absolute (profil privé) : attendu NULL, trouvé %', v_result;
       end if;
     end $$ $$,
  'trade_visible_pnl_absolute : profil privé → NULL (PnL absolu masqué)'
);

-- ----------------------------------------------------------------------------
-- Test 13 : trade_visible_pnl_absolute : proprio, trade non closed → NULL
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100, 0)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.trade_visible_pnl_absolute(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is not null then
         raise exception 'trade_visible_pnl_absolute (proprio, live) : attendu NULL, trouvé %', v_result;
       end if;
     end $$ $$,
  'trade_visible_pnl_absolute : proprio, trade non closed → NULL (propagation pnl_net)'
);

-- ----------------------------------------------------------------------------
-- Test 14 : rendement_pct reste visible pour profil privé (passthrough §09)
-- ----------------------------------------------------------------------------
-- rendement_pct ne consulte jamais users.is_public (fonction purement
-- mathématique sur le trade), donc ce test passerait avec B public ou
-- privé. On pose is_public=false quand même pour illustrer réellement le
-- scénario que le commentaire prétend tester (cohérence, pas validité).
select lives_ok(
  $$ do $$
     declare
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_result numeric;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, opened_at, closed_at, published_at, is_public, initial_quantity, initial_capital, realized_pnl_gross)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'closed',
               now() - interval '2 hours', now() - interval '1 hour',
               now() - interval '2 hours', true, 1, 100, 20)
       returning id into v_trade_id;
       update public.users set is_public = false where id = v_user_b;
       -- Pas de set_config : auth.uid() NULL ou résiduel n'affecte pas
       -- rendement_pct (fonction purement mathématique sur le trade).
       select public.rendement_pct(t.*) into v_result
         from public.trades t where t.id = v_trade_id;
       if v_result is null or v_result <= 0 then
         raise exception 'rendement_pct (profil privé) : attendu > 0, trouvé %', v_result;
       end if;
     end $$ $$,
  'rendement_pct : reste visible pour profil privé (passthrough §09)'
);

-- ============================================================================
-- C. FEED (6 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 15 : get_feed sans follower → 0 rows
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_count bigint;
     begin
       delete from public.followers where follower_id = v_user_a;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count from public.get_feed(v_user_a);
       if v_count <> 0 then
         raise exception 'get_feed sans follower : attendu 0, trouvé %', v_count;
       end if;
     end $$ $$,
  'get_feed sans follower → 0 rows'
);

-- ----------------------------------------------------------------------------
-- Test 16 : get_feed avec 1 follower, 1 trade public → 1 row
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_count bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       delete from public.followers where follower_id = v_user_a;
       delete from public.trades where user_id = v_user_b;
       insert into public.followers (follower_id, followee_id)
         values (v_user_a, v_user_b);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100);
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count from public.get_feed(v_user_a);
       if v_count <> 1 then
         raise exception 'get_feed (1 follower, 1 trade) : attendu 1, trouvé %', v_count;
       end if;
     end $$ $$,
  'get_feed avec 1 follower et 1 trade public → 1 row'
);

-- ----------------------------------------------------------------------------
-- Test 17 : get_feed : trade PRIVÉ du follower exclu
-- ----------------------------------------------------------------------------
-- Le filtre explicite t.is_public = true du WHERE de la CTE feed_trades
-- est le mécanisme qui exclut la ligne en premier (avant même la RLS de
-- trades, qui agirait en filet de sécurité). C'est la couche CTE qui
-- porte la sémantique "trades publics visibles dans le feed".
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_count bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       delete from public.followers where follower_id = v_user_a;
       delete from public.trades where user_id = v_user_b;
       insert into public.followers (follower_id, followee_id)
         values (v_user_a, v_user_b);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, is_public, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), false, 1, 100);
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count from public.get_feed(v_user_a);
       if v_count <> 0 then
         raise exception 'get_feed (trade privé) : attendu 0, trouvé %', v_count;
       end if;
     end $$ $$,
  'get_feed : trade PRIVÉ du follower exclu (filtre CTE t.is_public = true)'
);

-- ----------------------------------------------------------------------------
-- Test 18 : get_feed : pagination par p_before (3 trades, p_limit=1)
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_inst_id uuid;
       v_t1_pub timestamptz;
       v_first_id uuid;
       v_second_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       delete from public.followers where follower_id = v_user_a;
       delete from public.trades where user_id = v_user_b;
       insert into public.followers (follower_id, followee_id)
         values (v_user_a, v_user_b);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now() - interval '3 hours', now() - interval '3 hours', 1, 100);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'short', 100, 1, 100, 'live',
               now() - interval '2 hours', now() - interval '2 hours', 1, 100)
       returning published_at into v_t1_pub;
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now() - interval '1 hour', now() - interval '1 hour', 1, 100);
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       -- 1ère page : le plus récent (T-1)
       select trade_id into v_first_id from public.get_feed(v_user_a, null, 1);
       -- 2e page : strictement après le trade "milieu" (T-2) → T-3
       select trade_id into v_second_id
         from public.get_feed(v_user_a, v_t1_pub, 1);
       if v_first_id is not distinct from v_second_id then
         raise exception 'get_feed pagination : trade_id identique entre 2 pages (%), pagination cassée', v_first_id;
       end if;
     end $$ $$,
  'get_feed : pagination par p_before renvoie un trade DIFFÉRENT à la 2e page'
);

-- ----------------------------------------------------------------------------
-- Test 19 : get_feed : trade d'un non-follower exclu
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
       v_user_c uuid := '00000000-0000-0000-0000-00000000000a'::uuid;
       v_inst_id uuid;
       v_count bigint;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD6');
       delete from public.followers where follower_id = v_user_a;
       delete from public.trades where user_id in (v_user_b, v_user_c);
       insert into public.followers (follower_id, followee_id)
         values (v_user_a, v_user_b);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100);
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_c, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100);
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count from public.get_feed(v_user_a);
       if v_count <> 1 then
         raise exception 'get_feed (B + C trades publics, A follow B seulement) : attendu 1, trouvé %', v_count;
       end if;
     end $$ $$,
  'get_feed : trade d''un non-follower exclu (1 row, pas 2)'
);

-- ----------------------------------------------------------------------------
-- Test 20 : get_feed : p_user_id ≠ auth.uid() → throws
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000008'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000009'::uuid;
     begin
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       perform public.get_feed(v_user_b);
     end $$ $$,
  'get_feed:%',
  'get_feed refuse p_user_id ≠ auth.uid() (defense in depth explicite)'
);

select * from finish();
rollback;
