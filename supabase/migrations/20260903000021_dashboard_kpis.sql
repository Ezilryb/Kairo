-- /supabase/migrations/20260903000021_dashboard_kpis.sql
-- =============================================================================
-- Dashboard — KPIs financiers + liste "trades récents" (Phase 10 / Dashboard)
-- =============================================================================
-- Contexte : la page /app/(dashboard)/page.tsx a été livrée en Phase 0 avec
-- des données mockées et n'a jamais été recâblée (item A4 de l'audit
-- visuel Phase 9). Phase 3 (calculs financiers) puis Phase 4 (analytics)
-- ont exposé toutes les fonctions nécessaires côté DB, mais aucune ne
-- couvre (a) la SOMME de pnl_net sur une fenêtre temporelle, ni
-- (b) une liste "trades récents" qui ramène pnl_net / rendement_pct
-- calculés (règle whitepaper §09 : PnL obligatoire côté DB, jamais
-- côté client). Cette migration comble ces deux manques.
--
-- DEUX FONCTIONS, toutes deux SECURITY INVOKER + `t.*` direct depuis
-- `public.trades t` (pas de CTE intermédiaire qui renverrait un `record`
-- anonyme, leçon round 6 migrations). Les deux respectent la RLS
-- existante sur trades : un user qui appelle sum_pnl(target_user_id) ne
-- verra que les trades visibles (ses propres + publics de l'autre).
--
-- RÉGRESSION ANALYTIQUE FUTURE : si on a besoin d'une fenêtre "depuis
-- le début de l'année" ou "12 derniers mois glissants", préférer
-- l'ajout d'un p_until (avec p_since ET p_until) à la migration d'un
-- 3e paramètre. CREATE OR REPLACE accepte les params en queue avec
-- default ; on conserve cette discipline.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. sum_pnl(p_user_id, p_since) — somme de pnl_net sur les trades closed
-- -----------------------------------------------------------------------------
-- Retourne un numérique en devise de l'user (pas un rendement en %).
--
-- coalesce(..., 0) : un user qui n'a aucun trade closed sur la fenêtre
-- retourne 0, pas NULL. Côté UI ça permet d'afficher "0 €" plutôt que
-- "—" — un 0 € honnête est plus informatif qu'un tiret ambigu quand
-- l'user n'a simplement pas tradé sur les 30 derniers jours.
--
-- Différence à `analytics_crosstab(p_user_id, p_since)` : ce dernier
-- retourne des MOYENNES (avg_r_multiple, avg_rendement_pct) et un
-- winrate, pas une somme. Pas ré-utilisable tel quel pour le KPI
-- "PnL net (30 j)" du Dashboard.
create or replace function public.sum_pnl(
  p_user_id uuid,
  p_since   timestamptz default null
)
returns numeric
language sql
stable
security invoker
as $$
  select coalesce(sum(public.pnl_net(t.*)), 0)::numeric
  from public.trades t
  where t.user_id = p_user_id
    and t.status = 'closed'
    and (p_since is null or t.closed_at >= p_since)
$$;

comment on function public.sum_pnl(uuid, timestamptz) is
  'Somme de pnl_net sur les trades closed de l''utilisateur, optionnellement depuis p_since. Retourne 0 (pas NULL) si aucun trade closed sur la fenêtre. SECURITY INVOKER : respecte le RLS (un user appelant sum_pnl(target_user_id) ne voit que les trades visibles).';


-- -----------------------------------------------------------------------------
-- 2. recent_trades_with_pnl(p_user_id, p_limit) — N derniers trades avec PnL
-- -----------------------------------------------------------------------------
-- Liste les N derniers trades de l'user (toutes statuses), enrichis de :
--   - symbol + asset_class de l'instrument (JOIN direct, FK not null)
--   - pnl_net calculé (null si non closed ou exit_price manquant)
--   - rendement_pct calculé (null si non closed ou capital = 0)
--
-- Pourquoi pas une simple .from('trades').select(...) côté Supabase JS :
-- la règle whitepaper §09 impose PnL côté DB. Calculer pnl_net côté
-- client (exit - entry * qty * dir - fees - slippage) dupliquerait la
-- logique de la DB et rouvrirait la porte au trafiquage.
--
-- Pourquoi pas 2 queries côté client (1 trades + 1 instruments via IN) :
-- vu que les 2 sont consommées ENSEMBLE dans le Dashboard, autant
-- faire 1 round-trip qui ramène tout. Le JOIN direct sur l'instrument
-- est valide ici parce qu'instrument_id est NOT NULL sur trades
-- (migration 001) — pas de LEFT JOIN nécessaire.
--
-- Tri : updated_at desc nulls last puis created_at desc. nulls last
-- pour qu'un trade qui n'a jamais été update (rare, mais possible si
-- jamais update_atouched) ne se retrouve pas en tête artificiellement.
-- p_limit plafonné à 50 dans le corps pour éviter qu'un appelant
-- distrait demande 10 000 lignes.
create or replace function public.recent_trades_with_pnl(
  p_user_id uuid,
  p_limit   int default 7
)
returns table (
  id            uuid,
  status        public.trade_status,
  direction     public.trade_direction,
  entry_price   numeric,
  exit_price    numeric,
  quantity      numeric,
  capital       numeric,
  fees          numeric,
  slippage      numeric,
  closed_at     timestamptz,
  updated_at    timestamptz,
  created_at    timestamptz,
  instrument_id uuid,
  symbol        text,
  asset_class   public.asset_class,
  pnl_net       numeric,
  rendement_pct numeric
)
language sql
stable
security invoker
as $$
  select
    t.id,
    t.status,
    t.direction,
    t.entry_price,
    t.exit_price,
    t.quantity,
    t.capital,
    t.fees,
    t.slippage,
    t.closed_at,
    t.updated_at,
    t.created_at,
    i.id           as instrument_id,
    i.symbol,
    i.asset_class,
    public.pnl_net(t.*)       as pnl_net,
    public.rendement_pct(t.*) as rendement_pct
  from public.trades t
  join public.instruments i on i.id = t.instrument_id
  where t.user_id = p_user_id
  order by t.updated_at desc nulls last, t.created_at desc
  limit least(greatest(p_limit, 1), 50)
$$;

comment on function public.recent_trades_with_pnl(uuid, int) is
  'N derniers trades de l''utilisateur (toutes statuses) avec pnl_net et rendement_pct calculés, joint à l''instrument pour symbol + asset_class. p_limit entre 1 et 50 (clamp défensif). SECURITY INVOKER : respecte le RLS. NULL sur pnl_net/rendement_pct si trade non closed ou exit_price manquant.';


commit;