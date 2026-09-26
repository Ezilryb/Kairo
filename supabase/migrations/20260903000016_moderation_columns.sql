-- /supabase/migrations/20260903000016_moderation_columns.sql
-- =============================================================================
-- Phase 7 — Modération & Sanctions (whitepaper §12)
-- Colonnes moderation_hidden / moderation_flagged_at sur trades et
-- trade_comments, plus index pour la requête d'alerte compte (4 posts
-- masqués en 24h, migration 017).
--
-- Sémantique :
--   - moderation_hidden : true → la cible est masquée aux non-proprios
--     (RLS de trades et trade_comments, migration 018). Default false.
--   - moderation_flagged_at : timestamp du passage à true. NULL tant que
--     pas masqué. Utilisé par l'alerte compte pour compter les posts
--     masqués dans la fenêtre glissante 24h.
--
-- Colonnes nullable / default :
--   - moderation_hidden : NOT NULL DEFAULT false (cohérent avec le
--     principe "pas de NULL vs 0 qui se confondent" — un trade qui
--     n'a jamais été modéré a false, jamais NULL).
--   - moderation_flagged_at : NULLABLE (sémantique "pas encore flaggé"
--     est utile et différente de "flaggé à un moment mais cleared",
--     qu'on n'utilise pas pour ce MVP).
--
-- Index :
--   - Index composites partiels (user_id, moderation_flagged_at) WHERE
--     moderation_hidden = true. Alimente la requête d'alerte compte :
--     SELECT count(*) FROM trades WHERE user_id = X AND
--     moderation_flagged_at >= now() - interval '24 hours' (idem
--     pour trade_comments). Index partiel car on ne filtre jamais sur
--     les posts non-masqués.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. trades.moderation_hidden + moderation_flagged_at
-- -----------------------------------------------------------------------------
alter table public.trades
  add column if not exists moderation_hidden boolean not null default false;

comment on column public.trades.moderation_hidden is
  'Masqué automatiquement par la modération (Phase 7) si le post reçoit ≥ 2 signalements tout statut. Default false. La RLS de la migration 018 masque la ligne aux non-proprios quand true.';

alter table public.trades
  add column if not exists moderation_flagged_at timestamptz;

comment on column public.trades.moderation_flagged_at is
  'Timestamp du passage à moderation_hidden=true. NULL tant que pas masqué. Utilisé par l''alerte compte (Phase 7) pour compter les posts masqués dans la fenêtre 24h.';


-- -----------------------------------------------------------------------------
-- 2. trade_comments.moderation_hidden + moderation_flagged_at
-- -----------------------------------------------------------------------------
alter table public.trade_comments
  add column if not exists moderation_hidden boolean not null default false;

alter table public.trade_comments
  add column if not exists moderation_flagged_at timestamptz;


-- -----------------------------------------------------------------------------
-- 3. Index partiels pour l'alerte compte (migration 017)
-- -----------------------------------------------------------------------------
-- WHERE moderation_hidden = true : on n'indexe que les lignes masquées,
-- car l'alerte compte ne filtre jamais sur les posts non-masqués.
create index if not exists trades_moderation_flagged_at_idx
  on public.trades (user_id, moderation_flagged_at)
  where moderation_hidden = true;

create index if not exists trade_comments_moderation_flagged_at_idx
  on public.trade_comments (user_id, moderation_flagged_at)
  where moderation_hidden = true;

commit;
