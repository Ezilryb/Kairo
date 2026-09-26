-- /supabase/tests/07_moderation_test.sql
-- =============================================================================
-- Tests pgTAP pour la Phase 7 — Modération & Sanctions (whitepaper §12).
-- Couvre les 4 migrations :
--   - 20260903000015_admins_and_account_status.sql  (table admins + type
--                                                      account_status + colonne)
--   - 20260903000016_moderation_columns.sql         (colonnes moderation_*
--                                                      + index partiels)
--   - 20260903000017_auto_moderation_trigger.sql    (trigger AFTER INSERT
--                                                      sur reports)
--   - 20260903000018_admin_rpcs_and_visibility.sql  (2 RPCs admin + UPDATE
--                                                      policies SELECT)
--
-- Conventions identiques aux fichiers de test précédents (cf. leçon dans
-- docs/TODO_TECHNIQUE.md) :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Chaque test autosuffisant (setup + assertions dans le même do $$)
--   - SECURITY INVOKER : on pose set_config('request.jwt.claim.sub', ...)
--     avant l'appel RPC. SECURITY DEFINER : la fonction s'exécute avec
--     les droits du proprio (postgres), pas du caller — auth.uid()
--     reste celui du caller (jwt.claim.sub).
--   - lives_ok + IF ... RAISE EXCEPTION pour setup + assert (un bloc DO
--     est void, pas de RETURN <valeur>).
--   - IS DISTINCT FROM plutôt que <> (gère NULL correctement).
--   - throws_ok pour exception attendue.
--
-- Users dédiés :
--   00000000-0000-0000-0000-00000000000b — user A (rapporteur principal,
--                                            non-admin, non-proprio)
--   00000000-0000-0000-0000-00000000000c — user B (cible des signalements,
--                                            compte à modérer)
--   00000000-0000-0000-0000-00000000000d — user C (admin, dans public.admins)
--   00000000-0000-0000-0000-00000000000e — user E (utilisé pour tests de
--                                            visibilité post-masquage /
--                                            shadowban)
-- Instrument dédié : TESTUSD7 (crypto pour simplifier).
--
-- Plan : 14 assertions
-- A. reports RLS + trigger (6 tests) :
--    1  : insert report par soi-même → OK (lives_ok)
--    2  : insert report avec reporter_id ≠ auth.uid() → throws (throws_ok)
--    3  : 2 reports sur trade de B → trade masqué (lives_ok)
--    4  : 2 reports sur comment de B → comment masqué (lives_ok)
--    5  : 2 reports sur user sans post → ne masque rien (lives_ok)
--    6  : reports dismissed comptent (incl. dans le seuil) (lives_ok)
-- B. alerte compte (1 test) :
--    7  : 4 posts masqués du même owner en < 24h → audit_log (lives_ok)
-- C. RPCs admin (4 tests) :
--    8  : admin_resolve_report par admin → OK (lives_ok)
--    9  : admin_resolve_report par non-admin → throws (throws_ok)
--    10 : admin_set_account_status par admin → OK + audit_log (lives_ok)
--    11 : admin_set_account_status par non-admin → throws (throws_ok)
-- D. visibilité post-masquage + shadowban (3 tests) :
--    12 : trade masqué : proprio voit, non-proprio ne voit pas (lives_ok)
--    13 : account_status=shadowbanned : trades publics invisibles aux autres
--        (lives_ok)
--    14 : account_status=shadowbanned : proprio voit ses propres trades
--        (lives_ok)
--
-- Note accès audit_logs : la table n'a aucune policy RLS (lecture/écriture
-- service_role uniquement, cf. migration initiale 0001). En SQL Editor
-- Supabase, on tourne en postgres (BYPASSRLS), donc les SELECT en test
-- passent directement. Si on devait exécuter ce test en rôle authentifié
-- (non-supabase), il faudrait un wrapper SECURITY DEFINER — pas le cas
-- ici.
-- =============================================================================

begin;

-- ============================================================================
-- Setup : 4 users + 1 instrument + 1 admin (C)
-- ============================================================================
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD7', 'Test Asset 7', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000000b'::uuid, 'test+setupb@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000000b'::uuid, 'test_setupb')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000000c'::uuid, 'test+setupc@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000000c'::uuid, 'test_setupc')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000000d'::uuid, 'test+setupd@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000000d'::uuid, 'test_setupd')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000000e'::uuid, 'test+setupe@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000000e'::uuid, 'test_setupe')
on conflict (id) do nothing;

-- C est admin (insertion directe, comme un service_role le ferait).
-- Le test 11 utilise C comme admin pour vérifier le check.
insert into public.admins (user_id) values ('00000000-0000-0000-0000-00000000000d'::uuid)
on conflict (user_id) do nothing;

select plan(14);

-- ============================================================================
-- A. REPORTS RLS + TRIGGER (6 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 1 : insert report par soi-même sur trade public → OK
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason)
         values (v_user_a, v_trade_id, 'spam');
     end $$ $$,
  'insert report par soi-même sur trade public OK'
);

-- ----------------------------------------------------------------------------
-- Test 2 : insert report avec reporter_id ≠ auth.uid() → throws (RLS)
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       -- reporter_id = B mais auth.uid() = A → throws RLS INSERT.
       insert into public.reports (reporter_id, trade_id, reason)
         values (v_user_b, v_trade_id, 'spam');
     end $$ $$,
  'new row violates row-level security policy%',
  'insert report avec reporter_id ≠ auth.uid() refusé (RLS WITH CHECK)'
);

-- ----------------------------------------------------------------------------
-- Test 3 : 2 reports sur trade de B → trade masqué
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_hidden boolean;
       v_flagged_at timestamptz;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'spam');
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'scam');
       -- Bascule sur B (proprio) pour cette lecture : sous A (non-
       -- proprio), la policy SELECT trades (migration 018) rend la
       -- ligne entièrement invisible dès que moderation_hidden=true
       -- (le disjoint is_public AND NOT moderation_hidden échoue, et
       -- auth.uid() ≠ user_id) — le SELECT renverrait 0 ligne et
       -- v_hidden resterait NULL, pas un signe d'échec du masquage.
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       -- Vérifier que le trade est masqué
       select moderation_hidden, moderation_flagged_at into v_hidden, v_flagged_at
         from public.trades where id = v_trade_id;
       if v_hidden is distinct from true then
         raise exception 'trade masqué : attendu moderation_hidden=true, trouvé %', v_hidden;
       end if;
       if v_flagged_at is null then
         raise exception 'trade masqué : attendu moderation_flagged_at NOT NULL, trouvé NULL';
       end if;
     end $$ $$,
  '2 reports sur trade de B → trade masqué (moderation_hidden=true, flagged_at NOT NULL)'
);

-- ----------------------------------------------------------------------------
-- Test 4 : 2 reports sur comment de B → comment masqué + non-auteur ne voit plus
-- ----------------------------------------------------------------------------
-- La policy SELECT de trade_comments (migration 018) gate maintenant
-- sur le commentaire lui-même : moderation_hidden=true ET user_id !=
-- auth.uid() → ligne invisible. Donc :
--   - B (auteur) doit toujours voir son commentaire masqué
--   - A (rapporteur, non-auteur) ne doit plus voir le commentaire
-- On vérifie les 2 (le masquage d'un commentaire est un no-op si
-- seul le trigger pose la colonne sans que la policy ne la consulte).
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_comment_id uuid;
       v_hidden_by_author boolean;
       v_count_as_author integer;
       v_count_as_other integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       insert into public.trade_comments (trade_id, user_id, content)
         values (v_trade_id, v_user_b, 'commentaire test')
         returning id into v_comment_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, comment_id, reason) values (v_user_a, v_comment_id, 'spam');
       insert into public.reports (reporter_id, comment_id, reason) values (v_user_a, v_comment_id, 'harassment');
       -- (a) B (auteur) voit toujours son commentaire, masqué :
       --     moderation_hidden=true sur la ligne qu'il peut SELECT.
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       select moderation_hidden into v_hidden_by_author
         from public.trade_comments where id = v_comment_id;
       if v_hidden_by_author is distinct from true then
         raise exception 'comment masqué vu par auteur : attendu moderation_hidden=true, trouvé %', v_hidden_by_author;
       end if;
       select count(*) into v_count_as_author
         from public.trade_comments where id = v_comment_id;
       if v_count_as_author <> 1 then
         raise exception 'comment masqué vu par auteur : attendu 1 ligne, trouvé %', v_count_as_author;
       end if;
       -- (b) A (non-auteur) ne voit PLUS le commentaire (policy gate sur
       --     moderation_hidden). Sans le fix migration 018, A verrait
       --     encore 1 ligne — c'est exactement ce que ce test attrape.
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count_as_other
         from public.trade_comments where id = v_comment_id;
       if v_count_as_other <> 0 then
         raise exception 'comment masqué vu par non-auteur : attendu 0, trouvé %', v_count_as_other;
       end if;
     end $$ $$,
  '2 reports sur comment de B → masqué, auteur voit (1), non-auteur ne voit pas (0)'
);

-- ----------------------------------------------------------------------------
-- Test 5 : 2 reports sur user sans post (reported_user_id seul) → ne masque rien
-- ----------------------------------------------------------------------------
-- Le trigger vérifie trade_id et comment_id ; si les deux sont null,
-- v_target_owner reste null et le trigger return new sans rien faire.
-- (reported_user_id seul est un signalement "profil", pas "post".)
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_count integer;
     begin
       -- AUTO-SUFFISANCE : la vérification en fin de bloc est un
       -- count(*) WHERE user_id = B AND moderation_hidden=true (agrégat
       -- sur tous les trades de B, pas sur un trade_id précis). Sans
       -- cleanup, le résidu du test 3 (1 trade de B masqué) se retrouve
       -- dans ce count et déclenche un faux positif. Même leçon que
       -- Phase 4 tests 12/22, Phase 6 tests 11/12/14 — étendue aux
       -- agrégats non scopés.
       --
       -- Couverture : à l'entrée du test 5, 5 reports référencent un
       -- post de B (T1 = 1 via trade_id, T3 = 2 via trade_id, T4 = 2
       -- via comment_id). Tous couverts par le WHERE ci-dessous.
       --
       -- Ordre : reports d'abord, puis trades — sinon ON DELETE SET
       -- NULL sur reports.trade_id/comment_id est implémenté comme
       -- UPDATE interne, soumis au CHECK
       --   (trade_id is not null or comment_id is not null or reported_user_id is not null)
       -- Supprimer d'abord les trades laisserait les reports orphelins
       -- avec les 3 colonnes cible NULL → CHECK violée → exception.
       delete from public.reports
         where trade_id in (select id from public.trades where user_id = v_user_b)
            or comment_id in (select id from public.trade_comments where user_id = v_user_b);
       delete from public.trades where user_id = v_user_b;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, reported_user_id, reason) values (v_user_a, v_user_b, 'spam');
       insert into public.reports (reporter_id, reported_user_id, reason) values (v_user_a, v_user_b, 'impersonation');
       -- Aucun trade ou comment de B ne doit être masqué par ces 2 reports.
       -- Si la condition du trigger avait été "compte aussi les reports
       -- sur reported_user_id", B aurait des trades masqués — on vérifie
       -- que ce n'est pas le cas. La logique du trigger ne s'applique
       -- qu'à trade_id/comment_id, pas reported_user_id.
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       select count(*) into v_count from public.trades
         where user_id = v_user_b and moderation_hidden = true;
       if v_count <> 0 then
         raise exception 'report sur reported_user_id seul ne doit pas masquer : trouvé % trades masqués', v_count;
       end if;
     end $$ $$,
  '2 reports sur reported_user_id seul → ne masque aucun trade/comment'
);

-- ----------------------------------------------------------------------------
-- Test 6 : reports dismissed comptent dans le seuil (incl. dans le count)
-- ----------------------------------------------------------------------------
-- Si on ne comptait que les 'pending', un signalement 'dismissed'
-- ferait repartir le compteur à zéro — contournement trivial du seuil.
-- On vérifie : 1 report pending + 1 report dismissed (mis à jour)
-- + 1 report pending → count = 3 (incluant dismissed), masqué.
-- Si seuls pending comptaient, count = 2 → masqué aussi. Pour vraiment
-- voir la différence, on vérifie que masquer se produit sur le seuil 2
-- même quand on a 1 pending + 1 dismissed : on insert un 2e pending
-- qui devrait suffire à masquer grâce au dismissed déjà compté.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_report_id uuid;
       v_hidden boolean;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'spam')
         returning id into v_report_id;
       -- Marquer ce 1er report comme dismissed via l'admin (C est admin).
       perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d'::text, true);
       perform public.admin_resolve_report(v_report_id, 'dismissed');
       -- 2e report pending → si dismissed comptait, total=2 → masqué.
       -- Si on ne comptait que pending, total=1 → pas masqué.
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'scam');
       -- Bascule sur B (proprio) : même raison que le test 3 — sous A,
       -- la ligne devient invisible dès que moderation_hidden=true.
       perform set_config('request.jwt.claim.sub', v_user_b::text, true);
       select moderation_hidden into v_hidden
         from public.trades where id = v_trade_id;
       if v_hidden is distinct from true then
         raise exception 'reports dismissed comptent : attendu masqué, trouvé %', v_hidden;
       end if;
     end $$ $$,
  'reports dismissed comptent dans le seuil (count = 2, masqué)'
);

-- ============================================================================
-- B. ALERTE COMPTE (1 test)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 7 : 4 posts masqués du même owner en < 24h → audit_log
-- ----------------------------------------------------------------------------
-- AUTO-SUFFISANCE : les tests 3 (1 trade masqué), 4 (1 comment masqué)
-- et 6 (1 trade masqué via dismissed) laissent user_b avec 3 posts
-- masqués. Sans cleanup, le seuil serait franchi dès la 1re itération
-- de cette boucle (4 posts déjà masqués + 1 nouveau = 4, alerte),
-- et la dédup de l'alerte dans le trigger (migration 017) la rendrait
-- silencieuse — ce qui rendrait le test passant mais le récit faux.
-- On repart d'un état connu.
--
-- ORDRE DU CLEANUP critique : il faut d'abord supprimer les reports
-- qui ciblent les trades/commentaires de B AVANT de supprimer les
-- trades eux-mêmes. ON DELETE SET NULL sur reports.trade_id /
-- reports.comment_id est implémenté par PostgreSQL comme un UPDATE
-- interne, soumis au CHECK
--   (trade_id is not null or comment_id is not null or reported_user_id is not null)
-- Si on supprime d'abord les trades (ou cascade via trade_comments),
-- les reports perdent leur cible → CHECK violée → exception. Couverture
-- : test 1 (1), test 3 (2), test 6 (2) → 5 reports via trade_id ;
-- test 4 (2) → 2 reports via comment_id. Total 7 reports couverts,
-- tous supprimés avant le DELETE des trades.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_audit_count integer;
       v_t_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       -- Cleanup : d'abord les reports qui pointent sur les posts de B
       -- (pour qu'aucun report ne se retrouve avec les 3 colonnes cible
       -- à NULL après le DELETE en cascade).
       delete from public.reports
         where trade_id in (select id from public.trades where user_id = v_user_b)
            or comment_id in (select id from public.trade_comments where user_id = v_user_b);
       -- Ensuite les trades (cascade trade_comments via FK).
       delete from public.trades where user_id = v_user_b;
       -- Aussi : supprimer l'audit_log de test 6 (admin_resolve_report
       -- pour dismissed) qui ne dérange pas ce test mais garde l'env
       -- propre. Pas critique.
       delete from public.audit_logs where entity_id = v_user_b;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       -- 4 trades de B ; pour chacun, 2 reports de A.
       -- Cumul des posts masqués en 24h : 1 → 2 → 3 → 4 (franchissement
       -- du seuil à la 4e itération, alerte insérée une seule fois grâce
       -- à la dédup de la migration 017).
       for i in 1..4 loop
         insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
         values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
                 now(), now(), 1, 100)
         returning id into v_t_id;
         insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_t_id, 'spam');
         insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_t_id, 'scam');
       end loop;
       -- 4 posts masqués du même owner en 24h → exactement 1 audit_log
       -- (la dédup empêche les insertions suivantes).
       select count(*) into v_audit_count
         from public.audit_logs
         where action = 'moderation.account_flagged'
           and entity_type = 'user'
           and entity_id = v_user_b;
       if v_audit_count <> 1 then
         raise exception 'alerte compte : attendu 1 ligne audit_log moderation.account_flagged, trouvé %', v_audit_count;
       end if;
     end $$ $$,
  '4 posts masqués du même owner en < 24h → 1 audit_log (franchissement à la 4e itération, dédup)'
);

-- ============================================================================
-- C. RPCS ADMIN (4 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 8 : admin_resolve_report par admin → OK + journalise dans audit_logs
-- ----------------------------------------------------------------------------
-- p_notes doit être persisté (sinon silence — l'admin appelle avec une
-- note, elle disparaît, personne ne sait qu'elle a existé). La cohérence
-- avec admin_set_account_status (migration 018) impose la même logique
-- de traçabilité dans audit_logs.
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_user_c uuid := '00000000-0000-0000-00000000000d'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_report_id uuid;
       v_new_status public.report_status;
       v_resolved_by uuid;
       v_audit_count integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'spam')
         returning id into v_report_id;
       -- C (admin) résout le report, AVEC une note
       perform set_config('request.jwt.claim.sub', v_user_c::text, true);
       select status, resolved_by into v_new_status, v_resolved_by
         from public.admin_resolve_report(v_report_id, 'resolved', 'note de test 8');
       if v_new_status is distinct from 'resolved'::public.report_status then
         raise exception 'admin_resolve_report : attendu status=resolved, trouvé %', v_new_status;
       end if;
       if v_resolved_by is distinct from v_user_c then
         raise exception 'admin_resolve_report : attendu resolved_by=C, trouvé %', v_resolved_by;
       end if;
       -- Vérifier que la résolution a été journalisée (cohérence avec
       -- admin_set_account_status qui log aussi dans audit_logs).
       select count(*) into v_audit_count
         from public.audit_logs
         where action = 'moderation.report_resolved'
           and entity_type = 'report'
           and entity_id = v_report_id;
       if v_audit_count <> 1 then
         raise exception 'admin_resolve_report : attendu 1 audit_log, trouvé %', v_audit_count;
       end if;
     end $$ $$,
  'admin_resolve_report par admin → status=resolved + audit_log moderation.report_resolved'
);

-- ----------------------------------------------------------------------------
-- Test 9 : admin_resolve_report par non-admin → throws
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_report_id uuid;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_b, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'spam')
         returning id into v_report_id;
       -- A (non-admin) essaie de résoudre
       perform public.admin_resolve_report(v_report_id, 'resolved');
     end $$ $$,
  'admin_resolve_report: user (%) n''est pas admin',
  'admin_resolve_report par non-admin refusé (check admins en premier)'
);

-- ----------------------------------------------------------------------------
-- Test 10 : admin_set_account_status par admin → OK + audit_log
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
       v_user_c uuid := '00000000-0000-0000-0000-00000000000d'::uuid;
       v_status public.account_status;
       v_audit_count integer;
     begin
       perform set_config('request.jwt.claim.sub', v_user_c::text, true);
       select account_status into v_status
         from public.admin_set_account_status(v_user_b, 'shadowbanned', 'Phase 7 test 10');
       if v_status is distinct from 'shadowbanned'::public.account_status then
         raise exception 'admin_set_account_status : attendu shadowbanned, trouvé %', v_status;
       end if;
       select count(*) into v_audit_count
         from public.audit_logs
         where action = 'moderation.account_status_changed'
           and entity_type = 'user'
           and entity_id = v_user_b;
       if v_audit_count <> 1 then
         raise exception 'admin_set_account_status : attendu 1 audit_log, trouvé %', v_audit_count;
       end if;
     end $$ $$,
  'admin_set_account_status par admin → status=shadowbanned + audit_log'
);

-- ----------------------------------------------------------------------------
-- Test 11 : admin_set_account_status par non-admin → throws
-- ----------------------------------------------------------------------------
select throws_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_b uuid := '00000000-0000-0000-0000-00000000000c'::uuid;
     begin
       -- A (non-admin) essaie
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       perform public.admin_set_account_status(v_user_b, 'banned', 'tentative non-admin');
     end $$ $$,
  'admin_set_account_status: user (%) n''est pas admin',
  'admin_set_account_status par non-admin refusé (check admins en premier)'
);

-- ============================================================================
-- D. VISIBILITÉ POST-MASQUAGE + SHADOWBAN (3 tests)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Test 12 : trade masqué : proprio voit, non-proprio ne voit pas
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_e uuid := '00000000-0000-0000-0000-00000000000e'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_count_as_owner integer;
       v_count_as_visitor integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       -- E crée un trade public, qui sera masqué via 2 reports
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_e, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'spam');
       insert into public.reports (reporter_id, trade_id, reason) values (v_user_a, v_trade_id, 'scam');
       -- Le trade est maintenant masqué (moderation_hidden=true).
       -- E (proprio) le voit toujours.
       perform set_config('request.jwt.claim.sub', v_user_e::text, true);
       select count(*) into v_count_as_owner
         from public.trades where id = v_trade_id;
       if v_count_as_owner <> 1 then
         raise exception 'trade masqué vu par proprio : attendu 1, trouvé %', v_count_as_owner;
       end if;
       -- A (non-proprio, non-admin) ne le voit PAS.
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count_as_visitor
         from public.trades where id = v_trade_id;
       if v_count_as_visitor <> 0 then
         raise exception 'trade masqué vu par non-proprio : attendu 0, trouvé %', v_count_as_visitor;
       end if;
     end $$ $$,
  'trade masqué : proprio voit (1), non-proprio ne voit pas (0)'
);

-- ----------------------------------------------------------------------------
-- Test 13 : account_status=shadowbanned : trades publics invisibles aux autres
-- ----------------------------------------------------------------------------
select lives_ok(
  $$ do $$
     declare
       v_user_a uuid := '00000000-0000-0000-0000-00000000000b'::uuid;
       v_user_c uuid := '00000000-0000-0000-0000-00000000000d'::uuid;
       v_user_e uuid := '00000000-0000-0000-0000-00000000000e'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_count_as_visitor integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       -- E crée un trade public (PAS masqué par modération, juste account_status=shadowbanned)
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_e, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       -- C (admin) passe E en shadowbanned
       perform set_config('request.jwt.claim.sub', v_user_c::text, true);
       perform public.admin_set_account_status(v_user_e, 'shadowbanned', 'Phase 7 test 13');
       -- A (non-proprio) ne voit plus le trade de E
       perform set_config('request.jwt.claim.sub', v_user_a::text, true);
       select count(*) into v_count_as_visitor
         from public.trades where id = v_trade_id;
       if v_count_as_visitor <> 0 then
         raise exception 'shadowban : non-proprio voit le trade, attendu 0, trouvé %', v_count_as_visitor;
       end if;
     end $$ $$,
  'shadowban : trades publics du owner invisibles aux non-proprios'
);

-- ----------------------------------------------------------------------------
-- Test 14 : account_status=shadowbanned : proprio voit toujours ses trades
-- ----------------------------------------------------------------------------
-- "Le compte reste actif" — le proprio doit voir ce qui lui arrive,
-- même si son contenu est masqué aux autres. C'est la sémantique
-- explicitée par le chef dans le brief Phase 7.
-- Auto-suffisance : on pose shadowbanned explicitement ici, sans
-- dépendre du test 13. Idempotent — sans effet si déjà posé.
select lives_ok(
  $$ do $$
     declare
       v_user_e uuid := '00000000-0000-0000-0000-00000000000e'::uuid;
       v_inst_id uuid;
       v_trade_id uuid;
       v_count_as_owner integer;
     begin
       v_inst_id := (select id from public.instruments where symbol = 'TESTUSD7');
       -- Auto-suffisance : on pose shadowbanned sans dépendre du test 13.
       update public.users set account_status = 'shadowbanned' where id = v_user_e;
       -- E crée un nouveau trade et vérifie qu'il le voit malgré le shadowban.
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at, initial_quantity, initial_capital)
       values (v_user_e, v_inst_id, 'long', 100, 1, 100, 'live',
               now(), now(), 1, 100)
       returning id into v_trade_id;
       perform set_config('request.jwt.claim.sub', v_user_e::text, true);
       select count(*) into v_count_as_owner
         from public.trades where id = v_trade_id;
       if v_count_as_owner <> 1 then
         raise exception 'shadowban : proprio ne voit pas son propre trade, attendu 1, trouvé %', v_count_as_owner;
       end if;
     end $$ $$,
  'shadowban : proprio voit toujours ses propres trades (compte "reste actif")'
);

select * from finish();
rollback;
