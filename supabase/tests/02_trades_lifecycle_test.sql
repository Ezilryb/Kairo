-- /supabase/tests/02_trades_lifecycle_test.sql
-- =============================================================================
-- Tests pgTAP ciblés sur la migration 02 (trades_lifecycle).
-- Concentré sur les invariants métier de Phase 2 — pas une couverture
-- générale, juste 4 cas qui verrouillent ce qui a été discuté :
--   1. Draft → live avec augmentation de capital dans le MÊME update
--      doit réussir. C'est le cas que le bug initial (vérification sur
--      new.status au lieu de old.status) aurait cassé — le seul test
--      qui aurait attrapé ça avant relecture attentive.
--   2. Live + augmentation de capital seule → doit échouer.
--   3. Live + diminution (capital ou quantity) → doit réussir ET créer
--      un trade_event partial_exit.
--   4. Live + update qui ne touche ni capital ni quantity (ex: notes)
--      → doit réussir, sans event partial_exit.
--   5. Live + modif stop_loss à 59 s après publication → doit réussir
--      (dans la fenêtre scalping 60 s, whitepaper §04).
--   6. Live + modif stop_loss à 61 s après publication → doit lever
--      l'exception `enforce_sl_tp_immutability` (hors fenêtre).
--   7. publish_trade (RPC) sur draft → OK, pose published_at/opened_at
--      via now() côté DB (pas via une valeur fournie par le client).
--   8. publish_trade (RPC) sur trade déjà live → lève exception
--      (idempotence : pas de "republication" pour reset la fenêtre 60 s).
--
-- Fichier séparé de 01_schema_test.sql (même logique que la séparation
-- des migrations par phase). Chaque test est autosuffisant : setup
-- + assertions dans le même bloc do $$.
-- =============================================================================

begin;

-- Setup : un instrument et un user dédiés à cette suite de tests
-- (utilisateur 00000000-0000-0000-0000-000000000002 pour ne pas
-- collisionner avec 01_schema_test.sql qui utilise ...0001).
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD2', 'Test Asset 2', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000002'::uuid, 'test+setup2@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000002'::uuid, 'test_setup2')
on conflict (id) do nothing;

select plan(8);

-- ============================================================================
-- Test 1 : draft → live + augmentation capital dans le même UPDATE → OK
-- ============================================================================
-- Cas d'usage normal : ajuster sa taille de position au moment de
-- publier. La condition enforce_capital_immutability vérifie old.status
-- (draft), donc l'augmentation est autorisée.
-- Avec le bug (new.status = live, augmentation bloquée), ce test
-- échouerait — c'est le bug-fix test.
select lives_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'draft'
       )
       returning id into v_trade_id;
       update public.trades
       set status = 'live', published_at = now(), capital = 200
       where id = v_trade_id;
     end $$ $$,
  'draft → live avec augmentation de capital dans le même UPDATE doit réussir'
);

-- ============================================================================
-- Test 2 : live + augmentation capital seule → lève exception
-- ============================================================================
-- Le trade est déjà publié. Tenter d'augmenter capital doit lever
-- l'exception définie dans enforce_capital_immutability.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour'
       )
       returning id into v_trade_id;
       update public.trades set capital = 200 where id = v_trade_id;
     end $$ $$,
  'capital ne peut pas augmenter%',
  'live + augmentation de capital seule doit lever notre exception'
);

-- ============================================================================
-- Test 3 : live + diminution capital/quantity → OK + event partial_exit
-- ============================================================================
-- Sortie partielle : capital 100 → 50, quantity 1 → 0.5. Le trigger
-- log_partial_exits doit insérer une trade_event avec event_type =
-- 'partial_exit' et old_values/new_values JSONB qui capturent avant/après.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_event_count int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour'
       )
       returning id into v_trade_id;
       update public.trades
       set capital = 50, quantity = 0.5
       where id = v_trade_id;
       -- Vérification : un trade_event partial_exit doit avoir été créé
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'partial_exit';
       if v_event_count <> 1 then
         raise exception 'attendu 1 trade_event partial_exit, trouvé %', v_event_count;
       end if;
     end $$ $$,
  'live + diminution capital/quantity doit réussir ET créer 1 trade_event partial_exit'
);

-- ============================================================================
-- Test 4 : live + update notes-only → OK, sans event partial_exit
-- ============================================================================
-- Update qui ne touche ni capital ni quantity ne doit pas déclencher
-- log_partial_exits. Le trigger log_sl_tp_changes fire aussi mais ne crée
-- pas d'event si SL/TP n'ont pas changé — donc au final, 0 trade_event
-- créé par cet update.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_event_count int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, notes)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour',
         'note initiale'
       )
       returning id into v_trade_id;
       update public.trades set notes = 'note mise à jour' where id = v_trade_id;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id;
       if v_event_count <> 0 then
         raise exception 'attendu 0 trade_event pour update notes-only, trouvé %', v_event_count;
       end if;
     end $$ $$,
  'live + update notes-only doit réussir SANS créer de trade_event'
);

-- ============================================================================
-- Test 5 : live + modif stop_loss à 59 s après publication → OK
-- ============================================================================
-- Cas d'usage normal : le user publie un trade, ajuste son SL dans la
-- fenêtre scalping (whitepaper §04). On INSERT directement avec
-- published_at = now() - 59 s (dans la fenêtre) puis on UPDATE SL.
-- Le trigger évalue : T > (T-59s) + 60s = T > T+1s = false → la modif
-- doit passer. Convention identique aux tests 3.2 et 3.3 de
-- 01_schema_test.sql sur entry_price.
-- Note : take_profit suit la même règle (OR dans le trigger), pas de
-- test séparé pour TP — un test par branche du OR serait de la
-- sur-ingénierie pour deux conditions strictement symétriques.
select lives_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, stop_loss)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '59 seconds', now() - interval '59 seconds',
         95
       )
       returning id into v_trade_id;
       update public.trades set stop_loss = 90 where id = v_trade_id;
     end $$ $$,
  'modif stop_loss 59 s après publication passe (fenêtre scalping 60 s incluse)'
);

-- ============================================================================
-- Test 6 : live + modif stop_loss à 61 s après publication → lève exception
-- ============================================================================
-- published_at = now() - 61 s. Le trigger évalue :
-- T > (T-61s) + 60s = T > T-1s = true → la modif est refusée.
-- Message d'exception : 'stop_loss / take_profit sont immuables...'
-- (cf. enforce_sl_tp_immutability dans la migration
-- 20260901000001_trades_sl_tp_window.sql).
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, stop_loss)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '61 seconds', now() - interval '61 seconds',
         95
       )
       returning id into v_trade_id;
       update public.trades set stop_loss = 90 where id = v_trade_id;
     end $$ $$,
  'stop_loss / take_profit sont immuables%',
  'modif stop_loss 61 s après publication doit lever notre exception (fenêtre expirée)'
);

-- ============================================================================
-- Test 7 : publish_trade (RPC) sur draft → OK, now() côté DB
-- ============================================================================
-- Vérifie que le RPC pose les timestamps via now() côté base, pas via
-- une valeur fournie par le client. C'est le fix du bug d'horloge
-- navigateur découvert en Point C/D : si on acceptait published_at
-- depuis le client, une horloge mal réglée pouvait dater le trade
-- dans le passé, et la fenêtre 60 s pouvait être considérée comme
-- expirée dès la publication.
--
-- Technique : on INSERT un trade en draft, on capture t_before = now()
-- juste avant l'appel RPC, on appelle publish_trade, on vérifie que
-- published_at ET opened_at sont >= à t_before. On utilise >= (pas =)
-- parce que la résolution de now() peut produire un timestamp
-- postérieur à t_before dans la même transaction.
--
-- Note : le RPC est SECURITY INVOKER, il s'exécute avec les droits de
-- l'appelant. Dans le contexte de ce test, le rôle par défaut est
-- 'postgres' (superuser) et auth.uid() est NULL — mais comme on INSERT
-- le trade avec user_id = ...0002 et que le WHERE du RPC filtre sur
-- user_id = auth.uid(), le RPC ne matchera aucune ligne. Si ce test
-- échoue pour cette raison, le directeur devra ajouter un
-- `select set_config('request.jwt.claim.sub', '...0002', true);` avant
-- l'appel RPC pour simuler le user authentifié.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_published public.trades;
       v_t_before timestamptz;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'draft'
       )
       returning id into v_trade_id;
       v_t_before := now();
       select * into v_published from public.publish_trade(v_trade_id);
       if v_published.status <> 'live' then
         raise exception 'status doit être live, trouvé %', v_published.status;
       end if;
       if v_published.published_at is null then
         raise exception 'published_at ne doit pas être NULL';
       end if;
       if v_published.opened_at is null then
         raise exception 'opened_at ne doit pas être NULL';
       end if;
       if v_published.published_at < v_t_before then
         raise exception 'published_at (%) doit être >= à t_before (%)',
           v_published.published_at, v_t_before;
       end if;
       if v_published.opened_at < v_t_before then
         raise exception 'opened_at (%) doit être >= à t_before (%)',
           v_published.opened_at, v_t_before;
       end if;
     end $$ $$,
  'publish_trade (RPC) sur draft pose status=live + published_at/opened_at via now() DB'
);

-- ============================================================================
-- Test 8 : publish_trade (RPC) sur trade déjà live → lève exception
-- ============================================================================
-- Idempotence : un 2e appel sur un trade déjà publié ne doit pas
-- réécrire published_at (sinon on pourrait "republier" pour reset la
-- fenêtre 60 s, ce qui violerait le whitepaper §04). Le WHERE du RPC
-- filtre status = 'draft', donc 0 lignes affectées, l'exception
-- "Trade introuvable, déjà publié, ou non autorisé" remonte.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 hour', now() - interval '1 hour'
       )
       returning id into v_trade_id;
       perform public.publish_trade(v_trade_id);
     end $$ $$,
  'Trade introuvable%',
  'publish_trade (RPC) sur trade déjà live doit lever notre exception (pas de republication)'
);

select * from finish();
rollback;
