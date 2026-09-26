-- /supabase/migrations/20260903000008_plan_adherence_score.sql
-- =============================================================================
-- Phase 4 — Analytics Engine avancé (whitepaper §07)
-- Fonction plan_adherence_score : score de respect du plan (/100)
-- =============================================================================
-- 4 composantes × 25 = 100 :
--   - Entrée (25) : compte les events entry_modified
--       0 → 25, 1 → 15, ≥2 → 5
--   - SL    (25) : compte les events sl_modified (déjà logués Phase 0/2)
--       0 → 25, 1 → 15, ≥2 → 5
--   - TP    (25) : compte les events tp_modified (déjà logués Phase 0/2)
--       0 → 25, 1 → 15, ≥2 → 5
--   - Risque (25) :
--       - stop_loss IS NULL → 0 (aucun risque défini au départ)
--       - mistake_type IN ('sl_non_respecte','sl_deplace','surdimensionnement') → 0
--       - sinon → 25
--
-- Retourne NULL si status NOT IN ('closed','archived') — même principe que
-- pnl_gross avant clôture (Phase 3) : un trade non terminé n'a pas de score.
--
-- SECURITY INVOKER : s'appuie sur le RLS existant. Si le caller peut SELECT
-- le trade, il peut SELECT ses events (RLS trade_events donne accès aux
-- events des trades visibles via le même predicate is_public OR user_id=auth.uid()).
--
-- Premier jet raisonné, pas une vérité gravée (cf. brief chef). Barème à
-- ajuster quand on aura des vraies données utilisateur.
-- =============================================================================

create or replace function public.plan_adherence_score(p_trade public.trades)
returns integer
language sql
stable
security invoker
as $$
  with event_counts as (
    select
      count(*) filter (where event_type = 'entry_modified') as entry_count,
      count(*) filter (where event_type = 'sl_modified')    as sl_count,
      count(*) filter (where event_type = 'tp_modified')    as tp_count
    from public.trade_events
    where trade_id = p_trade.id
  ),
  components as (
    select
      -- Entrée : 0 modif = 25, 1 modif = 15, ≥2 modif = 5
      case
        when ec.entry_count >= 2 then 5
        when ec.entry_count = 1  then 15
        else 25
      end as entry_score,
      -- SL : idem
      case
        when ec.sl_count >= 2 then 5
        when ec.sl_count = 1  then 15
        else 25
      end as sl_score,
      -- TP : idem
      case
        when ec.tp_count >= 2 then 5
        when ec.tp_count = 1  then 15
        else 25
      end as tp_score,
      -- Risque
      case
        when p_trade.stop_loss is null then 0
        when p_trade.mistake_type in ('sl_non_respecte','sl_deplace','surdimensionnement') then 0
        else 25
      end as risk_score
    from event_counts ec
  )
  select case
    when p_trade.status not in ('closed','archived') then null
    else entry_score + sl_score + tp_score + risk_score
  end
  from components
$$;

comment on function public.plan_adherence_score(public.trades) is
  'Score de respect du plan sur /100 (4×25 : Entrée + SL + TP + Risque). NULL si status NOT IN (closed, archived). Composante Risque = 0 si stop_loss IS NULL OU si mistake_type IN (sl_non_respecte, sl_deplace, surdimensionnement). Premier jet — barème à ajuster avec données réelles.';
