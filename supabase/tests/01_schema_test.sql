-- /supabase/tests/01_schema_test.sql
-- =============================================================================
-- Tests pgTAP pour le schéma Kairo (Phase 0 — initial schema).
-- Exécution : supabase test db (CLI) ou psql -f sur la base.
-- Convention : begin/rollback autour du test, plan() en tête, finish() en fin.
-- Chaque test est indépendant, données de test créées en setup puis annulées
-- par le rollback final. Aucune mutation persistante.
--
-- Règle d'or (corrigée après audit) : ne JAMAIS comparer deux appels à
-- now() au sein du même test. now() est transaction_timestamp() et reste
-- constant pendant toute la transaction. Pour tester une fenêtre de
-- temps (ex. 60s pour entry_price), on INSERT directement avec un
-- published_at backdaté par now() - interval 'N seconds', puis on UPDATE
-- sans filtre temporel dans le WHERE — c'est la valeur absolue de
-- published_at dans la ligne qui fait foi pour le trigger.
-- =============================================================================

begin;

-- ============================================================================
-- 0. SETUP : fixtures minimales (un instrument, un user)
-- ============================================================================

insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD', 'Test Asset', 'crypto');

-- auth.users n'est pas insérable directement depuis un test SQL standard ;
-- on insère directement dans public.users (le profil applicatif) en lui
-- donnant un UUID cohérent.
insert into auth.users (id, email)
values ('00000000-0000-0000-0000-000000000001'::uuid, 'test+setup@kairo.local')
on conflict (id) do nothing;

insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-000000000001'::uuid, 'test_setup')
on conflict (id) do nothing;

-- Total assertions : section 1 (6) + section 2 (2) + section 3 (9) + section 4 (4) = 21
select plan(21);

-- ============================================================================
-- 1. CONTRAINTES DE BASE
-- ============================================================================

-- 1.1 users.pseudo : char_length entre 3 et 30 (trop court)
select throws_ok(
  $$ insert into public.users (id, pseudo) values (gen_random_uuid(), 'ab') $$,
  'new row for relation "users" violates check constraint "users_pseudo_check"',
  'users.pseudo : 2 caractères doit échouer'
);

-- 1.2 users.pseudo : char_length entre 3 et 30 (trop long)
select throws_ok(
  $$ insert into public.users (id, pseudo) values (gen_random_uuid(), repeat('a', 31)) $$,
  'new row for relation "users" violates check constraint "users_pseudo_check"',
  'users.pseudo : 31 caractères doit échouer'
);

-- 1.3 trades.entry_price > 0
select throws_ok(
  $$ insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital)
     values (
       '00000000-0000-0000-0000-000000000001'::uuid,
       (select id from public.instruments where symbol = 'TESTUSD'),
       'long', 0, 1, 100
     ) $$,
  'new row for relation "trades" violates check constraint "trades_entry_price_check"',
  'trades.entry_price = 0 doit échouer'
);

-- 1.4 trades.quantity > 0
select throws_ok(
  $$ insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital)
     values (
       '00000000-0000-0000-0000-000000000001'::uuid,
       (select id from public.instruments where symbol = 'TESTUSD'),
       'long', 100, 0, 100
     ) $$,
  'new row for relation "trades" violates check constraint "trades_quantity_check"',
  'trades.quantity = 0 doit échouer'
);

-- 1.5 reports : au moins un target (trade_id, comment_id ou reported_user_id)
select throws_ok(
  $$ insert into public.reports (reporter_id, reason)
     values ('00000000-0000-0000-0000-000000000001'::uuid, 'spam') $$,
  'new row for relation "reports" violates check constraint',
  'reports sans aucun target doit échouer'
);

-- 1.6 instruments : unicité (symbol, exchange)
select throws_ok(
  $$ insert into public.instruments (symbol, name, asset_class, exchange)
     values ('TESTUSD', 'Duplicate', 'crypto', null) $$,
  'duplicate key value violates unique constraint "instruments_symbol_exchange_key"',
  'instruments : (symbol, exchange) dupliqué doit échouer'
);

-- ============================================================================
-- 2. INDEX PARTIELS
-- ============================================================================

-- 2.1 trades_last_activity_idx est un index partiel filtré sur status = 'live'
select ok(
  exists(
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'trades'
      and indexname = 'trades_last_activity_idx'
      and indexdef like '%WHERE%status = ''live''%'
  ),
  'trades_last_activity_idx existe et est filtré sur status = ''live'''
);

-- 2.2 notifications_user_unread_idx est partiel sur read_at IS NULL
select ok(
  exists(
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'notifications'
      and indexname = 'notifications_user_unread_idx'
      and indexdef like '%WHERE%read_at IS NULL%'
  ),
  'notifications_user_unread_idx est partiel sur read_at IS NULL'
);

-- ============================================================================
-- 3. TRIGGERS MÉTIER
-- ============================================================================

-- 3.1a enforce_entry_price_immutability : trade DRAFT — INSERT passe
select lives_ok(
  $$ insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status)
     values (
       '00000000-0000-0000-0000-000000000001'::uuid,
       (select id from public.instruments where symbol = 'TESTUSD'),
       'long', 100, 1, 100, 'draft'
     ) $$,
  'insert trade en draft passe'
);

-- 3.1b enforce_entry_price_immutability : trade DRAFT — modif entry_price passe
select lives_ok(
  $$ update public.trades
       set entry_price = 110
     where user_id = '00000000-0000-0000-0000-000000000001'::uuid
       and status = 'draft' $$,
  'modif entry_price sur trade draft passe (toujours autorisé)'
);

-- 3.2 enforce_entry_price_immutability : trade LIVE, fenêtre 60s (DANS la fenêtre)
-- On INSERT un trade "live" avec published_at = now() - 59s (donc dans la
-- fenêtre de 60s). Le trigger évalue : now() > published_at + 60s
-- = T > (T-59s) + 60s = T > T+1s = false → la modif doit passer.
do $$
declare
  v_trade_id uuid;
begin
  insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
  values (
    '00000000-0000-0000-0000-000000000001'::uuid,
    (select id from public.instruments where symbol = 'TESTUSD'),
    'long', 100, 1, 100, 'live',
    now() - interval '59 seconds', now() - interval '59 seconds'
  )
  returning id into v_trade_id;

  update public.trades set entry_price = 105 where id = v_trade_id;
end $$;

select lives_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
       values (
         '00000000-0000-0000-0000-000000000001'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD'),
         'long', 100, 1, 100, 'live',
         now() - interval '59 seconds', now() - interval '59 seconds'
       )
       returning id into v_trade_id;
       update public.trades set entry_price = 105 where id = v_trade_id;
     end $$ $$,
  'modif entry_price 59s après publication passe (fenêtre incluse)'
);

-- 3.3 enforce_entry_price_immutability : trade LIVE, 61s après publication (HORS fenêtre)
-- On INSERT avec published_at = now() - 61s. Le trigger évalue :
-- T > (T-61s) + 60s = T > T-1s = true → doit bloquer.
select throws_ok(
  $$ do $$
     declare v_trade_id uuid;
     begin
       insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, published_at, opened_at)
       values (
         '00000000-0000-0000-0000-000000000001'::uuid,
         (select id from public.instruments where symbol = 'TESTUSD'),
         'long', 100, 1, 100, 'live',
         now() - interval '61 seconds', now() - interval '61 seconds'
       )
       returning id into v_trade_id;
       update public.trades set entry_price = 200 where id = v_trade_id;
     end $$ $$,
  'entry_price est immuable après publication%',
  'modif entry_price 61s après publication doit lever notre exception'
);

-- 3.4 log_sl_tp_changes : modif SL sur trade LIVE crée un trade_event
do $$
declare
  v_trade_id uuid;
  v_event_count int;
begin
  insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, stop_loss, published_at, opened_at)
  values (
    '00000000-0000-0000-0000-000000000001'::uuid,
    (select id from public.instruments where symbol = 'TESTUSD'),
    'long', 100, 1, 100, 'live', 95,
    now() - interval '10 seconds', now() - interval '10 seconds'
  )
  returning id into v_trade_id;

  update public.trades set stop_loss = 92 where id = v_trade_id;

  select count(*) into v_event_count
  from public.trade_events
  where trade_id = v_trade_id and event_type = 'sl_modified';

  if v_event_count <> 1 then
    raise exception 'attendu 1 trade_event sl_modified, trouvé %', v_event_count;
  end if;
end $$;

select ok(true, 'modif SL sur trade live crée exactement 1 trade_event sl_modified');

-- 3.5 log_sl_tp_changes : modif SL sur trade DRAFT ne crée PAS de trade_event
do $$
declare
  v_trade_id uuid;
  v_event_count int;
begin
  insert into public.trades (user_id, instrument_id, direction, entry_price, quantity, capital, status, stop_loss)
  values (
    '00000000-0000-0000-0000-000000000001'::uuid,
    (select id from public.instruments where symbol = 'TESTUSD'),
    'long', 100, 1, 100, 'draft', 95
  )
  returning id into v_trade_id;

  update public.trades set stop_loss = 92 where id = v_trade_id;

  select count(*) into v_event_count
  from public.trade_events
  where trade_id = v_trade_id;

  if v_event_count <> 0 then
    raise exception 'attendu 0 trade_event sur draft, trouvé %', v_event_count;
  end if;
end $$;

select ok(true, 'modif SL sur trade draft ne crée AUCUN trade_event');

-- 3.6 forbid_trade_events_mutation : on insère un trade_event pour avoir
-- une ligne à attaquer par les tests 3.7 et 3.8. Pas d'assertion ici.
do $$
declare
  v_trade_id uuid;
  v_event_id uuid;
begin
  select id into v_trade_id
  from public.trades
  where user_id = '00000000-0000-0000-0000-000000000001'::uuid
  limit 1;

  insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
  values (v_trade_id, '00000000-0000-0000-0000-000000000001'::uuid, 'created',
          '{"a": 1}'::jsonb, '{"a": 2}'::jsonb)
  returning id into v_event_id;
end $$;

-- 3.7 forbid_trade_events_mutation : UPDATE direct doit lever
select throws_ok(
  $$ update public.trade_events
       set old_values = '{"a": 99}'::jsonb
     where user_id = '00000000-0000-0000-0000-000000000001'::uuid $$,
  'trade_events est immuable%',
  'UPDATE direct sur trade_events doit lever notre exception'
);

-- 3.8 forbid_trade_events_mutation : DELETE direct doit lever
select throws_ok(
  $$ delete from public.trade_events
     where user_id = '00000000-0000-0000-0000-000000000001'::uuid $$,
  'trade_events est immuable%',
  'DELETE direct sur trade_events doit lever notre exception'
);

-- 3.9 prepare_user_deletion_cascade : suppression d'un user (sans trades)
-- doit poser le flag + écrire l'audit log
do $$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_audit_count int;
begin
  -- Nettoie les dépendances pour isoler le test
  delete from public.trade_events where user_id = v_user_id;
  delete from public.trades where user_id = v_user_id;
  delete from public.users where id = v_user_id;
  delete from auth.users where id = v_user_id;

  -- L'audit log doit avoir au moins une entrée gdpr_deleted
  select count(*) into v_audit_count
  from public.audit_logs
  where action = 'user.gdpr_deleted';

  if v_audit_count < 1 then
    raise exception 'attendu ≥ 1 audit_log user.gdpr_deleted, trouvé %', v_audit_count;
  end if;
end $$;

select ok(true, 'auth.users DELETE déclenche prepare_user_deletion_cascade et écrit l''audit_log');

-- ============================================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================================

-- 4.1 RLS activé sur les tables métier principales
select ok(
  (select relrowsecurity from pg_class where relname = 'users' and relnamespace = 'public'::regnamespace),
  'RLS activé sur public.users'
);

select ok(
  (select relrowsecurity from pg_class where relname = 'trades' and relnamespace = 'public'::regnamespace),
  'RLS activé sur public.trades'
);

select ok(
  (select relrowsecurity from pg_class where relname = 'trade_events' and relnamespace = 'public'::regnamespace),
  'RLS activé sur public.trade_events'
);

-- 4.2 policy trades:lecture utilise is_public + auth.uid() = user_id
select ok(
  exists(
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'trades'
      and policyname = 'trades: lecture (publics ou propriétaire)'
      and qual = '(is_public OR (auth.uid() = user_id))'
  ),
  'policy trades:lecture utilise (is_public OR auth.uid() = user_id)'
);

-- ============================================================================
-- FIN
-- ============================================================================

select * from finish();
rollback;
