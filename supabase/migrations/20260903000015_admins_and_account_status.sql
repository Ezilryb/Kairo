-- /supabase/migrations/20260903000015_admins_and_account_status.sql
-- =============================================================================
-- Phase 7 — Modération & Sanctions (whitepaper §12)
-- Table admins (rôle admin) + type account_status + colonne users.account_status.
--
-- JUSTIFICATION TABLE DÉDIÉE (PAS colonne is_admin sur users) :
-- La policy RLS actuelle "users: modification de son propre profil"
-- (migration initiale 0001) autorise un user à modifier N'IMPORTE QUELLE
-- colonne de sa propre ligne via `auth.uid() = id`. Une colonne
-- is_admin directement sur users serait auto-attribuable par
-- n'importe quel user via un simple UPDATE client — faille de privilège
-- triviale. À la place : table dédiée admins, RLS activée sans aucune
-- policy client, lecture/écriture exclusivement via service_role (SQL
-- Editor Supabase pour ce MVP, pas d'UI admin). Toutes les fonctions
-- admin vérifient explicitement :
--   exists (select 1 from public.admins where user_id = auth.uid())
--
-- SÉMA NTIQUE account_status (Phase 7 MVP) :
-- 4 valeurs enum : active (normal), shadowbanned, suspended, banned.
-- Pour ce MVP, les 3 valeurs non-active ont le MÊME effet (masquage
-- aux autres — appliqué via RLS policies de la migration 018). Les
-- permissions d'action différentes (banned empêche aussi de publier)
-- sont un raffinement à cadrer séparément.
--
-- Le champ notification_type = 'moderation' (enum notification_type
-- depuis la migration initiale 0001) reste non câblé cette phase :
-- il n'existe aucune UI admin de consommation, audit_logs sert déjà
-- de journal consultable (SQL direct pour ce MVP). À reprendre si une
-- UI admin est cadrée plus tard — noté explicitement plutôt que de le
-- laisser tomber en silence.
--
-- Hors scope explicite : bloquer réellement la connexion d'un compte
-- banned est un sujet Supabase Auth Admin API (auth.admin.updateUserById
-- avec ban_duration), donc TypeScript/service_role, pas SQL. À cadrer
-- séparément (probablement Phase 8 ou un round dédié admin).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Type account_status
-- -----------------------------------------------------------------------------
create type public.account_status as enum (
  'active',        -- normal, visible et actif
  'shadowbanned',  -- contenu masqué aux autres (Phase 7 MVP)
  'suspended',     -- contenu masqué aux autres (Phase 7 MVP)
  'banned'         -- contenu masqué aux autres (Phase 7 MVP)
);

comment on type public.account_status is
  'État de modération d''un compte (Phase 7). active = normal. Les 3 valeurs non-active ont le même effet pour ce MVP : masquage du contenu aux autres via RLS policies (migration 018). Distinguer par des permissions d''action différentes (ex : banned empêche de publier) est un raffinement à cadrer séparément, hors scope Phase 7.';


-- -----------------------------------------------------------------------------
-- 2. Table admins (rôle admin)
-- -----------------------------------------------------------------------------
create table public.admins (
  user_id     uuid primary key references public.users (id) on delete cascade,
  granted_at  timestamptz not null default now(),
  granted_by  uuid references public.users (id)
);

comment on table public.admins is
  'Rôle admin (Phase 7 Modération). Table dédiée plutôt qu''une colonne is_admin sur users : la RLS "users: modification de son propre profil" autoriserait n''importe quel user à s''auto-promouvoir via UPDATE client. RLS activée sans aucune policy — table inaccessible aux rôles anon/authenticated. Lecture/écriture exclusivement via service_role (SQL Editor Supabase pour ce MVP, pas d''UI admin).';

comment on column public.admins.user_id is
  'User promu admin. PK (un user = au plus une ligne).';

comment on column public.admins.granted_at is
  'Timestamp de la promotion. DEFAULT now().';

comment on column public.admins.granted_by is
  'User qui a accordé le rôle (pour audit). Référence users mais pas FK pour permettre la suppression de l''admin originel sans casser la trace.';


-- -----------------------------------------------------------------------------
-- 3. Colonne users.account_status
-- -----------------------------------------------------------------------------
alter table public.users
  add column if not exists account_status public.account_status not null default 'active';

comment on column public.users.account_status is
  'État de modération du compte (Phase 7). DEFAULT ''active''. Migration 018 applique la RLS : un user shadowbanned/suspended/banned a son contenu masqué aux autres (mais le propriétaire voit toujours le sien, peu importe son statut — "le compte reste actif", il doit voir ce qui lui arrive).';


-- -----------------------------------------------------------------------------
-- 4. RLS sur admins : aucune policy client
-- -----------------------------------------------------------------------------
alter table public.admins enable row level security;

-- (aucune policy SELECT/INSERT/UPDATE/DELETE pour anon/authenticated.
-- Table inaccessible en rôle client — bypass uniquement via service_role.)

commit;
