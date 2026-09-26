-- /supabase/migrations/20260903000002_fee_profiles.sql
-- =============================================================================
-- Phase 3 — Calculs Financiers : table fee_profiles + seed Binance/Kraken.
--
-- Contexte (whitepaper §06 — Calculs Financiers & Gestion des Frais) :
-- l'utilisateur sélectionne sa plateforme (Binance, Kraken, ...) et le
-- système applique un profil de frais estimé. trades.fees (déjà en place
-- depuis la Phase 0, type numeric(24,8), nullable) reste le champ de
-- correction manuelle : c'est la valeur RÉELLE constatée par
-- l'utilisateur, la source de vérité pour le calcul de PnL net.
--
-- fee_profiles ne fait QUE proposer une valeur par défaut côté UI au
-- moment de la publication. Il ne touche JAMAIS à la DB au moment du
-- publish — c'est purement une suggestion pour aider l'utilisateur à
-- remplir trades.fees s'il n'a pas encore les frais réels en tête. Le
-- profil peut être faux (estimation), le trade peut être saisi plus tard
-- (frais réel différent), on ne sait pas — d'où la séparation nette entre
-- "proposition indicative" (fee_profiles) et "valeur réelle constatée"
-- (trades.fees).
--
-- Structure : (exchange, asset_class, order_type) → (maker_fee, taker_fee)
--   - maker_fee : frais quand l'ordre ajoute de la liquidité (limit)
--   - taker_fee : frais quand l'ordre prend de la liquidité (market)
-- Les valeurs sont des fractions (0.00100 = 0.1%), pas des pourcentages.
--
-- Le seed couvre les 4 asset_class × 2 order_type × 2 exchanges = 16
-- lignes. Les asset_class 'stock'/'forex'/'etf' chez Binance/Kraken
-- sont à 0.00000 par défaut — ces exchanges ne supportent pas vraiment
-- ces asset classes, mais la ligne existe pour permettre à l'UI
-- d'afficher "pas de profil de frais disponible" au lieu de planter.
-- À l'usage, l'utilisateur saisira le frais réel dans trades.fees.
--
-- MAJ des valeurs : pas de trigger d'auto-update. C'est de la config
-- manuelle, à mettre à jour en éditant cette migration si Binance/
-- Kraken changent leurs tarifs. Une fois une migration appliquée, on
-- ne la modifie plus — pour ajuster les valeurs, nouvelle migration
-- (ou UPDATE direct en service_role).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- Table fee_profiles
-- -----------------------------------------------------------------------------
create table if not exists public.fee_profiles (
  id          uuid primary key default gen_random_uuid(),
  exchange    text not null,
  asset_class public.asset_class not null,
  order_type  text not null check (order_type in ('market', 'limit')),
  maker_fee   numeric(6,5) not null check (maker_fee >= 0 and maker_fee < 1),
  taker_fee   numeric(6,5) not null check (taker_fee >= 0 and taker_fee < 1),
  created_at  timestamptz not null default now(),
  unique (exchange, asset_class, order_type)
);

comment on table public.fee_profiles is
  'Profils de frais estimés par (exchange, asset_class, order_type). Utilisés par l''UI pour proposer une valeur par défaut à trades.fees au moment de la publication. Ne touche JAMAIS la DB au moment du publish — c''est une suggestion indicative, la valeur réelle reste trades.fees.';

comment on column public.fee_profiles.maker_fee is
  'Frais maker (limit, ajoute de la liquidité), en fraction (0.00100 = 0.1%).';

comment on column public.fee_profiles.taker_fee is
  'Frais taker (market, prend de la liquidité), en fraction (0.00100 = 0.1%).';

comment on column public.fee_profiles.order_type is
  'Type d''ordre : ''market'' (taker) ou ''limit'' (maker).';

-- Index de lookup : l'UI cherche par (exchange, asset_class) pour
-- pré-remplir trades.fees au moment de la publication.
create index if not exists fee_profiles_lookup_idx
  on public.fee_profiles (exchange, asset_class);

-- -----------------------------------------------------------------------------
-- Seed Binance + Kraken pour les 4 asset_class × 2 order_type
-- -----------------------------------------------------------------------------
-- Valeurs indicatives au 2025 (standards Binance/Kraken spot). À mettre
-- à jour via une nouvelle migration si les tarifs changent. Pas de
-- trigger d'auto-update — c'est de la config, pas du calcul.
--
-- Binance : 0.10% maker/taker sur spot crypto (standard VIP0). Pour les
-- asset_class non-crypto, Binance ne supporte pas → 0.00000, l'UI
-- affichera "pas de profil" et l'utilisateur saisira le frais réel.
--
-- Kraken : 0.16% maker / 0.26% taker sur spot crypto (Pro, standard).
-- Idem 0.00000 pour les non-crypto.
--
-- on conflict do nothing : permet une ré-exécution manuelle propre si
-- on doit ré-appliquer la migration.
insert into public.fee_profiles (exchange, asset_class, order_type, maker_fee, taker_fee) values
  -- Binance
  ('binance', 'crypto', 'market', 0.00100, 0.00100),
  ('binance', 'crypto', 'limit',  0.00100, 0.00100),
  ('binance', 'stock',  'market', 0.00000, 0.00000),
  ('binance', 'stock',  'limit',  0.00000, 0.00000),
  ('binance', 'forex',  'market', 0.00000, 0.00000),
  ('binance', 'forex',  'limit',  0.00000, 0.00000),
  ('binance', 'etf',    'market', 0.00000, 0.00000),
  ('binance', 'etf',    'limit',  0.00000, 0.00000),
  -- Kraken
  ('kraken',  'crypto', 'market', 0.00160, 0.00260),
  ('kraken',  'crypto', 'limit',  0.00160, 0.00260),
  ('kraken',  'stock',  'market', 0.00000, 0.00000),
  ('kraken',  'stock',  'limit',  0.00000, 0.00000),
  ('kraken',  'forex',  'market', 0.00000, 0.00000),
  ('kraken',  'forex',  'limit',  0.00000, 0.00000),
  ('kraken',  'etf',    'market', 0.00000, 0.00000),
  ('kraken',  'etf',    'limit',  0.00000, 0.00000)
on conflict (exchange, asset_class, order_type) do nothing;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
-- Lecture publique : les profils de frais ne sont pas sensibles, ils
-- servent à proposer une valeur par défaut à tout utilisateur (y
-- compris non authentifié pour les pages de marketing futures). Pas
-- d'INSERT/UPDATE/DELETE policy : la table est en lecture seule côté
-- authenticated, les seules écritures sont cette migration (DDL) et
-- éventuellement un script service_role pour mettre à jour les
-- valeurs si Binance/Kraken changent leurs tarifs.
alter table public.fee_profiles enable row level security;

drop policy if exists "fee_profiles: lecture publique" on public.fee_profiles;
create policy "fee_profiles: lecture publique"
  on public.fee_profiles for select
  using (true);

commit;
