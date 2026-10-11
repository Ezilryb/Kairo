-- /supabase/tests/13_trade_metrics_test.sql
-- =============================================================================
-- Tests pgTAP pour la migration 026 — clôture avec prix obligatoire + RPC
-- public.trade_metrics(p_trade_id uuid) (lecture filtrée par user_id).
--
-- Cadrage E (chantier E) :
--   * transition_trade refuse désormais p_exit_price NULL ou <= 0
--     quand p_new_status = 'closed'.
--   * pnl_gross reconnaît un trade archivé en plus du clôturé (status in
--     ('closed', 'archived')), au lieu de status = 'closed' seul.
--   * trade_metrics expose, pour un trade de l'utilisateur courant, le
--     statut, l'exit_price, les PnL calculés via les fonctions existantes
--     (pnl_gross / pnl_net / rendement_pct / r_multiple), le risque
--     initial (|entry - stop_loss| * initial_quantity / initial_capital *
--     100, NULL si pas de stop_loss ou capital nul) et les flags
--     fees_known / slippage_known. SECURITY INVOKER, filtre
--     t.user_id = auth.uid().
--
-- Conventions :
--   - begin/rollback, plan() en tête, finish() en fin
--   - Setup users au niveau top-level (auth.users + public.users),
--     pattern recopié de 09_trade_events_policy_test.sql / 10 / 11
--   - Pour simuler un user authentifié :
--       set local role authenticated;
--       perform set_config('request.jwt.claim.sub', '<uuid>::text', true);
--       ... actions ...
--       reset role;
--   - throws_like entoure une instruction SQL simple (pgTAP capture
--     l'exception d'une expression SELECT). throws_like compare en
--     LIKE/glob (préfixe avec %), contrairement à throws_ok (égalité
--     stricte). Cf. TODO_TECHNIQUE §Phase 10.
--   - is() / ok() / matches() pour asserter une valeur précise.
--   - set_config(..., false) : scope transaction, lecture courante.
--   - coalesce(v_num::text, 'NULL') pour transmettre NULL via texte.
--   - Délimiteurs dollar distincts ($q$, $auth$) pour éviter les
--     collisions dans les blocs do imbriqués.
--
-- Users dédiés (...001d/...001e/...001f, libres — 12 utilise ...001c,
-- 11 utilise ...0019/...001a/...001b).
-- Instrument : TESTUSD13 (crypto, sans exchange, pattern 09-12).
--
-- Plan : 25 assertions détaillées dans chaque test ci-dessous.
-- 4 (test 1 : long gagnant) + 2 (test 2 : short gagnant)
-- + 2 (test 3 : trade perdant)
-- + 1 (test 4 : clôture sans prix) + 1 (test 5 : prix 0) + 1 (test 6 : prix -10)
-- + 1 (test 7 : cumul 40 + -60 = -20) + 1 (test 8 : risque 8,92)
-- + 1 (test 9 : risque NULL sans stop_loss)
-- + 4 (test 10 : trade en cours — status, exit_price, risk_pct, pnl_gross)
-- + 1 (test 11 : tiers → 0 ligne)
-- + 1 (test 12 : clôturé+archivé garde résultat)
-- + 1 (test 13 : event closed contient exit_price)
-- + 1 (test 14 : trade_metrics EXECUTE refusé à PUBLIC)
-- + 1 (test 15 : trade_metrics EXECUTE refusé à anon)
-- + 1 (test 16 : trade_metrics EXECUTE accordé à authenticated)
-- + 1 (test 17 : pnl_gross EXECUTE conservé pour authenticated)
-- = 25
-- =============================================================================

begin;

-- ============================================================================
-- Setup : 3 users + 1 instrument
-- ============================================================================
insert into public.instruments (symbol, name, asset_class)
values ('TESTUSD13', 'Test Asset 13', 'crypto')
on conflict (symbol, exchange) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000001d'::uuid, 'test+setup1d@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000001d'::uuid, 'test_setup1d')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000001e'::uuid, 'test+setup1e@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000001e'::uuid, 'test_setup1e')
on conflict (id) do nothing;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000001f'::uuid, 'test+setup1f@kairo.local')
on conflict (id) do nothing;
insert into public.users (id, pseudo)
values ('00000000-0000-0000-0000-00000000001f'::uuid, 'test_setup1f')
on conflict (id) do nothing;

select plan(25);


-- ============================================================================
-- Test 1 : long gagnant — 4 assertions (pnl_gross=10, pnl_net=10,
--          r_multiple=2, risk_pct=5)
-- ============================================================================
-- entry=100, stop_loss=95, initial_quantity=1, initial_capital=100,
-- exit=110 (long) :
--   realized_pnl_gross = (110-100)*1 = 10
--   pnl_net = 10 (fees/slippage NULL → coalesce 0)
--   risk_pct = |100-95|*1/100*100 = 5
--   risk (montant) = |100-95|*1 = 5
--   r_multiple = 10 / 5 = 2
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001d';
  v_inst_id uuid;
  v_trade_id uuid;
  v_pnl_gross numeric;
  v_pnl_net numeric;
  v_r_multiple numeric;
  v_risk_pct numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, stop_loss,
     quantity, capital, initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 95,
     1, 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 110);

  select pnl_gross, pnl_net, r_multiple, risk_pct
    into v_pnl_gross, v_pnl_net, v_r_multiple, v_risk_pct
    from public.trade_metrics(v_trade_id);

  perform set_config('test.t1_pnl_gross',  v_pnl_gross::text,                         false);
  perform set_config('test.t1_pnl_net',    v_pnl_net::text,                           false);
  perform set_config('test.t1_r_multiple', v_r_multiple::text,                        false);
  perform set_config('test.t1_risk_pct',   coalesce(v_risk_pct::text, 'NULL'),        false);
  reset role;
end $q$;

select is(current_setting('test.t1_pnl_gross', true)::numeric,  10::numeric, 'long gagnant : pnl_gross = 10');
select is(current_setting('test.t1_pnl_net', true)::numeric,    10::numeric, 'long gagnant : pnl_net = 10 (fees/slippage NULL → coalesce 0)');
select is(current_setting('test.t1_r_multiple', true)::numeric, 2::numeric,  'long gagnant : r_multiple = pnl_net / risque = 10 / 5 = 2');
select is(current_setting('test.t1_risk_pct', true)::numeric,   5::numeric,  'long gagnant : risk_pct = |100-95|*1/100*100 = 5');


-- ============================================================================
-- Test 2 : short gagnant — 2 assertions (pnl_gross=10, r_multiple=2)
-- ============================================================================
-- entry=100, stop_loss=105 (short stop au-dessus), initial_quantity=1,
-- initial_capital=100, exit=90 (short gagne : prix baisse) :
--   realized_pnl_gross = (90-100)*1*(-1) = 10
--   risk_pct = |100-105|*1/100*100 = 5
--   r_multiple = 10 / 5 = 2
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001d';
  v_inst_id uuid;
  v_trade_id uuid;
  v_pnl_gross numeric;
  v_r_multiple numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, stop_loss,
     quantity, capital, initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'short', 100, 105,
     1, 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 90);

  select pnl_gross, r_multiple
    into v_pnl_gross, v_r_multiple
    from public.trade_metrics(v_trade_id);

  perform set_config('test.t2_pnl_gross',  v_pnl_gross::text,  false);
  perform set_config('test.t2_r_multiple', v_r_multiple::text, false);
  reset role;
end $q$;

select is(current_setting('test.t2_pnl_gross', true)::numeric,  10::numeric, 'short gagnant : pnl_gross = (90-100)*1*(-1) = 10');
select is(current_setting('test.t2_r_multiple', true)::numeric, 2::numeric,  'short gagnant : r_multiple = 10 / 5 = 2');


-- ============================================================================
-- Test 3 : trade perdant — 2 assertions (pnl_gross=-10, r_multiple=-2)
-- ============================================================================
-- entry=100, stop_loss=95, initial_quantity=1, initial_capital=100,
-- exit=90 (long perd) :
--   realized_pnl_gross = (90-100)*1 = -10
--   r_multiple = -10 / 5 = -2
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001d';
  v_inst_id uuid;
  v_trade_id uuid;
  v_pnl_gross numeric;
  v_r_multiple numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, stop_loss,
     quantity, capital, initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 95,
     1, 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 90);

  select pnl_gross, r_multiple
    into v_pnl_gross, v_r_multiple
    from public.trade_metrics(v_trade_id);

  perform set_config('test.t3_pnl_gross',  v_pnl_gross::text,  false);
  perform set_config('test.t3_r_multiple', v_r_multiple::text, false);
  reset role;
end $q$;

select is(current_setting('test.t3_pnl_gross', true)::numeric,  -10::numeric, 'trade perdant : pnl_gross = -10');
select is(current_setting('test.t3_r_multiple', true)::numeric, -2::numeric,  'trade perdant : r_multiple = -10 / 5 = -2');


-- ============================================================================
-- Tests 4, 5, 6 : transition_trade(closed) refuse p_exit_price omis,
--                  nul, ou négatif — un seul bloc authentifié
-- ============================================================================
-- Tous les trades d'un test ont le même created_at (now() de la
-- transaction), donc `order by created_at desc limit 1` n'est pas
-- déterministe entre les 3 sous-blocs : on capture l'identifiant
-- directement dans une variable, et on utilise la même session
-- authentifiée pour les 3 appels. Les sous-blocs begin/exception
-- when others then capturent SQLERRM sans avorter la transaction,
-- reset role ferme le scope authentifié.
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001d';
  v_inst_id uuid;
  v_trade_id uuid;
  v_err_omit text;
  v_err_zero text;
  v_err_neg text;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  -- Sous-bloc 1 : p_exit_price omis → exception « transition_trade refusé »
  begin
    perform public.transition_trade(
      v_trade_id, 'closed'::public.trade_status
    );
  exception when others then
    v_err_omit := SQLERRM;
  end;

  -- Sous-bloc 2 : p_exit_price = 0 → exception
  begin
    perform public.transition_trade(
      v_trade_id, 'closed'::public.trade_status, 0
    );
  exception when others then
    v_err_zero := SQLERRM;
  end;

  -- Sous-bloc 3 : p_exit_price = -10 → exception
  begin
    perform public.transition_trade(
      v_trade_id, 'closed'::public.trade_status, -10
    );
  exception when others then
    v_err_neg := SQLERRM;
  end;

  perform set_config('test.t4_err', coalesce(v_err_omit, 'NO_ERROR'), false);
  perform set_config('test.t5_err', coalesce(v_err_zero, 'NO_ERROR'), false);
  perform set_config('test.t6_err', coalesce(v_err_neg,  'NO_ERROR'), false);
  reset role;
end $q$;

-- 3 assertions matches au niveau top-level : matches() compare en
-- regex (préfixe ancré ^), tolérant une éventuelle variation de
-- message mais garantissant que l'erreur commence bien par le motif
-- attendu.
select matches(
  current_setting('test.t4_err', true),
  '^transition_trade refusé : un prix de sortie strictement positif est obligatoire',
  'clôture sans p_exit_price → exception (message 026 attendu, sous-bloc 1)'
);

select matches(
  current_setting('test.t5_err', true),
  '^transition_trade refusé : un prix de sortie strictement positif est obligatoire',
  'clôture avec p_exit_price = 0 → exception (026 refuse <= 0, sous-bloc 2)'
);

select matches(
  current_setting('test.t6_err', true),
  '^transition_trade refusé : un prix de sortie strictement positif est obligatoire',
  'clôture avec p_exit_price < 0 → exception (026 refuse <= 0, sous-bloc 3)'
);


-- ============================================================================
-- Test 7 : cumul du PnL toujours juste (40 - 60 = -20)
-- ============================================================================
-- Trade avec realized_pnl_gross=40 et exit_price=140 simulant un leg
-- partiel antérieur (UPDATE direct postgres BYPASSRLS), puis clôture
-- via transition_trade(closed, 40) :
--   leg final = (40-100)*1 = -60
--   realized_pnl_gross final = 40 + (-60) = -20
-- On vérifie que realized_pnl_gross est AJOUTÉ et non écrasé (cumul,
-- pas remplacement). C'est le garde-fou central contre toute
-- redéfinition future de transition_trade qui oublierait le calcul
-- du leg final (cf. migration 004 _realized_pnl.sql).
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001e';
  v_inst_id uuid;
  v_trade_id uuid;
  v_pnl_gross numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, stop_loss,
     quantity, capital, initial_quantity, initial_capital,
     realized_pnl_gross, exit_price, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 95,
     1, 100, 1, 100,
     40, 140, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 40);

  select pnl_gross into v_pnl_gross
    from public.trade_metrics(v_trade_id);

  perform set_config('test.t7_pnl_gross', v_pnl_gross::text, false);
  reset role;
end $q$;

select is(current_setting('test.t7_pnl_gross', true)::numeric, -20::numeric,
  'cumul PnL toujours juste : leg partiel 40 + leg final -60 = -20 (realized_pnl_gross cumulé, non écrasé)'
);


-- ============================================================================
-- Test 8 : risque avec stop loss (entry=625,32, stop=615, qty=1,4,
--          capital=162 → 8,92%)
-- ============================================================================
-- risk_pct = |625.32 - 615| * 1.4 / 162 * 100 = 10.32 * 1.4 / 162 * 100
--          = 14.448 / 162 * 100
--          = 0.089185185... * 100
--          = 8.9185185...
-- arrondi à 2 décimales = 8.92
-- Trade en cours (status='live') pour démontrer que risk_pct est
-- exposé même avant clôture (cadrage E2 : risque affiché dès qu'un
-- stop_loss est posé).
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001e';
  v_inst_id uuid;
  v_trade_id uuid;
  v_risk_pct numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, stop_loss,
     quantity, capital, initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 625.32, 615,
     1.4, 162, 1.4, 162, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  select risk_pct into v_risk_pct
    from public.trade_metrics(v_trade_id);

  -- round(risk_pct, 2) à la lecture ET à la comparaison : la valeur
  -- réelle est 8.9185..., l'arrondi à 2 décimales donne 8.92.
  perform set_config('test.t8_risk_pct', round(v_risk_pct, 2)::text, false);
  reset role;
end $q$;

select is(current_setting('test.t8_risk_pct', true)::numeric, 8.92::numeric,
  'risque avec stop_loss : round(|625.32 - 615| * 1.4 / 162 * 100, 2) = 8.92'
);


-- ============================================================================
-- Test 9 : risque absent sans stop loss (NULL)
-- ============================================================================
-- Trade en cours sans stop_loss : risk_pct doit être NULL (la branche
-- `when t.stop_loss is null then null` de trade_metrics).
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001e';
  v_inst_id uuid;
  v_trade_id uuid;
  v_risk_pct numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price,
     quantity, capital, initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100,
     1, 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  select risk_pct into v_risk_pct
    from public.trade_metrics(v_trade_id);

  -- coalesce(...::text, 'NULL') : set_config prend du texte, NULL doit
  -- être encodé. Cast explicite numeric → text avant coalesce, sinon
  -- PG lève une erreur de type (numeric + text 'NULL').
  perform set_config('test.t9_risk_pct', coalesce(v_risk_pct::text, 'NULL'), false);
  reset role;
end $q$;

select is(current_setting('test.t9_risk_pct', true), 'NULL',
  'risque absent sans stop_loss : risk_pct = NULL'
);


-- ============================================================================
-- Test 10 : risque d'un trade en cours — 4 assertions
--          (status, exit_price, risk_pct, pnl_gross)
-- ============================================================================
-- Trade live avec stop_loss posé mais pas de sortie :
--   status       = 'live'
--   exit_price   = NULL
--   risk_pct     = 5 (calculé à la lecture, |100-95|*1/100*100)
--   pnl_gross    = NULL (status != closed/archived → pnl_gross NULL)
-- trade_metrics expose risk_pct dès qu'un stop_loss est posé, sans
-- attendre la clôture (cadrage E2 : risque dans "Détails du trade"
-- pour tout trade ayant un stop loss, y compris en cours).
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001f';
  v_inst_id uuid;
  v_trade_id uuid;
  v_status public.trade_status;
  v_exit_price numeric;
  v_risk_pct numeric;
  v_pnl_gross numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, stop_loss,
     quantity, capital, initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 95,
     1, 100, 1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  select status, exit_price, risk_pct, pnl_gross
    into v_status, v_exit_price, v_risk_pct, v_pnl_gross
    from public.trade_metrics(v_trade_id);

  perform set_config('test.t10_status',       v_status::text,                         false);
  perform set_config('test.t10_exit_price',   coalesce(v_exit_price::text, 'NULL'),   false);
  perform set_config('test.t10_risk_pct',     coalesce(v_risk_pct::text, 'NULL'),     false);
  perform set_config('test.t10_pnl_gross',    coalesce(v_pnl_gross::text, 'NULL'),    false);
  reset role;
end $q$;

select is(current_setting('test.t10_status', true),
  'live',
  'trade en cours : status = live'
);
select is(current_setting('test.t10_exit_price', true),
  'NULL',
  'trade en cours : exit_price = NULL (pas encore clôturé)'
);
select is(current_setting('test.t10_risk_pct', true)::numeric,
  5::numeric,
  'trade en cours avec stop_loss : risk_pct = 5 (calculé à la lecture)'
);
select is(current_setting('test.t10_pnl_gross', true),
  'NULL',
  'trade en cours : pnl_gross = NULL (status live, hors closed/archived)'
);


-- ============================================================================
-- Test 11 : tiers sans accès (1 ligne) — trade_metrics renvoie 0 ligne
--           pour un utilisateur qui n'est pas propriétaire du trade
-- ============================================================================
do $q$
declare
  v_user_a uuid := '00000000-0000-0000-0000-00000000001d';
  v_user_b uuid := '00000000-0000-0000-0000-00000000001e';
  v_inst_id uuid;
  v_trade_id uuid;
  v_count int;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital,
     initial_quantity, initial_capital, status)
  values
    (v_user_a, v_inst_id, 'long', 100, 1, 100,
     1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_b::text, true);

  select count(*) into v_count from public.trade_metrics(v_trade_id);

  perform set_config('test.t11_count', v_count::text, false);
  reset role;
end $q$;

select is(current_setting('test.t11_count', true)::int, 0,
  'trade_metrics par un tiers (user B sur trade de A) → 0 ligne (filtre user_id = auth.uid())'
);


-- ============================================================================
-- Test 12 : trade clôturé puis archivé garde son résultat dans
--           trade_metrics (échoue avant 026, réussit après — pnl_gross
--           étendu à status in (''closed'', ''archived'')).
-- ============================================================================
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001f';
  v_inst_id uuid;
  v_trade_id uuid;
  v_pnl_gross numeric;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital,
     initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100,
     1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);

  -- Clôture à 110 (pnl_gross = 10), puis archivage (sans p_exit_price,
  -- archived != closed).
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 110);
  perform public.transition_trade(v_trade_id, 'archived'::public.trade_status);

  select pnl_gross into v_pnl_gross
    from public.trade_metrics(v_trade_id);

  perform set_config('test.t12_pnl_gross', coalesce(v_pnl_gross::text, 'NULL'), false);
  reset role;
end $q$;

select is(current_setting('test.t12_pnl_gross', true)::numeric, 10::numeric,
  'clôturé+archivé : trade_metrics.pnl_gross reste 10 (status in closed/archived post-026)'
);


-- ============================================================================
-- Test 13 : event closed contient exit_price dans new_values
-- ============================================================================
-- Le trigger transition_trade historise l'événement 'closed' avec
-- new_values->>'exit_price' = p_exit_price (ici '110'). Garantit que
-- le PoP timeline capture bien le prix de sortie pour audit.
do $q$
declare
  v_user_id uuid := '00000000-0000-0000-0000-00000000001f';
  v_inst_id uuid;
  v_trade_id uuid;
  v_exit_price text;
begin
  v_inst_id := (select id from public.instruments where symbol = 'TESTUSD13');

  insert into public.trades
    (user_id, instrument_id, direction, entry_price, quantity, capital,
     initial_quantity, initial_capital, status)
  values
    (v_user_id, v_inst_id, 'long', 100, 1, 100,
     1, 100, 'live')
  returning id into v_trade_id;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform public.transition_trade(v_trade_id, 'closed'::public.trade_status, 110);

  select new_values->>'exit_price' into v_exit_price
    from public.trade_events
    where trade_id = v_trade_id and event_type = 'closed';

  perform set_config('test.t13_exit_price', v_exit_price, false);
  reset role;
end $q$;

select is(current_setting('test.t13_exit_price', true), '110',
  'event closed → new_values->>''exit_price'' = ''110'' (audit PoP timeline)'
);


-- ============================================================================
-- Tests 14-16 : droits EXECUTE sur public.trade_metrics
-- ============================================================================
-- PUBLIC : refusé (pg_proc + aclexplode, grantee = 0). has_function_privilege
-- avec 'public' peut lever "role does not exist" — on utilise donc
-- pg_proc + aclexplode, pattern recopié du test 11 (migration 024).
select is(
  exists (
    select 1
    from pg_proc p,
         aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = 'public.trade_metrics(uuid)'::regprocedure
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ),
  false,
  'trade_metrics EXECUTE refusé à PUBLIC (REVOKE)'
);

-- anon : refusé (has_function_privilege direct)
select is(
  has_function_privilege('anon', 'public.trade_metrics(uuid)', 'EXECUTE'),
  false,
  'trade_metrics EXECUTE refusé à anon (REVOKE FROM anon)'
);

-- authenticated : accordé
select is(
  has_function_privilege('authenticated', 'public.trade_metrics(uuid)', 'EXECUTE'),
  true,
  'trade_metrics EXECUTE accordé à authenticated (GRANT)'
);


-- ============================================================================
-- Test 17 : pnl_gross EXECUTE conservé pour authenticated
-- ============================================================================
-- La migration 026 ne touche PAS aux droits des fonctions de calcul.
-- Ce test piège toute migration future qui, par réflexe, ajouterait
-- un `revoke execute … from anon, authenticated` sur pnl_gross et
-- casserait du même coup les appels à pnl_net, rendement_pct,
-- r_multiple, sum_pnl, winrate, recent_trades_with_pnl exécutés sous
-- le rôle authenticated (dashboard, profil public authentifié, etc.).
-- Ces fonctions appellent pnl_gross en chaîne avec le rôle de
-- l'appelant.
select is(
  has_function_privilege('authenticated', 'public.pnl_gross(public.trades)', 'EXECUTE'),
  true,
  'pnl_gross EXECUTE conservé pour authenticated (la 026 ne touche pas aux droits des fonctions de calcul)'
);


select * from finish();
rollback;