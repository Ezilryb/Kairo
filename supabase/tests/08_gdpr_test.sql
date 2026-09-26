-- /supabase/tests/08_gdpr_test.sql
-- =============================================================================
-- Tests pgTAP pour la Phase 8 — RGPD & Export/Migration (whitepaper §10 + §11).
-- Couvre la migration 20260903000019_gdpr_export_and_restoration.sql :
--   - export_user_data (SECURITY DEFINER + check self)
--   - flag_restoration_conflict (SECURITY DEFINER + check admins)
--   - colonne users.restoration_hold_until
--
-- Conventions identiques aux fichiers de test précédents (cf. leçon dans
-- docs/TODO_TECHNIQUE.md) :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Chaque test autosuffisant (setup + assertions dans le même do $$)
--   - SECURITY DEFINER : on pose set_config('request.jwt.claim.sub', ...)
--     avant l'appel RPC. La fonction s'exécute avec les droits du proprio
--     (postgres), mais auth.uid() reflète le JWT positionné via
--     set_config — c'est le pattern utilisé par tous les tests Phase 6/7.
--   - lives_ok + IF ... RAISE EXCEPTION pour setup + assert.
--   - IS DISTINCT FROM plutôt que <> (gère NULL correctement).
--   - throws_ok pour exception attendue (prefix matching avec %).
--
-- Users dédiés :
--   00000000-0000-0000-0000-000000000010 — user A (sujet export_self)
--   00000000-0000-0000-0000-000000000011 — user B (cible export_other / cible
--                                            hold)
--   00000000-0000-0000-0000-000000000012 — user C (admin dans public.admins)
-- Instrument dédié : TESTUSD8 (crypto pour simplifier).
--
-- Plan : 9 assertions
-- A. export_user_data (5 tests) :
--    1  : self-export OK, forme du JSON (toutes clés présentes + non vides)
--    2  : export d'un autre user → throws (check self)
--    3  : export inclut commentaires soft-deleted (deleted_at NOT NULL)
--    4  : profile exclut account_status ET restoration_hold_until
--    9  : export non authentifié (auth.uid() NULL) → throws (CRITIQUE
--        sécurité : la faille <>-vs-IS DISTINCT FROM sur SECURITY DEFINER)
-- B. flag_restoration_conflict (4 tests) :
--    5  : admin pose hold → colonne mise à jour + audit_log (lives_ok)
--    6  : non-admin → throws (check admins)
--    7  : reason vide → throws (validation)
--    8  : user inexistant → throws
-- =============================================================================

begin;

-- ============================================================================
-- Setup : 3 users + 1 instrument + 1 admin (C)
-- ============================================================================
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD8', 'Test Asset 8', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000010'::uuid, 'test+setup10@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000010'::uuid, 'test_setup10')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000011'::uuid, 'test+setup11@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000011'::uuid, 'test_setup11')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000012'::uuid, 'test+setup12@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000012'::uuid, 'test_setup12')
on conflict (id) do nothing;

-- C est admin (insertion directe, comme un service_role le ferait).
insert into public.admins (user_id) values ('00000000-0000-0000-0000-000000000012'::uuid)
on conflict (user_id) do nothing;

select plan(9);

-- ============================================================================
-- A. EXPORT_USER_DATA (5 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 1 : self-export OK + forme du JSON (toutes clés présentes et peuplées)
-- ----------------------------------------------------------------------------
-- IMPORTANT — le test couvre la LONGUEUR de chaque liste, pas juste la
-- présence de la clé. Un bug dans une sous-requête (mauvaise colonne,
-- mauvaise table, mauvais filtre) ferait silencieusement diverger la
-- longueur de la liste sans que la présence de la clé le signale. C'est
-- exactement ce qui s'est passé pour likes_given avant ajout du check.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000010'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_export jsonb;
       v_profile jsonb;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD8');
       -- Setup : 1 trade de A (id retourné pour le like), 1 like de A
       -- sur ce trade, 1 follower A→B, 1 follower B→A. Vérifier la
       -- longueur de CHAQUE liste, pas juste la présence des clés.
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       insert into public.likes (trade_id, user_id)
         values (v_trade_id, v_user_a);
       insert into public.followers (follower_id, followee_id)
         values (v_user_a, '00000000-0000-0000-0000-000000000011'::uuid);
       insert into public.followers (follower_id, followee_id)
         values ('00000000-0000-0000-0000-000000000011'::uuid, v_user_a);
       -- set_config avant l'appel : pattern Phase 6/7 SECURITY DEFINER.
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       -- L'appel retourne directement le jsonb.
       select public.export_user_data(v_user_a) into v_export;
       -- Vérifier la présence et le type de chaque clé top-level.
       if not (v_export ? 'profile') then
         raise exception 'export : clé "profile" manquante';
       end if;
       if not (v_export ? 'trades') or jsonb_typeof(v_export->'trades') <> 'array' then
         raise exception 'export : clé "trades" absente ou pas un array';
       end if;
       if not (v_export ? 'trade_events') or jsonb_typeof(v_export->'trade_events') <> 'array' then
         raise exception 'export : clé "trade_events" absente ou pas un array';
       end if;
       if not (v_export ? 'comments') or jsonb_typeof(v_export->'comments') <> 'array' then
         raise exception 'export : clé "comments" absente ou pas un array';
       end if;
       if not (v_export ? 'likes_given') or jsonb_typeof(v_export->'likes_given') <> 'array' then
         raise exception 'export : clé "likes_given" absente ou pas un array';
       end if;
       if not (v_export ? 'following') or jsonb_typeof(v_export->'following') <> 'array' then
         raise exception 'export : clé "following" absente ou pas un array';
       end if;
       if not (v_export ? 'followers') or jsonb_typeof(v_export->'followers') <> 'array' then
         raise exception 'export : clé "followers" absente ou pas un array';
       end if;
       if not (v_export ? 'exported_at') then
         raise exception 'export : clé "exported_at" manquante';
       end if;
       -- Cohérence de contenu : 1 trade, 1 like, 1 follow donné, 1 follow reçu.
       if jsonb_array_length(v_export->'trades') <> 1 then
         raise exception 'export : attendu 1 trade, trouvé %', jsonb_array_length(v_export->'trades');
       end if;
       if jsonb_array_length(v_export->'likes_given') <> 1 then
         raise exception 'export : attendu 1 like donné, trouvé %', jsonb_array_length(v_export->'likes_given');
       end if;
       if jsonb_array_length(v_export->'following') <> 1 then
         raise exception 'export : attendu 1 follow donné, trouvé %', jsonb_array_length(v_export->'following');
       end if;
       if jsonb_array_length(v_export->'followers') <> 1 then
         raise exception 'export : attendu 1 follow reçu, trouvé %', jsonb_array_length(v_export->'followers');
       end if;
       -- Le profile pointe bien vers A.
       v_profile := v_export->'profile';
       if v_profile->>'id' is distinct from v_user_a::text then
         raise exception 'export : profile.id attendu %, trouvé %', v_user_a, v_profile->>'id';
       end if;
       if v_profile->>'pseudo' is distinct from 'test_setup10' then
         raise exception 'export : profile.pseudo attendu test_setup10, trouvé %', v_profile->>'pseudo';
       end if;
     end $$ $$,
  'export_user_data self → JSON avec toutes les clés + contenu cohérent (longueurs)'
);

-- ----------------------------------------------------------------------------
-- Test 2 : export d'un autre user → throws (check p_user_id = auth.uid())
-- ----------------------------------------------------------------------------
-- Note : SECURITY DEFINER ne dispense PAS du check — l'appelant qui passe
-- l'id d'un autre user doit voir l'erreur immédiatement, pas recevoir un
-- export silencieux (qui serait soit vide si les sub-requêtes filtraient
-- par p_user_id, soit un trou de sécurité si elles ne filtraient pas).
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000010'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000011'::uuid;
     begin
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       -- A essaie d'exporter B → throws check self.
       perform public.export_user_data(v_user_b);
     end $$ $$,
  'export_user_data: p_user_id (%) ne correspond pas à auth.uid() (%)%',
  'export d''un autre user refusé (check p_user_id = auth.uid())'
);

-- ----------------------------------------------------------------------------
-- Test 3 : export inclut les commentaires soft-deleted (justification SECURITY DEFINER)
-- ----------------------------------------------------------------------------
-- Sans SECURITY DEFINER, la policy SELECT de trade_comments filtre
-- `deleted_at IS NULL`, donc l'auteur lui-même ne verrait pas ses
-- commentaires supprimés dans son export. C'est exactement ce qu'on
-- contourne avec SECURITY DEFINER + check self — la portabilité RGPD
-- couvre toutes les données détenues, y compris les supprimées.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000010'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_export jsonb;
       v_count_comments integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD8');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_a, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       -- 1 commentaire "actif" + 1 commentaire soft-deleted.
       insert into public.trade_comments (trade_id, user_id, content)
         values (v_trade_id, v_user_a, 'commentaire actif');
       insert into public.trade_comments (trade_id, user_id, content, deleted_at)
         values (v_trade_id, v_user_a, 'commentaire supprime', now());
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.export_user_data(v_user_a) into v_export;
       -- Les DEUX commentaires doivent apparaître dans l'export.
       select count(*) into v_count_comments
         from jsonb_array_elements(v_export->'comments') c
         where c->>'content' in ('commentaire actif', 'commentaire supprime');
       if v_count_comments <> 2 then
         raise exception 'export : attendu 2 commentaires (actif + soft-deleted), trouvé % dans l''export', v_count_comments;
       end if;
     end $$ $$,
  'export inclut les commentaires soft-deleted (portabilité RGPD intégrale)'
);

-- ----------------------------------------------------------------------------
-- Test 4 : profile exclut account_status ET restoration_hold_until
-- ----------------------------------------------------------------------------
-- Les deux sont des états administratifs imposés de l'extérieur
-- (modération §12, RGPD §11), pas des données fournies par / décrivant
-- l'activité de trading de l'user. Pas leur place dans un export
-- user-facing (portabilité RGPD art. 20 = données du titulaire, pas
-- données administratives sur lui).
--
-- On pose les deux colonnes à des valeurs NON-default pour s'assurer
-- que ce n'est pas juste une coïncidence "valeur par défaut = absente"
-- qui masquerait un oubli de l'opérateur `-`.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000010'::uuid;
       v_export jsonb;
       v_profile jsonb;
     begin
       update public.users
         set account_status         = 'shadowbanned',
             restoration_hold_until = now() + interval '10 days'
         where id = v_user_a;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select public.export_user_data(v_user_a) into v_export;
       v_profile := v_export->'profile';
       if v_profile ? 'account_status' then
         raise exception 'profile.account_status doit être exclu, trouvé %', v_profile->>'account_status';
       end if;
       if v_profile ? 'restoration_hold_until' then
         raise exception 'profile.restoration_hold_until doit être exclu, trouvé %', v_profile->>'restoration_hold_until';
       end if;
       -- Sanity check : les autres clés profil attendues sont présentes.
       if not (v_profile ? 'id') then
         raise exception 'profile.id manquant';
       end if;
       if not (v_profile ? 'pseudo') then
         raise exception 'profile.pseudo manquant';
       end if;
       if not (v_profile ? 'is_public') then
         raise exception 'profile.is_public manquant';
       end if;
       if not (v_profile ? 'created_at') then
         raise exception 'profile.created_at manquant';
       end if;
     end $$ $$,
  'profile exclut account_status ET restoration_hold_until (états administratifs non exportables)'
);

-- ============================================================================
-- B. FLAG_RESTORATION_CONFLICT (4 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 5 : admin pose hold → colonne mise à jour + audit_log créé
-- ----------------------------------------------------------------------------
-- AUTO-SUFFISANCE : cleanup explicite de audit_logs pour ce user en tête
-- (le test 5 va vérifier un COUNT = 1 sur les audit_logs de B, donc tout
-- résidu antérieur serait compté et ferait échouer le test — exactement
-- la même leçon Phase 7 tests 5/7 sur les agrégats non scopés).
select lives_ok(
  $$ do $$
     declare
       v_user_b uuid := '00000000-0000-0000-0000-000000000011'::uuid;
       v_user_c uuid := '00000000-0000-0000-0000-000000000012'::uuid;
       v_user public.users;
       v_hold timestamptz;
       v_audit_count integer;
     begin
       -- Cleanup audit_logs pour B (les tests précédents Phase 7 ont pu
       -- laisser des traces ; on veut un décompte précis).
       delete from public.audit_logs where entity_id = v_user_b;
       -- C (admin) pose le hold sur B.
       perform set_config('request.jwt.claim.sub', v_user_c::text, true);
       select * into v_user
         from public.flag_restoration_conflict(v_user_b, 'pseudo déjà pris à la restauration');
       -- L'utilisateur retourné doit être B.
       if v_user.id is distinct from v_user_b then
         raise exception 'flag_restoration_conflict : attendu user %, trouvé %', v_user_b, v_user.id;
       end if;
       -- La colonne restoration_hold_until doit être posée ≈ now() + 10j.
       if v_user.restoration_hold_until is null then
         raise exception 'flag_restoration_conflict : restoration_hold_until non posé';
       end if;
       if v_user.restoration_hold_until < now() then
         raise exception 'flag_restoration_conflict : hold dans le passé (% < now())', v_user.restoration_hold_until;
       end if;
       if v_user.restoration_hold_until > now() + interval '11 days' then
         raise exception 'flag_restoration_conflict : hold trop loin dans le futur (% > now()+11d)', v_user.restoration_hold_until;
       end if;
       -- Vérifier aussi via SELECT direct (pas juste le retour de la RPC).
       select restoration_hold_until into v_hold
         from public.users where id = v_user_b;
       if v_hold is distinct from v_user.restoration_hold_until then
         raise exception 'flag_restoration_conflict : hold retourné (%) ≠ hold en base (%)',
           v_user.restoration_hold_until, v_hold;
       end if;
       -- Audit log : exactement 1 ligne avec action = gdpr.restoration_conflict_flagged.
       select count(*) into v_audit_count
         from public.audit_logs
         where action = 'gdpr.restoration_conflict_flagged'
           and entity_type = 'user'
           and entity_id = v_user_b;
       if v_audit_count <> 1 then
         raise exception 'flag_restoration_conflict : attendu 1 audit_log, trouvé %', v_audit_count;
       end if;
     end $$ $$,
  'flag_restoration_conflict par admin → hold_until posé + audit_log'
);

-- ----------------------------------------------------------------------------
-- Test 6 : non-admin → throws (check admins)
-- ----------------------------------------------------------------------------
-- Auto-suffisance : on remet hold_until à NULL en tête pour ne pas
-- dépendre d'un état antérieur (le test 5 vient de le poser).
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-000000000010'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000011'::uuid;
     begin
       -- Cleanup audit_logs B (le test 5 a posé 1 ligne, il en reste
       -- au moins 1 même après ce test, mais pour les tests suivants
       -- qui dépendent du compte on nettoie quand nécessaire).
       -- (pas de cleanup ici, le throws_ok annule tout).
       update public.users set restoration_hold_until = null where id = v_user_b;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       perform public.flag_restoration_conflict(v_user_b, 'tentative non-admin');
     end $$ $$,
  'flag_restoration_conflict: user (%) n''est pas admin%',
  'flag_restoration_conflict par non-admin refusé (check admins en premier)'
);

-- ----------------------------------------------------------------------------
-- Test 7 : reason vide → throws (validation p_reason non vide)
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_c uuid := '00000000-0000-0000-0000-000000000012'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-000000000011'::uuid;
     begin
       perform set_config('request.jwt.claim.sub', v_user_c::text, true);
       perform public.flag_restoration_conflict(v_user_b, '');
     end $$ $$,
  'flag_restoration_conflict: p_reason obligatoire%',
  'flag_restoration_conflict avec reason vide refusé (validation)'
);

-- ----------------------------------------------------------------------------
-- Test 8 : user inexistant → throws
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_c uuid := '00000000-0000-0000-0000-000000000012'::uuid;
       v_ghost uuid := '00000000-0000-0000-0000-deadbeef0000'::uuid;
     begin
       perform set_config('request.jwt.claim.sub', v_user_c::text, true);
       perform public.flag_restoration_conflict(v_ghost, 'user qui n''existe pas');
     end $$ $$,
  'flag_restoration_conflict: user (%) introuvable%',
  'flag_restoration_conflict sur user inexistant → erreur explicite'
);

-- ----------------------------------------------------------------------------
-- Test 9 (CRITIQUE sécurité) : export non authentifié (auth.uid() NULL) → throws
-- ----------------------------------------------------------------------------
-- Bug à éviter absolument (Phase 8 round 1, raté à la première rédaction) :
-- le check `if p_user_id <> auth.uid()` avec un appel non authentifié
-- (auth.uid() = NULL) donne `uuid <> NULL` = NULL (logique 3 valeurs),
-- traité comme FALSE par IF PL/pgSQL → branche raise ne s'exécute pas.
-- SECURITY DEFINER + aucune REVOKE EXECUTE FROM PUBLIC = un POST
-- /rest/v1/rpc/export_user_data anonyme + UUID de victime = export
-- intégral contournant le masquage Phase 6 (to_jsonb(t) sur toutes
-- les lignes, capital, notes, emotion, mistake_type, etc.).
--
-- set_config('request.jwt.claim.sub', '', true) reproduit exactement
-- le cas d'un appel REST sans header Authorization (current_setting
-- → '' → nullif('', '') → NULL → auth.uid() = NULL).
--
-- Ce test reproduit ce cas et vérifie que IS DISTINCT FROM (et pas <>)
-- est bien utilisé dans le check. Sans le fix, ce test lèverait
-- silencieusement la branche raise et exécuterait jsonb_build_object
-- avec les sub-requêtes filtrées sur p_user_id = uuid de la victime
-- → données exfiltrées → lives_ok passerait quand même (pas d'erreur),
-- mais throws_ok ici FORCE l'erreur attendue. C'est ce qui rend ce
-- test essentiel : il transforme une fuite silencieuse en exception
-- observable par pgTAP.
--
-- Pas de renumérotation des tests 1-8 (chef explicite) : on ajoute
-- juste le 9 à la fin, après le 8.
select throws_ok(
  $$ do $$
     declare
       v_user_b uuid := '00000000-0000-0000-0000-000000000011'::uuid;
     begin
       -- Simule un appel non authentifié : aucun set_config n'a jamais
       -- positionné le JWT. set_config('...', '', true) reproduit
       -- exactement ce cas (current_setting -> '', nullif('','') -> NULL,
       -- donc auth.uid() = NULL) — même chemin qu'un appel REST Supabase
       -- sans header Authorization, servi par le rôle anon.
       perform set_config('request.jwt.claim.sub', '', true);
       perform public.export_user_data(v_user_b);
     end $$ $$,
  'export_user_data: p_user_id (%) ne correspond pas à auth.uid() (%)%',
  'export_user_data non authentifié (auth.uid() NULL) → refusé, pas de fuite'
);

select * from finish();
rollback;
