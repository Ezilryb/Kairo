-- /supabase/migrations/20260903000010_crosstab_extra_dimensions.sql
-- =============================================================================
-- Phase 4 — Analytics Engine avancé (whitepaper §07)
-- Extension analytics_crosstab : 2 dimensions manquantes (Jour, Durée)
-- =============================================================================
-- Le cadrage initial listait 7 dimensions (Asset, Session, Jour, Direction,
-- Setup, Timeframe, Durée). La migration 009 exposait 5 d'entre elles comme
-- filtres d'analytics_crosstab. Manquaient : Jour et Durée — exposées ici
-- via les helpers _day_of_week et _duration_bucket déjà créés en 007.
--
-- IMPÉRATIF TECHNIQUE : les 2 nouveaux paramètres vont en FIN de liste,
-- après p_since, avec default null. CREATE OR REPLACE FUNCTION n'accepte
-- d'ajouter des paramètres à une fonction existante que s'ils sont ajoutés
-- en fin de liste avec une valeur par défaut. Si on les insérait au milieu,
-- Postgres créerait une fonction surchargée distincte au lieu de remplacer
-- l'existante, et on se retrouverait avec 2 analytics_crosstab qui
-- coexistent. L'ordre choisi préserve aussi la compatibilité positionnelle
-- des appels déjà écrits dans les tests 19-28.
--
-- Comportement des nouveaux filtres :
--   - p_day_of_week = 0..6 : match public._day_of_week(t.opened_at) = p_day_of_week
--   - p_duration_bucket = 'lt_15m' | '15m_1h' | '1h_4h' | '4h_1d' | 'gt_1d' | 'unknown'
--     match public._duration_bucket(t.closed_at - t.opened_at) = p_duration_bucket
--   - 'unknown' match les trades dont la durée est NULL (live, forgotten)
-- =============================================================================

create or replace function public.analytics_crosstab(
  p_user_id         uuid,
  p_instrument_id   uuid                          default null,
  p_direction       public.trade_direction        default null,
  p_session         text                          default null,
  p_setup           text                          default null,
  p_timeframe       public.trade_timeframe        default null,
  p_since           timestamptz                   default null,
  p_day_of_week     int                           default null,
  p_duration_bucket text                          default null
)
returns table (
  trade_count        bigint,
  winrate            numeric,
  avg_r_multiple     numeric,
  avg_rendement_pct  numeric
)
language sql
stable
security invoker
as $$
  with filtered as (
    select t.*
    from public.trades t
    where t.user_id = p_user_id
      and t.status = 'closed'
      and (p_instrument_id   is null or t.instrument_id = p_instrument_id)
      and (p_direction       is null or t.direction = p_direction)
      and (p_session         is null or public._trading_session(t.opened_at) = p_session)
      and (p_setup           is null or t.setup = p_setup)
      and (p_timeframe       is null or t.timeframe = p_timeframe)
      and (p_since           is null or t.closed_at >= p_since)
      and (p_day_of_week     is null or public._day_of_week(t.opened_at) = p_day_of_week)
      and (p_duration_bucket is null or public._duration_bucket(t.closed_at - t.opened_at) = p_duration_bucket)
  )
  select
    count(*)::bigint as trade_count,
    case
      when count(*) = 0 then null
      else (count(*) filter (where public.pnl_net(t.*) > 0))::numeric * 100.0 / count(*)::numeric
    end as winrate,
    avg(public.r_multiple(t.*))     as avg_r_multiple,
    avg(public.rendement_pct(t.*))  as avg_rendement_pct
  from filtered t
$$;

comment on function public.analytics_crosstab(uuid, uuid, public.trade_direction, text, text, public.trade_timeframe, timestamptz, int, text) is
  'Moteur de croisement multidimensionnel (whitepaper §07). 7 dimensions (asset, direction, session, setup, timeframe, day_of_week, duration_bucket) + p_since + p_user_id obligatoire. SECURITY INVOKER : respecte le RLS (user voit ses trades + les trades publics des autres). 0 trade → tout NULL sauf count=0. winrate = % de pnl_net > 0, en % (0-100).';
