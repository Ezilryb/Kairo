-- /supabase/migrations/20260903000009_analytics_crosstab.sql
-- =============================================================================
-- Phase 4 — Analytics Engine avancé (whitepaper §07)
-- Fonction analytics_crosstab : moteur de croisement multidimensionnel
-- =============================================================================
-- 7 dimensions du croisement §07 :
--   - p_user_id       (obligatoire)
--   - p_instrument_id (asset)
--   - p_direction
--   - p_session       (asia/europe/us — match _trading_session(opened_at))
--   - p_setup         (texte libre, match direct sur la colonne)
--   - p_timeframe     (enum)
--   - p_since         (filtre closed_at >= p_since)
--
-- Plutôt qu'une combinatoire de vues (asset×session×setup×... = explosion),
-- une seule fonction paramétrée : tous les filtres non-null sont appliqués.
--
-- Retourne (count, winrate, avg_r_multiple, avg_rendement_pct) sur les
-- trades CLOSED matchant les filtres. 0 trade → tout NULL sauf count=0.
--
-- SECURITY INVOKER : s'appuie sur le RLS existant. Sémantique :
--   - p_user_id = auth.uid() → le caller voit tous ses trades (privés + publics)
--   - p_user_id != auth.uid() → le caller voit seulement les trades publics
--     de cet autre user (is_public = true) + ses propres trades (RLS or)
-- =============================================================================

create or replace function public.analytics_crosstab(
  p_user_id       uuid,
  p_instrument_id uuid                          default null,
  p_direction     public.trade_direction        default null,
  p_session       text                          default null,
  p_setup         text                          default null,
  p_timeframe     public.trade_timeframe        default null,
  p_since         timestamptz                   default null
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
      and (p_instrument_id is null or t.instrument_id = p_instrument_id)
      and (p_direction     is null or t.direction = p_direction)
      and (p_session       is null or public._trading_session(t.opened_at) = p_session)
      and (p_setup         is null or t.setup = p_setup)
      and (p_timeframe     is null or t.timeframe = p_timeframe)
      and (p_since         is null or t.closed_at >= p_since)
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

comment on function public.analytics_crosstab(uuid, uuid, public.trade_direction, text, text, public.trade_timeframe, timestamptz) is
  'Moteur de croisement multidimensionnel (whitepaper §07). Filtres non-null appliqués sur trades closed. SECURITY INVOKER : respecte le RLS (user voit ses trades + les trades publics des autres). 0 trade → tout NULL sauf count=0. winrate = % de pnl_net > 0, en % (0-100).';
