-- /supabase/migrations/20260903000005_setup_timeframe.sql
-- =============================================================================
-- Phase 4 — Analytics Engine avancé (whitepaper §07) — Colonnes setup + timeframe
-- =============================================================================
-- Contexte : §07 croise 7 dimensions (Asset, Session, Jour, Direction, Setup,
-- Timeframe, Durée). À l'issue de la Phase 3, instrument_id et direction
-- existent, session/jour/durée sont dérivables à la volée depuis opened_at /
-- closed_at. Manquent : setup et timeframe — colonnes ajoutées ici.
--
-- Choix de modélisation :
--   - setup : TEXT libre. Les setups sont propres à chaque trader, un enum
--     figerait leur vocabulaire. L'auto-complétion basée sur l'historique
--     utilisateur est une amélioration UI pour plus tard (Phase 9), pas un
--     prérequis DB. NULL autorisé (utilisateur n'a pas renseigné).
--   - timeframe : ENUM avec 8 valeurs standard (1m → 1w). DISTINCT du
--     "Timeframe auto" des graphiques (§08, Phase 5) : ici c'est l'INTENTION
--     de trading déclarée par l'utilisateur à la création du trade, pas
--     un réglage d'affichage de chart. Voir commentaire de colonne.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Type enum trade_timeframe
-- -----------------------------------------------------------------------------
create type public.trade_timeframe as enum (
  '1m', '5m', '15m', '30m', '1h', '4h', '1d', '1w'
);

-- -----------------------------------------------------------------------------
-- 2. Colonnes
-- -----------------------------------------------------------------------------
alter table public.trades
  add column setup    text,
  add column timeframe public.trade_timeframe;

-- setup : texte libre décrivant le setup de trading (ex: "breakout range",
-- "pullback EMA20", "order block 4H"). NULL si non renseigné. Pas de
-- normalisation en DB : un trader peut écrire ce qu'il veut. L'UI pourra
-- proposer une auto-complétion depuis l'historique utilisateur (Phase 9).
comment on column public.trades.setup is
  'Setup de trading déclaré par l''utilisateur (texte libre, pas d''enum). Auto-complétion UI depuis historique utilisateur en Phase 9.';

-- timeframe : INTENTION de trading (sur quel horizon l''utilisateur trade),
-- DISTINCT du "Timeframe auto" des graphiques (§08, Phase 5) qui est un
-- réglage d''affichage de chart. Un trade long terme (timeframe=1d) peut être
-- visualisé sur un chart 15m (Timeframe auto=15m). Les deux concepts ne se
-- confondent pas.
comment on column public.trades.timeframe is
  'Intention de trading déclarée à la création du trade (sur quel horizon l''utilisateur trade). DISTINCT du "Timeframe auto" des graphiques (§08, Phase 5) qui est un réglage d''affichage de chart.';

-- -----------------------------------------------------------------------------
-- 3. Index partiels — pour le moteur d'analytics (analytics_crosstab)
-- -----------------------------------------------------------------------------
-- Les requêtes du moteur de crosstab filtrent typiquement par user_id + une
-- des dimensions (setup, timeframe). Un index composite (user_id, dimension)
-- permet d'éviter un seq scan même quand setup/timeframe sont NULL (l'index
-- stocke toutes les lignes, le planner choisit en fonction de la sélectivité).
create index trades_user_id_setup_idx
  on public.trades (user_id, setup);
create index trades_user_id_timeframe_idx
  on public.trades (user_id, timeframe);

-- -----------------------------------------------------------------------------
-- 4. Grants (le default EXECUTE/SELECT est à PUBLIC pour les types, donc rien
--    à faire côté grants : authenticated peut lire/écrire setup et timeframe
--    via le client Supabase selon les policies RLS déjà en place).
-- -----------------------------------------------------------------------------
