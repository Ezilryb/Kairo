-- /supabase/tests/10_trade_events_created_test.sql
-- =============================================================================
-- Tests pgTAP pour la migration 023 — événements "created" et "published"
-- générés par trigger, backfill idempotent, REVOKE des droits d'écriture
-- sur trade_events, et transition_trade repassée en SECURITY DEFINER.
--
-- Conventions :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Setup users au niveau top-level (auth.users + public.users),
--     recopié du pattern de 09_trade_events_policy_test.sql
--   - Le rôle courant dans le SQL Editor Supabase est `postgres`
--     (BYPASSRLS). Pour simuler un user authentifié :
--       set local role authenticated;
--       perform set_config('request.jwt.claim.sub', '<uuid>::text', true);
--     puis reset role; à la fin du bloc.
--   - throws_ok entoure une SIMPLE instruction SQL, pas un bloc do $$
--     (lève fait avorter la transaction, et l'instruction throws_ok
--     capture l'exception d'un expression SELECT).
--   - Pour les tests qui ont besoin d'assertions sur des exceptions
--     levées dans un contexte authentifié, on capture l'exception dans
--     un do $q$ via `exception when others then`, on stocke SQLERRM
--     via set_config, et on assert au top-level avec is() / matches().
--     Le do $q$ ne lève jamais, la transaction continue, et `reset role;`
--     est appelé avant la fin du bloc (cf. test 3, test 6, test 11).
--   - is() / ok() / matches() pour asserter une valeur précise. LÈVENT
--     une exception pgTAP si la condition est fausse. matches() permet
--     une comparaison partielle (regex LIKE/glob) sans casser sur les
--     variations de message. Pour les tests négatifs, Pierre-Gaspard
--     décommentera les lignes `select is(...)` taggées `-- NEGATIF:`
--     (cf. test 1 et test 7).
--   - Délimiteurs dollar distincts ($q$, $auth$, $reset$) pour éviter
--     les collisions dans les blocs do $q$ imbriqués.
--
-- transition_trade à 3 paramètres (migration 023 = prod verbatim) :
-- signature (uuid, trade_status, numeric). Le 3e paramètre p_exit_price
-- est optionnel (DEFAULT NULL) et n'est utilisé que pour les clôtures.
--
-- IMPORTANT : transition_trade en prod cumule le PnL réalisé dans
-- realized_pnl_gross via v_final_exit_price / v_leg_pnl (cf. migration
-- 004 _realized_pnl.sql). Le test 5 inclut une assertion sur le cumul
-- réalisé pour servir de GARDE-FOU : toute redéfinition future qui
-- oublierait ce calcul ferait immédiatement échouer ce test. C'est
-- précisément ce qui s'est passé lors du round précédent (la migration
-- 023 a failli supprimer le calcul du leg final parce que le fichier
-- de référence était périmé).
--
-- Users dédiés (...0016/...0017/...0018, libres — 09 utilise ...0013/...0015).
-- Instrument : TESTUSD10 (crypto, sans exchange, pattern 09).
--
-- Plan : 25 assertions détaillées dans chaque test ci-dessous.
-- 1 (test 1) + 1 (test 2) + 1 (test 3) + 8 (test 4) + 2 (test 5)
-- + 1 (test 6) + 1 (test 7) + 4 (test 8) + 2 (test 9) + 2 (test 10)
-- + 1 (test 11) + 1 (test 12) = 25
-- =============================================================================

begin;

-- ============================================================================
-- Setup : 3 users + 1 instrument
-- ============================================================================
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD10', 'Test Asset 10', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000016'::uuid, 'test+setup16@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000016'::uuid, 'test_setup16')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000017'::uuid, 'test+setup17@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000017'::uuid, 'test_setup17')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000018'::uuid, 'test+setup18@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000018'::uuid, 'test_setup18')
on conflict (id) do nothing;

select plan(25);


-- ============================================================================
-- Test 1 : INSERT dans trades → event 'created' présent, is_backfilled=false
-- ============================================================================
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_inst_id uuid;
  v_trade_id uuid;
  v_count int;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'draft')
  returning id into v_trade_id;

  select count(*) into v_count
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'created' and is_backfilled = false;

  perform set_config('test.t1_count', v_count::text, false);
end $q$;

select is(
  current_setting('test.t1_count', true)::int,
  1,
  'INSERT trade → 1 event created (is_backfilled=false)'
);

-- NEGATIF (à décommenter par Pierre-Gaspard pour preuve que le test fail) :
-- select is(
--   current_setting('test.t1_count', true)::int,
--   99,
--   'NEGATIF test 1 : devrait fail (attendu 99, trouvé 1)'
-- );


-- ============================================================================
-- Test 2 : UPDATE direct postgres draft→live → event 'published' présent
-- ============================================================================
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_inst_id uuid;
  v_trade_id uuid;
  v_count int;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'draft')
  returning id into v_trade_id;

  update public.trades
    set status = 'live', published_at = now(), opened_at = now()
    where id = v_trade_id and user_id = v_user_id and status = 'draft';

  select count(*) into v_count
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'published' and is_backfilled = false;

  perform set_config('test.t2_count', v_count::text, false);
end $q$;

select is(
  current_setting('test.t2_count', true)::int,
  1,
  'UPDATE direct postgres draft→live → 1 event published (is_backfilled=false)'
);


-- ============================================================================
-- Test 3 : INSERT direct authenticated dans trade_events doit lever (REVOKE)
-- ============================================================================
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_inst_id uuid;
  v_trade_id uuid;
  v_err text;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'draft')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  begin
    insert into public.trade_events (trade_id, user_id, event_type)
      values (v_trade_id, v_user_id, 'created'::public.trade_event_type);
  exception when others then
    v_err := SQLERRM;
  end;

  perform set_config('test.t3_error', coalesce(v_err, 'NO_ERROR'), false);
  reset role;
end $q$;

select matches(
  current_setting('test.t3_error', true),
  '^permission denied',
  'INSERT direct authenticated dans trade_events doit lever (REVOKE — message commence par permission denied)'
);


-- ============================================================================
-- Test 4 : REVOKE a bien été appliqué — 4 droits × 2 rôles = 8 assertions
-- ============================================================================
select is(has_table_privilege('authenticated', 'public.trade_events', 'INSERT'),   false, 'INSERT revoked for authenticated');
select is(has_table_privilege('authenticated', 'public.trade_events', 'UPDATE'),   false, 'UPDATE revoked for authenticated');
select is(has_table_privilege('authenticated', 'public.trade_events', 'DELETE'),   false, 'DELETE revoked for authenticated');
select is(has_table_privilege('authenticated', 'public.trade_events', 'TRUNCATE'), false, 'TRUNCATE revoked for authenticated');
select is(has_table_privilege('anon',          'public.trade_events', 'INSERT'),   false, 'INSERT revoked for anon');
select is(has_table_privilege('anon',          'public.trade_events', 'UPDATE'),   false, 'UPDATE revoked for anon');
select is(has_table_privilege('anon',          'public.trade_events', 'DELETE'),   false, 'DELETE revoked for anon');
select is(has_table_privilege('anon',          'public.trade_events', 'TRUNCATE'), false, 'TRUNCATE revoked for anon');


-- ============================================================================
-- Test 5 : transition_trade par le propriétaire (post-DEFINER, role reset)
--          + GARDE-FOU realized_pnl_gross = (110 - 100) * 1 * (+1) = 10
-- ============================================================================
-- Le garde-fou realized_pnl_gross = 10 protège contre toute future
-- redéfinition de transition_trade qui oublierait le calcul du leg
-- final (v_final_exit_price / v_leg_pnl, cf. migration 004
-- _realized_pnl.sql). Trade long entry=100 qté=1, clôture à exit=110 :
-- (110 - 100) * 1 * 1 = 10.
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_inst_id uuid;
  v_trade_id uuid;
  v_count int;
  v_realized numeric(24,8);
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 110);

  select count(*) into v_count
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'closed';

  select realized_pnl_gross into v_realized
    from public.trades
    where id = v_trade_id;

  perform set_config('test.t5_count',     v_count::text,                  false);
  perform set_config('test.t5_realized', v_realized::text,               false);
  reset role;
end $q$;

select is(
  current_setting('test.t5_count', true)::int,
  1,
  'transition_trade par le proprio → 1 event closed (post-DEFINER + REVOKE)'
);

select is(
  current_setting('test.t5_realized', true)::numeric,
  10::numeric,
  'GARDE-FOU realized_pnl_gross = (110-100)*1*1 = 10 (leg final cumulé à la clôture)'
);


-- ============================================================================
-- Test 6 : transition_trade par un tiers doit lever
--         ("Trade introuvable ou non autorisé")
-- ============================================================================
do $q$
declare
  v_user_a uuid := '00000000-0000-0000-0000-000000000016';
  v_user_b uuid := '00000000-0000-0000-0000-000000000017';
  v_inst_id uuid;
  v_trade_id uuid;
  v_err text;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_a, v_inst_id, 'long', 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_b::text, true);

  begin
    perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 110);
  exception when others then
    v_err := SQLERRM;
  end;

  perform set_config('test.t6_error', coalesce(v_err, 'NO_ERROR'), false);
  reset role;
end $q$;

select is(
  current_setting('test.t6_error', true),
  'Trade introuvable ou non autorisé',
  'transition_trade par un tiers doit lever (message unique, sans UUID)'
);


-- ============================================================================
-- Test 7 : re-run backfill = 0 nouveau doublon (idempotence réelle)
-- ============================================================================
do $q$
declare
  v_count_before int;
  v_count_after int;
begin
  select count(*) into v_count_before
    from public.trade_events
    where event_type = 'created';

  insert into public.trade_events
    (trade_id, user_id, event_type, is_backfilled, metadata, created_at)
  select t.id, t.user_id, 'created'::public.trade_event_type, true,
    jsonb_build_object('source', 'migration_023', 'original_timestamp', t.created_at),
    t.created_at
  from public.trades t
  where not exists (
    select 1 from public.trade_events e
    where e.trade_id = t.id and e.event_type = 'created'
  );

  select count(*) into v_count_after
    from public.trade_events
    where event_type = 'created';

  perform set_config('test.t7_before', v_count_before::text, false);
  perform set_config('test.t7_after',  v_count_after::text,  false);
end $q$;

select is(
  current_setting('test.t7_after', true)::int,
  current_setting('test.t7_before', true)::int,
  're-run backfill created = 0 nouveau doublon (compte après = compte avant)'
);

-- NEGATIF (à décommenter par Pierre-Gaspard) :
-- select is(
--   current_setting('test.t7_after', true)::int,
--   current_setting('test.t7_before', true)::int + 1,
--   'NEGATIF test 7 : devrait fail (après != avant + 1)'
-- );


-- ============================================================================
-- Test 8 : Trade sans events natifs → backfill pose les events avec
--          is_backfilled=true, metadata conforme, timestamp = trades.created_at
-- ============================================================================
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000018';
  v_inst_id uuid;
  v_trade_id uuid;
  v_backfilled_created int;
  v_metadata_ok int;
  v_backfilled_published int;
  v_ts_match text;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
  values
    (v_user_id, v_inst_id, 'short', 50, 1, 50, 'live', now(), now())
  returning id into v_trade_id;

  perform set_config('app.allow_trade_events_mutation', 'true', true);
  delete from public.trade_events where trade_id = v_trade_id;
  perform set_config('app.allow_trade_events_mutation', 'false', true);

  insert into public.trade_events
    (trade_id, user_id, event_type, is_backfilled, metadata, created_at)
  select t.id, t.user_id, 'created'::public.trade_event_type, true,
    jsonb_build_object('source', 'migration_023', 'original_timestamp', t.created_at),
    t.created_at
  from public.trades t
  where not exists (
    select 1 from public.trade_events e
    where e.trade_id = t.id and e.event_type = 'created'
  );

  insert into public.trade_events
    (trade_id, user_id, event_type, is_backfilled, metadata, created_at)
  select t.id, t.user_id, 'published'::public.trade_event_type, true,
    jsonb_build_object('source', 'migration_023', 'original_timestamp', t.published_at),
    t.published_at
  from public.trades t
  where t.published_at is not null
    and not exists (
      select 1 from public.trade_events e
      where e.trade_id = t.id and e.event_type = 'published'
    );

  select count(*) into v_backfilled_created
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'created' and is_backfilled = true;

  select count(*) into v_metadata_ok
    from public.trade_events
    where trade_id = v_trade_id
      and event_type = 'created'
      and is_backfilled = true
      and metadata ? 'source'
      and metadata ? 'original_timestamp'
      and metadata->>'source' = 'migration_023';

  select count(*) into v_backfilled_published
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'published' and is_backfilled = true;

  select case
    when exists (
      select 1 from public.trade_events where trade_id = v_trade_id
        and event_type = 'created'
        and is_backfilled = true
        and created_at = (select created_at from public.trades where id = v_trade_id)
    ) then 'true' else 'false'
  end into v_ts_match;

  perform set_config('test.t8_backfilled_created',   v_backfilled_created::text,    false);
  perform set_config('test.t8_metadata_ok',         v_metadata_ok::text,          false);
  perform set_config('test.t8_backfilled_published', v_backfilled_published::text,  false);
  perform set_config('test.t8_ts_match',            v_ts_match,                    false);
end $q$;

select is(current_setting('test.t8_backfilled_created',   true)::int, 1,     'backfill pose 1 event created (is_backfilled=true)');
select is(current_setting('test.t8_metadata_ok',         true)::int, 1,     'metadata conforme (source=migration_023 + original_timestamp)');
select is(current_setting('test.t8_backfilled_published', true)::int, 1,     'backfill pose 1 event published (is_backfilled=true)');
select is(current_setting('test.t8_ts_match',            true),       'true','timestamp du backfill = trades.created_at');


-- ============================================================================
-- Test 9 : INSERT direct en live → event 'published' + metadata.direct_insert_live
-- ============================================================================
do $q$
declare
  v_user_c uuid := '00000000-0000-0000-0000-000000000018';
  v_inst_id uuid;
  v_trade_id uuid;
  v_count_created int;
  v_count_published_direct int;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_c, v_inst_id, 'short', 50, 1, 50, 'live')
  returning id into v_trade_id;

  select count(*) into v_count_created
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'created';

  select count(*) into v_count_published_direct
    from public.trade_events
    where trade_id = v_trade_id
      and event_type = 'published'
      and (metadata->>'direct_insert_live')::boolean = true;

  perform set_config('test.t9_count_created',           v_count_created::text,           false);
  perform set_config('test.t9_count_published_direct', v_count_published_direct::text, false);
end $q$;

select is(current_setting('test.t9_count_created',           true)::int, 1, 'INSERT direct en live → 1 event created');
select is(current_setting('test.t9_count_published_direct', true)::int, 1, 'INSERT direct en live → 1 event published avec metadata.direct_insert_live=true');


-- ============================================================================
-- Test 10 : Chemin réel de publication via RPC publish_trade en authenticated
-- ============================================================================
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_inst_id uuid;
  v_trade_id uuid;
  v_count_published int;
  v_count_published_not_backfilled int;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'draft')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.publish_trade(v_trade_id);

  select count(*) into v_count_published
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'published';

  select count(*) into v_count_published_not_backfilled
    from public.trade_events
    where trade_id = v_trade_id
      and event_type = 'published'
      and is_backfilled = false;

  perform set_config('test.t10_count_published', v_count_published::text, false);
  perform set_config('test.t10_count_published_not_backfilled', v_count_published_not_backfilled::text, false);
  reset role;
end $q$;

select is(
  current_setting('test.t10_count_published', true)::int,
  1,
  'publish_trade par le proprio en authenticated → exactement 1 event published (pas de doublon)'
);

select is(
  current_setting('test.t10_count_published_not_backfilled', true)::int,
  1,
  'event published posé en temps réel par trigger (is_backfilled=false), pas par backfill'
);


-- ============================================================================
-- Test 11 : Suppression d'un brouillon par son proprio doit lever
--           (régression post-023 — description du comportement réel)
-- ============================================================================
-- Cf. TODO_TECHNIQUE.md : "supprimer un brouillon échoue tant que 10.0
-- n'est pas fait". L'UI n'expose pas de bouton supprimer brouillon
-- (grep `delete.*trade` dans app/ → 0 match), donc aucun fix urgent.
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_inst_id uuid;
  v_trade_id uuid;
  v_err text;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD10');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'draft')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  begin
    delete from public.trades where id = v_trade_id;
  exception when others then
    v_err := SQLERRM;
  end;

  perform set_config('test.t11_error', coalesce(v_err, 'NO_ERROR'), false);
  reset role;
end $q$;

select matches(
  current_setting('test.t11_error', true),
  '^trade_events est immuable',
  'DELETE brouillon en authenticated lève (régression post-023, à corriger en round 10.0)'
);


-- ============================================================================
-- Test 12 : Surcharge analytics_crosstab — appel à 7 paramètres
-- ============================================================================
-- Constat recensement : deux surcharges analytics_crosstab coexistent
-- en prod (7 et 9 paramètres). L'appel à 7 args doit fonctionner sans
-- ambiguïté. Si Postgres répond "is not unique" → c'est un bug.
--
-- NOTE importante : la signature 7 args exige des casts explicites
-- sur chaque paramètre NULL (les types sont stricts). Sans casts,
-- Postgres lèverait "function does not exist" même avec la 7-args
-- présente, ce qui ferait passer le test à vide (le check "is not
-- unique" ne se déclencherait jamais).
--
-- Signature 7 args (donnée par le cadrage) :
--   analytics_crosstab(uuid, null::uuid, null::trade_direction,
--                      null::text, null::text, null::trade_timeframe,
--                      null::timestamptz)
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000016';
  v_err text;
  v_has_ambiguity boolean := false;
begin
  begin
    perform public.analytics_crosstab(
      v_user_id,
      null::uuid,
      null::public.trade_direction,
      null::text,
      null::text,
      null::public.trade_timeframe,
      null::timestamptz
    );
  exception when others then
    v_err := SQLERRM;
  end;

  v_has_ambiguity := (coalesce(v_err, '') ~ 'is not unique');

  perform set_config('test.t12_has_ambiguity', v_has_ambiguity::text, false);
  perform set_config('test.t12_error',         coalesce(v_err, 'NO_ERROR_7ARGS_OK'), false);
end $q$;

select is(
  current_setting('test.t12_has_ambiguity', true)::boolean,
  false,
  'analytics_crosstab(7 args, casts explicites) ne lève pas "is not unique" (sentinelle non-régression)'
);


select * from finish();
rollback;