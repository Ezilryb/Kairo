-- /supabase/tests/09_trade_events_policy_test.sql
-- =============================================================================
-- Tests pgTAP pour la migration 020 — alignement de la policy SELECT
-- trade_events avec la policy trades Phase 7.
--
-- Contexte : la migration 020 a remplacé l'ancienne policy "lecture si le
-- trade est lisible" (predicate Phase 0 : is_public OR user_id = auth.uid())
-- par une policy alignée sur la Phase 7 (3 conditions : is_public AND NOT
-- moderation_hidden AND owner.account_status = 'active', plus case proprio
-- total). Ces tests re-dérivent les 5 cas de la table de vérité documentée
-- dans le brief chef Phase 9, plus 1 test de régression sur la policy
-- INSERTION (Phase 0) qui ne doit pas avoir été touchée.
--
-- Conventions identiques aux fichiers de test précédents (cf. leçon dans
-- docs/TODO_TECHNIQUE.md) :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Chaque test autosuffisant (setup + assertions dans le même do $$)
--   - SECURITY INVOKER : on pose set_config('request.jwt.claim.sub', ...)
--     avant chaque requête authentifiée. auth.uid() lit le JWT positionné.
--   - lives_ok + IF ... RAISE EXCEPTION pour setup + assert.
--   - IS DISTINCT FROM plutôt que <> (gère NULL correctement).
--   - throws_ok pour exception attendue (prefix matching avec %).
--
-- Users dédiés :
--   00000000-0000-0000-0000-000000000013 — user A (visiteur / non-proprio)
--   00000000-0000-0000-0000-000000000014 — user B (propriétaire normal)
--   00000000-0000-0000-0000-000000000015 — user C (propriétaire shadowbanned)
-- Instrument dédié : TESTUSD9 (crypto pour simplifier).
--
-- Plan : 7 assertions
--   1  : proprio lit ses propres events quel que soit le contexte (cas 1)
--   2  : non-proprio lit events d'un trade public, non masqué, actif → OK (cas 2)
--   3  : non-proprio lit events d'un trade public MASQUÉ → REFUSÉ (cas 3)
--   4  : non-proprio lit events d'un trade public dont le proprio est
--        shadowbanned → REFUSÉ (cas 4)
--   5  : non-proprio lit events d'un trade privé → REFUSÉ (cas 5)
--   6  : non-proprio essaie d'INSÉRER un event dans le trade d'un autre
--        avec user_id = A (l'attaquant) → REFUSÉ
--        (régression branche 2 de la policy INSERTION Phase 0 préservée)
--   7  : proprio B essaie d'INSÉRER un event dans son propre trade
--        avec user_id = A (quelqu'un d'autre) → REFUSÉ
--        (couverture branche 1 de la policy INSERTION : anti-usurpation
--        d'attribution de l'historique immuable. Sans ce test, un
--        refactor retirant la branche `auth.uid() = user_id` passerait
--        inaperçu — et la corruption d'attribution minerait la
--        crédibilité du Proof of Performance.)
-- =============================================================================

begin;

-- ============================================================================
-- Setup : 3 users + 1 instrument
-- ============================================================================
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD9', 'Test Asset 9', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000013'::uuid, 'test+setup13@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000013'::uuid, 'test_setup13')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000014'::uuid, 'test+setup14@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000014'::uuid, 'test_setup14')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000015'::uuid, 'test+setup15@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000015'::uuid, 'test_setup15')
on conflict (id) do nothing;

select plan(7);

-- ============================================================================
-- Test 1 : proprio lit ses events quel que soit le contexte (cas 1)
-- ============================================================================
-- Cadrage : on pose le trade masqué + le proprio shadowbanned pour tester
-- que case (a) reste vraie sans dépendre de ces conditions. La policy doit
-- laisser passer l'event.
--
-- Note : on insère directement dans trade_events (le trigger AFTER INSERT
-- n'existe pas sur trade_events — seules les policies RLS et le trigger
-- forbid_trade_events_mutation sur UPDATE/DELETE s'appliquent). On
-- contourne les policies INSERT en mode postgres (BYPASSRLS = 1 sur le
-- rôle postgres), ce qui est le cas pour SQL Editor Supabase.
select lives_ok(
  $$ do $$
     declare
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_event_id uuid;
       v_count integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       -- Trade masqué par modération, proprio shadowbanned.
       -- Ces 2 conditions rendentrait la lecture impossible pour un
       -- non-proprio. Le proprio doit voir ses events quand même.
       update public.users set account_status = 'shadowbanned' where id = v_user_b;
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         true, true
       ) returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_b, 'created',
                 null, '{"status": "draft"}'::jsonb)
         returning id into v_event_id;
       -- Lecture en tant que proprio (B).
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       select count(*) into v_count
         from public.trade_events
         where id = v_event_id;
       if v_count is distinct from 1 then
         raise exception 'cas 1 (proprio lit ses events) : attendu 1 ligne, trouvé %', v_count;
       end if;
     end $$ $$,
  'cas 1 : proprio lit ses events malgré trade masqué + account_status non-actif'
);

-- ============================================================================
-- Test 2 : non-proprio lit events d'un trade public, non masqué, actif (cas 2)
-- ============================================================================
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000013'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_event_id uuid;
       v_count integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       -- Reset proprio à 'active' (cas 1 l'avait passé en shadowbanned).
       update public.users set account_status = 'active' where id = v_user_b;
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         true, false
       ) returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_b, 'created', null, '{"status": "draft"}'::jsonb)
         returning id into v_event_id;
       -- Lecture en tant que non-proprio (A).
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count
         from public.trade_events
         where id = v_event_id;
       if v_count is distinct from 1 then
         raise exception 'cas 2 (non-proprio lit events public non-masqué actif) : attendu 1 ligne, trouvé %', v_count;
       end if;
     end $$ $$,
  'cas 2 : non-proprio lit events d''un trade public, non masqué, proprio actif'
);

-- ============================================================================
-- Test 3 : non-proprio lit events d'un trade public MAIS MASQUÉ (cas 3)
-- ============================================================================
-- Le bug que cette migration corrige. AVANT la migration 020, ce cas
-- aurait retourné 1 ligne (faille). APRÈS, il retourne 0 ligne.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000013'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_event_id uuid;
       v_count integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       -- Trade public mais moderation_hidden = true.
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         true, true
       ) returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_b, 'sl_modified',
                 '{"stop_loss": 95}'::jsonb, '{"stop_loss": 90}'::jsonb)
         returning id into v_event_id;
       -- Lecture en tant que non-proprio (A).
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count
         from public.trade_events
         where id = v_event_id;
       -- AVANT migration 020 : la policy acceptait (is_public OR user_id=auth.uid())
       -- → v_count = 1. APRÈS : la nouvelle policy refuse → v_count = 0.
       if v_count is distinct from 0 then
         raise exception 'cas 3 (non-proprio lit events masqué) : attendu 0 ligne (refusé), trouvé %', v_count;
       end if;
     end $$ $$,
  'cas 3 : non-proprio NE lit PAS les events d''un trade public masqué par modération'
);

-- ============================================================================
-- Test 4 : non-proprio lit events d''un trade public dont le proprio est shadowbanned (cas 4)
-- ============================================================================
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000013'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_event_id uuid;
       v_count integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       -- Reset moderation_hidden sur le trade du cas 3 si on l'a laissé.
       -- (Le trade créé au cas 3 est orphelin sur sa propre existence —
       -- on ne le supprime pas, on en crée un nouveau ici pour ce cas.)
       -- Reset proprio à shadowbanned.
       update public.users set account_status = 'shadowbanned' where id = v_user_b;
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         true, false
       ) returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_b, 'created', null, '{"status": "draft"}'::jsonb)
         returning id into v_event_id;
       -- Lecture en tant que non-proprio (A).
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count
         from public.trade_events
         where id = v_event_id;
       -- AVANT migration 020 : la policy acceptait (is_public OR user_id=auth.uid())
       -- → v_count = 1. APRÈS : la nouvelle policy refuse → v_count = 0.
       if v_count is distinct from 0 then
         raise exception 'cas 4 (non-proprio lit events proprio shadowbanned) : attendu 0 ligne (refusé), trouvé %', v_count;
       end if;
     end $$ $$,
  'cas 4 : non-proprio NE lit PAS les events d''un trade dont le proprio est shadowbanned'
);

-- ============================================================================
-- Test 5 : non-proprio lit events d'un trade privé (cas 5)
-- ============================================================================
-- Cas déjà couvert par la policy Phase 0 (la condition OR is_public
-- bloquait déjà), mais on le ré-inclut explicitement pour confirmer
-- qu'on n'a pas régressé dessus en alignant sur Phase 7.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000013'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_event_id uuid;
       v_count integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       -- Reset proprio à 'active' pour isoler la condition is_public=false.
       update public.users set account_status = 'active' where id = v_user_b;
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         false, false
       ) returning id into v_trade_id;
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_b, 'created', null, '{"status": "draft"}'::jsonb)
         returning id into v_event_id;
       -- Lecture en tant que non-proprio (A).
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count
         from public.trade_events
         where id = v_event_id;
       if v_count is distinct from 0 then
         raise exception 'cas 5 (non-proprio lit events trade privé) : attendu 0 ligne (refusé), trouvé %', v_count;
       end if;
     end $$ $$,
  'cas 5 : non-proprio NE lit PAS les events d''un trade privé'
);

-- ============================================================================
-- Test 6 : non-proprio essaie d'INSÉRER un event dans le trade d'un
-- autre → REFUSÉ (régression policy INSERTION Phase 0 préservée)
-- ============================================================================
-- Cette migration n'a touché QUE la policy SELECT. La policy INSERTION
-- "trade_events: insertion par le propriétaire du trade" (migration 0001)
-- doit rester active et bloquer un INSERT avec reporter_id ≠ auth.uid()
-- et trade_id n'appartenant pas à l'appelant.
--
-- Note : on insère directement ici (sans utiliser le trade du test 5
-- dont on ne peut garantir l'existence post-rollback). On crée un
-- nouveau trade pour B, puis on tente d'insérer un event avec A comme
-- user_id (≠ B) — doit lever RLS WITH CHECK.
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000013'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         true, false
       ) returning id into v_trade_id;
       -- A essaie d'insérer un event dans le trade de B avec user_id = A.
       -- RLS WITH CHECK doit lever : user_id != auth.uid() OU trade.user_id != A.
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_a, 'created', null, null);
     end $$ $$,
  'new row violates row-level security policy%',
  'régression : insertion par non-propriétaire reste bloquée (policy INSERT Phase 0 préservée)'
);

-- ============================================================================
-- Test 7 : proprio B essaie d'INSÉRER un event sur son propre trade
-- avec user_id = A (usurpation d'attribution) → REFUSÉ
-- ============================================================================
-- Cadrage : la policy INSERT a DEUX conditions (cf. migration 0001) :
--   condition 1 : auth.uid() = user_id  (anti-usurpation attribution)
--   condition 2 : EXISTS trades WHERE id=trade_id AND user_id = auth.uid()
--                 (anti-écriture sur trade d'un autre)
-- Le test 6 couvre la branche 2 seule (user_id=A, trade de B → branche 2 KO).
-- Ce test 7 couvre la branche 1 seule (user_id=A MAIS trade de B : branche 2 OK
-- car B est proprio, branche 1 KO car auth.uid()=B ≠ user_id=A).
-- Les deux branches ont chacune leur test dédié — si un refactor retire
-- l'une des deux conditions, l'un des tests échoue et l'oubli est
-- visible. Sans ce test 7, retirer la condition 1 passerait inaperçu :
-- un proprio pourrait écrire un event sur son trade avec un user_id
-- qui n'est pas le sien → corruption d'attribution de l'historique
-- immuable que le Proof of Performance présente comme preuve d'intégrité.
--
-- 13/13 colonnes sur l'INSERT trades (cohérent avec tests 1-6).
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000013'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000014'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD9');
       insert into public.trades (
         user_id, instrument_id, direction, entry_price, quantity, capital,
         status, published_at, opened_at, initial_quantity, initial_capital,
         is_public, moderation_hidden
       ) values (
         v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
         now(), now(), 1, 100,
         true, false
       ) returning id into v_trade_id;
       -- B (proprio) essaie d'insérer avec user_id = A (usurpation).
       -- Branche 1 KO : auth.uid()=B ≠ user_id=A.
       -- Branche 2 OK : trade appartient bien à B (auth.uid()=B).
       -- AND global KO → throws.
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
         values (v_trade_id, v_user_a, 'created', null, null);
     end $$ $$,
  'new row violates row-level security policy%',
  'régression : proprio ne peut pas insérer un event avec user_id ≠ auth.uid() (anti-usurpation attribution)'
);

select * from finish();
rollback;
