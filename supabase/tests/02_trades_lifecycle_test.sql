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
--   9. transition_trade live → closed : OK, closed_at posé, event 'closed'.
--  10. transition_trade forgotten → live : OK, event 'reactivated'.
--  11. transition_trade live → archived : lève exception (transition
--      interdite, faut passer par closed).
--  12. mark_forgotten_trades sur trade live+old : OK, status='forgotten'
--      + event 'marked_forgotten'.
--  13. mark_forgotten_trades sur trade live+recent : 0 affecté (le
--      WHERE last_activity_at < now() - 5d ne matche pas).
--  14. mark_forgotten_trades préserve last_activity_at (intégrité :
--      log_sl_tp_changes ne doit pas écraser la date quand le trade
--      bascule vers 'forgotten').
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

select plan(14);

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
-- IMPORTANT : le RPC est SECURITY INVOKER, le WHERE filtre sur
-- user_id = auth.uid(). En contexte pgTAP brut, auth.uid() est NULL
-- (il lit request.jwt.claim.sub, posé uniquement par PostgREST) et le
-- RPC ne matche rien. On pose donc explicitement le claim AVANT
-- l'appel via set_config(..., true) (true = local à la transaction).
-- Sans ça, ce test donnerait un faux négatif visible — gênant mais
-- détectable. Pire pour le test 8 (cf. commentaire dédié).
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
       -- Pose le claim JWT pour que auth.uid() renvoie le user ...0002
       -- pendant cet appel RPC. Le 3e arg `true` = local à la
       -- transaction, reset automatique au COMMIT/ROLLBACK.
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000002',
         true
       );
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
--
-- Piège détecté en revue : sans set_config du JWT claim, auth.uid()
-- vaut NULL et `user_id = NULL` ne matche jamais rien — l'exception
-- remonterait "pour la mauvaise raison". Si quelqu'un retirait un
-- jour la condition `status = 'draft'` du RPC par erreur
-- (régression sur l'idempotence), ce test continuerait de passer au
-- vert sans détecter la régression. Faux vert plus dangereux qu'un
-- test manquant. D'où le set_config explicite ci-dessous, qui rend
-- le test authentique : user_id matche bien, seul status = 'draft'
-- filtre, et c'est ÇA qui doit faire échouer le WHERE.
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
       -- Idem test 7 : pose le claim pour que user_id matche, et que
       -- l'exception vienne BIEN du filtre status='draft' (et pas de
       -- user_id = NULL).
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000002',
         true
       );
       perform public.publish_trade(v_trade_id);
     end $$ $$,
  'Trade introuvable%',
  'publish_trade (RPC) sur trade déjà live doit lever notre exception (pas de republication)'
);

-- ============================================================================
-- Test 9 : transition_trade live → closed : OK, closed_at + event
-- ============================================================================
-- Clôture manuelle d'un trade publié. Vérifie :
--   - status passe à 'closed'
--   - closed_at est posé à now() (non NULL, et >= t_before)
--   - 1 trade_event de type 'closed' est créé avec old/new status
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_result public.trades;
       v_t_before timestamptz;
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
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000002',
         true
       );
       v_t_before := now();
       select * into v_result from public.transition_trade(v_trade_id, 'closed'::public.trade_status);
       if v_result.status <> 'closed' then
         raise exception 'status doit être closed, trouvé %', v_result.status;
       end if;
       if v_result.closed_at is null then
         raise exception 'closed_at ne doit pas être NULL';
       end if;
       if v_result.closed_at < v_t_before then
         raise exception 'closed_at (%) doit être >= à t_before (%)',
           v_result.closed_at, v_t_before;
       end if;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'closed';
       if v_event_count <> 1 then
         raise exception 'attendu 1 trade_event closed, trouvé %', v_event_count;
       end if;
     end $$ $$,
  'transition_trade live → closed pose status + closed_at + event closed'
);

-- ============================================================================
-- Test 10 : transition_trade forgotten → live : OK, event 'reactivated'
-- ============================================================================
-- Réactivation d'un trade oublié. Vérifie :
--   - status repasse à 'live'
--   - closed_at reste NULL (on n'a pas transité par closed)
--   - 1 trade_event de type 'reactivated' est créé
-- C'est la transition "REACTIVÉ" du whitepaper §04 — pas un statut
-- à part, juste forgotten qui redevient live.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_result public.trades;
       v_event_count int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'forgotten',
         now() - interval '10 days', now() - interval '10 days'
       )
       returning id into v_trade_id;
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000002',
         true
       );
       select * into v_result from public.transition_trade(v_trade_id, 'live'::public.trade_status);
       if v_result.status <> 'live' then
         raise exception 'status doit être live, trouvé %', v_result.status;
       end if;
       if v_result.closed_at is not null then
         raise exception 'closed_at doit rester NULL (pas transité par closed), trouvé %',
           v_result.closed_at;
       end if;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'reactivated';
       if v_event_count <> 1 then
         raise exception 'attendu 1 trade_event reactivated, trouvé %', v_event_count;
       end if;
     end $$ $$,
  'transition_trade forgotten → live pose status=live + event reactivated'
);

-- ============================================================================
-- Test 11 : transition_trade live → archived : lève exception
-- ============================================================================
-- Transition interdite : pour archiver, il faut passer par closed
-- d'abord (LIVE → CLOSED → ARCHIVED). Le RPC doit refuser
-- explicitement, pas passer en silence.
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
       perform set_config(
         'request.jwt.claim.sub',
         '00000000-0000-0000-0000-000000000002',
         true
       );
       perform public.transition_trade(v_trade_id, 'archived'::public.trade_status);
     end $$ $$,
  'Transition non autorisée%',
  'transition_trade live → archived doit lever (faut passer par closed)'
);

-- ============================================================================
-- Test 12 : mark_forgotten_trades sur trade live+old : OK + event
-- ============================================================================
-- Job OUBLIÉ. On INSERT un trade live avec last_activity_at = now() -
-- 6 jours (> 5 jours, doit être oublié). On appelle le RPC, on
-- vérifie :
--   - status passe à 'forgotten'
--   - 1 trade_event 'marked_forgotten' est créé
--   - le compteur retourné est 1
--
-- Note : SECURITY DEFINER bypasse la RLS, donc pas besoin de
-- set_config pour auth.uid() ici — le RPC s'exécute avec les droits
-- du propriétaire de la fonction, peu importe qui appelle.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_count int;
       v_status public.trade_status;
       v_event_count int;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, last_activity_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '6 days', now() - interval '6 days',
         now() - interval '6 days'
       )
       returning id into v_trade_id;
       v_count := public.mark_forgotten_trades();
       if v_count < 1 then
         raise exception 'mark_forgotten_trades doit retourner au moins 1, retourné %', v_count;
       end if;
       select status into v_status from public.trades where id = v_trade_id;
       if v_status <> 'forgotten' then
         raise exception 'status doit être forgotten, trouvé %', v_status;
       end if;
       select count(*) into v_event_count
       from public.trade_events
       where trade_id = v_trade_id and event_type = 'marked_forgotten';
       if v_event_count <> 1 then
         raise exception 'attendu 1 trade_event marked_forgotten, trouvé %', v_event_count;
       end if;
     end $$ $$,
  'mark_forgotten_trades bascule les trades live+old (status=forgotten + event)'
);

-- ============================================================================
-- Test 13 : mark_forgotten_trades sur trade live+recent : 0 affecté
-- ============================================================================
-- Trade live avec last_activity_at = now() - 1 jour (< 5 jours, ne
-- doit PAS être oublié). On INSERT explicitement le trade, on
-- appelle le RPC, on vérifie :
--   - le compteur retourné est 0 (rien à oublier parmi les récents)
--   - le trade reste en 'live' (n'a pas été basculé)
-- Si le RPC matchait aussi les récents, le compteur serait > 0 ET
-- le status du trade serait 'forgotten' → les 2 assertions sautent.
-- Le test 12 a déjà oublié son propre trade (donc le WHERE ne le
-- matche plus, status = 'forgotten'), on est dans un état propre.
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_count int;
       v_status public.trade_status;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, last_activity_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '1 day', now() - interval '1 day',
         now() - interval '1 day'
       )
       returning id into v_trade_id;
       v_count := public.mark_forgotten_trades();
       if v_count <> 0 then
         raise exception 'compteur doit être 0 (aucun trade à oublier), retourné %', v_count;
       end if;
       select status into v_status from public.trades where id = v_trade_id;
       if v_status <> 'live' then
         raise exception 'trade live+recent ne doit pas être oublié, status = %', v_status;
       end if;
     end $$ $$,
  'mark_forgotten_trades sur trade live+recent : compteur 0 et status reste live'
);

-- ============================================================================
-- Test 14 : mark_forgotten_trades préserve last_activity_at (intégrité)
-- ============================================================================
-- Bug identifié en revue du Point D : la version précédente de
-- log_sl_tp_changes (Phase 0) posait `new.last_activity_at := now()`
-- inconditionnellement, ce qui écrasait silencieusement la date de
-- dernière activité réelle au moment même où le job constatait
-- l'inactivité. La valeur de last_activity_at pour les trades
-- basculés était définitivement perdue (whitepaper §07, AI Bias
-- Detector).
--
-- Fix : log_sl_tp_changes ne rafraîchit last_activity_at que si
-- new.status <> 'forgotten'. On vérifie ici que le fix tient.
--
-- On INSERT un trade live+old (last_activity_at = now() - 6j), on
-- capture cette valeur, on appelle mark_forgotten_trades, on relit
-- last_activity_at et on vérifie qu'il n'a pas bougé. Tolérance
-- ±1s pour la résolution de now() dans la même transaction
-- (vraisemblablement 0s en pratique, mais on reste défensif).
select lives_ok(
  $$ do $$
     declare
       v_trade_id uuid;
       v_last_activity_before timestamptz;
       v_last_activity_after timestamptz;
       v_diff_seconds numeric;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, last_activity_at)
       values (
         '00000000-0000-0000-0000-000000000002'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD2'),
         'long', 100, 1, 100, 'live',
         now() - interval '6 days', now() - interval '6 days',
         now() - interval '6 days'
       )
       returning id, last_activity_at into v_trade_id, v_last_activity_before;
       perform public.mark_forgotten_trades();
       select last_activity_at into v_last_activity_after
       from public.trades where id = v_trade_id;
       if v_last_activity_after is null then
         raise exception 'last_activity_at ne doit pas être NULL après mark_forgotten_trades';
       end if;
       v_diff_seconds := abs(extract(epoch from (v_last_activity_after - v_last_activity_before)));
       if v_diff_seconds > 1.0 then
         raise exception 'last_activity_at a bougé de % secondes (avant=%, après=%) — log_sl_tp_changes a écrasé la date d''inactivité',
           v_diff_seconds, v_last_activity_before, v_last_activity_after;
       end if;
     end $$ $$,
  'mark_forgotten_trades préserve last_activity_at (pas d''écrasement silencieux par log_sl_tp_changes)'
);

select * from finish();
rollback;
