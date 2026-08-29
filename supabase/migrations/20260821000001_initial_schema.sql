-- /supabase/migrations/20260821000001_initial_schema.sql
-- =============================================================================
-- Migration 0001 — Schéma initial (Whitepaper v6.0 §04/§05)
-- Trading Journal & Réseau Social — Phase 0 / Tâche 2
--
-- Contenu :
--   1. Enums Postgres (statuts, directions, événements, psychologie, modération)
--   2. Tables : users, instruments, trades, trade_events, trade_comments,
--      followers, reports, notifications, audit_logs
--   3. Triggers métier : immuabilité entry_price post-publication (fenêtre
--      scalping 60 s), historisation SL/TP dans trade_events, immuabilité
--      de trade_events, updated_at automatique
--   4. RLS activé sur TOUTES les tables dès cette migration (policies de
--      base — à durcir au fil des phases, jamais ajouté après coup)
--
-- Auth : SSO uniquement via Supabase Auth — aucune colonne mot de passe ici.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. ENUMS
-- -----------------------------------------------------------------------------

create type public.trade_direction as enum ('long', 'short');

create type public.trade_status as enum (
  'draft',      -- Brouillon, non publié, tout est modifiable
  'live',       -- Publié, verrouillé (sauf fenêtre scalping 60 s)
  'forgotten',  -- Bascule auto après 5 jours calendaires d'inactivité
  'closed',     -- Clôturé (manuel ou atteinte SL/TP)
  'archived'    -- Conservation long terme
);

create type public.trade_event_type as enum (
  'created',
  'published',
  'entry_modified',    -- uniquement pendant la fenêtre scalping 60 s
  'sl_modified',
  'tp_modified',
  'info_modified',     -- notes, champs psycho, etc. pendant la fenêtre 60 s
  'partial_exit',      -- sortie partielle (réduction de position autorisée)
  'marked_forgotten',
  'reactivated',
  'closed',
  'archived'
);

-- Psychologie de sortie / erreur (§07)
create type public.emotion_type as enum (
  'calme', 'confiant', 'fomo', 'impatience', 'peur',
  'euphorie', 'revenge', 'surconfiance', 'fatigue', 'distraction'
);

create type public.mistake_type as enum (
  'aucune', 'entree_prematuree', 'entree_tardive', 'sortie_prematuree',
  'sortie_tardive', 'sl_deplace', 'sl_non_respecte', 'tp_non_respecte',
  'surdimensionnement', 'overtrading', 'revenge_trading', 'autre'
);

create type public.asset_class as enum (
  'crypto', 'stock', 'forex', 'commodity', 'index', 'etf'
);

create type public.report_reason as enum (
  'spam', 'scam', 'false_info', 'harassment', 'impersonation'
);

create type public.report_status as enum (
  'pending', 'under_review', 'resolved', 'dismissed'
);

create type public.notification_type as enum (
  'follow', 'comment', 'like', 'mention', 'trade_forgotten', 'system', 'moderation'
);

-- -----------------------------------------------------------------------------
-- 2. TABLES
-- -----------------------------------------------------------------------------

-- ---- users -----------------------------------------------------------------
-- Profil applicatif lié à auth.users (SSO Google/Facebook via Supabase Auth).
-- AUCUNE colonne mot de passe : l'authentification est déléguée à Supabase Auth.
create table public.users (
  id          uuid primary key references auth.users (id) on delete cascade,
  pseudo      text not null unique
              check (char_length(pseudo) between 3 and 30),
  bio         text,
  avatar_url  text,
  is_public   boolean not null default true,  -- profil public vs privé (§09)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---- instruments -------------------------------------------------------------
create table public.instruments (
  id             uuid primary key default gen_random_uuid(),
  symbol         text not null,                -- ex: BTCUSDT, AAPL
  name           text not null,                -- ex: Bitcoin / US Dollar
  asset_class    public.asset_class not null,
  exchange       text,                         -- ex: binance, kraken, nasdaq
  base_currency  text,
  quote_currency text,
  created_at     timestamptz not null default now(),
  unique (symbol, exchange)
);

-- ---- trades ------------------------------------------------------------------
create table public.trades (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.users (id) on delete cascade,
  instrument_id  uuid not null references public.instruments (id),
  direction      public.trade_direction not null,
  status         public.trade_status not null default 'draft',

  -- Prix d'entrée : non nullable, immuable post-publication (trigger ci-dessous,
  -- avec fenêtre scalping de 60 s après published_at — §04)
  entry_price    numeric(24, 8) not null check (entry_price > 0),

  -- SL/TP : figés à la publication pour le Plan Adherence Score ; toute
  -- modification ultérieure est tracée dans trade_events (trigger ci-dessous)
  stop_loss      numeric(24, 8),
  take_profit    numeric(24, 8),

  quantity       numeric(24, 8) not null check (quantity > 0),
  leverage       numeric(10, 2) not null default 1 check (leverage >= 1),
  capital        numeric(24, 8) not null check (capital >= 0),
  risk_percent   numeric(6, 3) check (risk_percent >= 0 and risk_percent <= 100),
  fees           numeric(24, 8),               -- frais réels (corrigés par l'utilisateur)
  slippage       numeric(24, 8),

  opened_at      timestamptz,
  closed_at      timestamptz,
  published_at   timestamptz,                  -- null tant que status = 'draft'
  last_activity_at timestamptz not null default now(),  -- pour la bascule OUBLIÉ (5 j)

  -- Psychologie (§05/§07) — optionnels
  emotion        public.emotion_type,
  stress         smallint check (stress between 1 and 10),
  confidence     smallint check (confidence between 1 and 10),
  plan_followed  boolean,
  mistake_type   public.mistake_type,
  notes          text,

  -- Visibilité : un trade peut être masqué même si le profil est public
  is_public      boolean not null default true,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index trades_user_id_idx       on public.trades (user_id);
create index trades_instrument_id_idx on public.trades (instrument_id);
create index trades_status_idx        on public.trades (status);
create index trades_last_activity_idx on public.trades (last_activity_at)
  where status = 'live';  -- alimente le job de bascule OUBLIÉ

-- ---- trade_events ------------------------------------------------------------
-- Historique IMMUABLE des actions sur un trade (§04/§05).
-- Toute modification de SL/TP, sortie partielle, changement de statut y est
-- consignée — jamais écrasée en place sur trades.
create table public.trade_events (
  id          uuid primary key default gen_random_uuid(),
  trade_id    uuid not null references public.trades (id) on delete cascade,
  user_id     uuid not null references public.users (id) on delete cascade,
  event_type  public.trade_event_type not null,
  old_values  jsonb,        -- état avant (ex: {"stop_loss": 42000})
  new_values  jsonb,        -- état après
  created_at  timestamptz not null default now()
);

create index trade_events_trade_id_idx on public.trade_events (trade_id);
create index trade_events_created_idx  on public.trade_events (created_at);

-- ---- trade_comments ----------------------------------------------------------
create table public.trade_comments (
  id          uuid primary key default gen_random_uuid(),
  trade_id    uuid not null references public.trades (id) on delete cascade,
  user_id     uuid not null references public.users (id) on delete cascade,
  content     text not null check (char_length(content) between 1 and 2000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz   -- soft delete (modération §12)
);

create index trade_comments_trade_id_idx on public.trade_comments (trade_id);

-- ---- followers ---------------------------------------------------------------
create table public.followers (
  follower_id  uuid not null references public.users (id) on delete cascade,
  followee_id  uuid not null references public.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create index followers_followee_idx on public.followers (followee_id);

-- ---- reports -----------------------------------------------------------------
-- Signalements (§12) : cible = un trade, un commentaire ou un utilisateur.
create table public.reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid not null references public.users (id) on delete cascade,
  reported_user_id uuid references public.users (id) on delete set null,
  trade_id         uuid references public.trades (id) on delete set null,
  comment_id       uuid references public.trade_comments (id) on delete set null,
  reason           public.report_reason not null,
  details          text,
  status           public.report_status not null default 'pending',
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz,
  resolved_by      uuid references public.users (id) on delete set null,
  check (trade_id is not null or comment_id is not null or reported_user_id is not null)
);

create index reports_status_idx    on public.reports (status);
create index reports_trade_idx     on public.reports (trade_id) where trade_id is not null;

-- ---- notifications -----------------------------------------------------------
create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id) on delete cascade,
  type        public.notification_type not null,
  payload     jsonb not null default '{}'::jsonb,  -- ex: {"trade_id": "...", "actor_id": "..."}
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index notifications_user_unread_idx on public.notifications (user_id)
  where read_at is null;

-- ---- audit_logs --------------------------------------------------------------
-- Journal d'audit (modération, actions admin, événements sensibles — §12).
-- Écrit uniquement via service_role ; jamais exposé aux clients.
create table public.audit_logs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references public.users (id) on delete set null,
  action      text not null,        -- ex: 'trade.auto_forgotten', 'user.suspended'
  entity_type text,                 -- ex: 'trade', 'user', 'report'
  entity_id   uuid,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

create index audit_logs_entity_idx    on public.audit_logs (entity_type, entity_id);
create index audit_logs_created_idx   on public.audit_logs (created_at);

-- -----------------------------------------------------------------------------
-- 3. TRIGGERS MÉTIER
-- -----------------------------------------------------------------------------

-- ---- updated_at générique ----------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger set_users_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

create trigger set_trades_updated_at
  before update on public.trades
  for each row execute function public.set_updated_at();

create trigger set_trade_comments_updated_at
  before update on public.trade_comments
  for each row execute function public.set_updated_at();

-- ---- Immuabilité entry_price post-publication (§04) --------------------------
-- Règle : une fois publié, entry_price ne peut plus JAMAIS être modifié,
-- sauf pendant la fenêtre scalping de 60 secondes suivant published_at.
-- La règle est aussi appliquée côté application ; ce trigger est la garantie DB.
create or replace function public.enforce_entry_price_immutability()
returns trigger language plpgsql as $$
begin
  if new.entry_price is distinct from old.entry_price then
    if old.status <> 'draft'
       and old.published_at is not null
       -- Fenêtre scalping = exactement 60 s : la comparaison est STRICTEMENT
       -- supérieure (>), donc la borne 60 s pile est encore incluse. Au-delà
       -- (60 s + ε), la modification d'entry_price est refusée.
       and now() > old.published_at + interval '60 seconds' then
      raise exception
        'entry_price est immuable après publication (fenêtre scalping de 60 s expirée)';
    end if;
  end if;
  return new;
end $$;

create trigger trades_enforce_entry_price_immutability
  before update on public.trades
  for each row execute function public.enforce_entry_price_immutability();

-- ---- Historisation SL/TP dans trade_events (§04/§05) -------------------------
-- Toute modification de stop_loss / take_profit sur un trade publié est
-- automatiquement tracée dans trade_events (jamais écrasée silencieusement).
create or replace function public.log_sl_tp_changes()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.status <> 'draft' then
    if new.stop_loss is distinct from old.stop_loss then
      insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
      values (old.id, old.user_id, 'sl_modified',
              jsonb_build_object('stop_loss', old.stop_loss),
              jsonb_build_object('stop_loss', new.stop_loss));
    end if;
    if new.take_profit is distinct from old.take_profit then
      insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
      values (old.id, old.user_id, 'tp_modified',
              jsonb_build_object('take_profit', old.take_profit),
              jsonb_build_object('take_profit', new.take_profit));
    end if;
  end if;
  -- Toute activité sur le trade repousse la bascule OUBLIÉ (5 jours)
  new.last_activity_at := now();
  return new;
end $$;

create trigger trades_log_sl_tp_changes
  before update on public.trades
  for each row execute function public.log_sl_tp_changes();

-- ---- Immuabilité de trade_events ----------------------------------------------
-- L'historique ne se modifie ni ne se supprime jamais en fonctionnement normal
-- (Proof of Performance).
-- Exception unique et explicite : le rôle service_role est autorisé à passer,
-- car c'est le canal dédié à l'effacement de compte RGPD (Phase 8) qui doit
-- supprimer la chaîne users → trades → trade_events en cascade. Le service_role
-- possède BYPASSRLS, ce qui contourne les RLS policies, mais PAS les triggers :
-- d'où ce garde-fou explicite dans la fonction.
-- Détection : auth.role() = 'service_role' (API Supabase canonique). La fonction
-- n'est PAS security definer, donc auth.role() reflète bien le rôle de l'appelant,
-- y compris dans un DELETE déclenché par ON DELETE CASCADE.
create or replace function public.forbid_trade_events_mutation()
returns trigger language plpgsql as $$
begin
  if auth.role() = 'service_role'
     or current_setting('app.allow_trade_events_mutation', true) = 'true' then
    -- Garde-fou levé :
    --   - soit on est en service_role (PostgREST direct, BYPASSRLS)
    --   - soit le flag de session 'app.allow_trade_events_mutation' a été posé
    --     par prepare_user_deletion_cascade() lors d'un DELETE sur auth.users
    --     (couvre le chemin auth.admin.deleteUser() / GoTrue, où le rôle réel
    --     est supabase_auth_admin et auth.role() n'est pas positionné).
    -- TG_OP gère le retour : OLD pour DELETE (NEW est NULL), NEW pour UPDATE/INSERT.
    if tg_op = 'DELETE' then
      return old;
    else
      return new;
    end if;
  end if;
  raise exception 'trade_events est immuable : UPDATE/DELETE interdits';
end $$;

create trigger trade_events_no_update
  before update on public.trade_events
  for each row execute function public.forbid_trade_events_mutation();

create trigger trade_events_no_delete
  before delete on public.trade_events
  for each row execute function public.forbid_trade_events_mutation();

-- ---- Préparation de la cascade RGPD sur suppression de compte ----------------
-- Trigger sur auth.users : s'exécute AVANT que la cascade FK (auth.users →
-- public.users → public.trades → public.trade_events) ne démarre. Il (1) écrit
-- un audit log de la suppression de compte et (2) pose un flag de session
-- 'app.allow_trade_events_mutation' que le trigger forbid_trade_events_mutation
-- lit pour laisser passer le DELETE en cascade.
--
-- Ce design couvre TOUS les chemins de suppression d'un compte Supabase :
--   - auth.admin.deleteUser() (API serveur, chemin Phase 8)
--   - Supabase Dashboard (Studio) — même chemin interne GoTrue
--   - DELETE direct sur auth.users depuis psql / procédure SQL
-- Sans dépendre du rôle PostgreSQL appelant (qui n'est pas service_role dans
-- le chemin GoTrue : c'est supabase_auth_admin, et il n'a pas accès au schéma
-- public par défaut — d'où le SECURITY DEFINER ci-dessous).
--
-- Le second argument de set_config à `true` rend le flag LOCAL à la transaction :
-- il ne survit pas au COMMIT, donc on n'ouvre aucune fenêtre où un autre DELETE
-- dans une autre transaction pourrait en profiter.
create or replace function public.prepare_user_deletion_cascade()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pseudo text;
begin
  select pseudo into v_pseudo from public.users where id = old.id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (null, 'user.gdpr_deleted', 'user', old.id,
          jsonb_build_object('pseudo', v_pseudo));
  -- user_id volontairement NULL (pas old.id) : public.users va disparaître
  -- dans le même DELETE, autant ne pas dépendre de l'ordre exact de la cascade.
  -- entity_id porte l'identifiant (pas de FK dessus, donc pas de risque).

  perform set_config('app.allow_trade_events_mutation', 'true', true);
  return old;
end $$;

create trigger on_auth_user_deleted_prepare_cascade
  before delete on auth.users
  for each row execute function public.prepare_user_deletion_cascade();

-- -----------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY — activé dès cette migration sur TOUTES les tables
-- -----------------------------------------------------------------------------
-- Policies de base (Phase 0) : lisibles par tous ce qui est public, modifiable
-- uniquement par le propriétaire. Le durcissement (visibilité profil privé §09,
-- rôles admin §12) se fera par migrations incrémentales — jamais "plus tard".

alter table public.users          enable row level security;  -- TEMPORAIRE Phase 0 (policies de base)
alter table public.instruments    enable row level security;  -- TEMPORAIRE Phase 0
alter table public.trades         enable row level security;  -- TEMPORAIRE Phase 0
alter table public.trade_events   enable row level security;  -- TEMPORAIRE Phase 0
alter table public.trade_comments enable row level security;  -- TEMPORAIRE Phase 0
alter table public.followers      enable row level security;  -- TEMPORAIRE Phase 0
alter table public.reports        enable row level security;  -- TEMPORAIRE Phase 0
alter table public.notifications  enable row level security;  -- TEMPORAIRE Phase 0
alter table public.audit_logs     enable row level security;  -- TEMPORAIRE Phase 0 (aucune policy)

-- ---- users -------------------------------------------------------------------
create policy "users: lecture publique"
  on public.users for select
  using (true);
-- TODO Phase 1/3 : masquer les champs monétaires (capital, position size, PnL
-- absolu) pour les profils privés. is_public (colonne users) ne conditionne
-- pas la lecture de la ligne : un profil privé reste visible (pseudo/bio/
-- activité) — seuls les chiffres sont masqués via une vue dédiée ou logique
-- API. À ne PAS traiter en Phase 0.

create policy "users: création de son propre profil"
  on public.users for insert
  with check (auth.uid() = id);

create policy "users: modification de son propre profil"
  on public.users for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- ---- instruments ---------------------------------------------------------------
create policy "instruments: lecture publique"
  on public.instruments for select
  using (true);

create policy "instruments: création par utilisateur authentifié"
  on public.instruments for insert
  with check (auth.uid() is not null);

-- ---- trades --------------------------------------------------------------------
create policy "trades: lecture (publics ou propriétaire)"
  on public.trades for select
  using (is_public or auth.uid() = user_id);

create policy "trades: création par le propriétaire"
  on public.trades for insert
  with check (auth.uid() = user_id);

create policy "trades: modification par le propriétaire"
  on public.trades for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "trades: suppression de ses brouillons uniquement"
  on public.trades for delete
  using (auth.uid() = user_id and status = 'draft');

-- ---- trade_events ----------------------------------------------------------------
create policy "trade_events: lecture si le trade est lisible"
  on public.trade_events for select
  using (
    exists (
      select 1 from public.trades t
      where t.id = trade_id
        and (t.is_public or t.user_id = auth.uid())
    )
  );

create policy "trade_events: insertion par le propriétaire du trade"
  on public.trade_events for insert
  with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.trades t
      where t.id = trade_id and t.user_id = auth.uid()
    )
  );

-- (aucune policy UPDATE/DELETE : immuable, cf. triggers)

-- ---- trade_comments --------------------------------------------------------------
create policy "trade_comments: lecture si le trade est lisible"
  on public.trade_comments for select
  using (
    deleted_at is null
    and exists (
      select 1 from public.trades t
      where t.id = trade_id
        and (t.is_public or t.user_id = auth.uid())
    )
  );

create policy "trade_comments: création par utilisateur authentifié"
  on public.trade_comments for insert
  with check (auth.uid() = user_id);

create policy "trade_comments: modification par l'auteur"
  on public.trade_comments for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- (aucune policy DELETE : la suppression effective est INTERDITE côté API, même
-- par l'auteur. Le retrait d'un commentaire passe par soft-delete (deleted_at,
-- cf. ligne de table ci-dessus) pour préserver la cohérence des fils de
-- discussion et permettre la modération §12. Effacement réel = service_role
-- uniquement, via procédure dédiée Phase 8.)

-- ---- followers ---------------------------------------------------------------------
create policy "followers: lecture publique"
  on public.followers for select
  using (true);

create policy "followers: follow par soi-même"
  on public.followers for insert
  with check (auth.uid() = follower_id);

create policy "followers: unfollow par soi-même"
  on public.followers for delete
  using (auth.uid() = follower_id);

-- ---- reports ------------------------------------------------------------------------
create policy "reports: création par utilisateur authentifié"
  on public.reports for insert
  with check (auth.uid() = reporter_id);

create policy "reports: lecture de ses propres signalements"
  on public.reports for select
  using (auth.uid() = reporter_id);

-- (la revue des signalements se fera via service_role / rôle admin — Phase 7)

-- ---- notifications ---------------------------------------------------------------------
create policy "notifications: lecture des siennes uniquement"
  on public.notifications for select
  using (auth.uid() = user_id);

create policy "notifications: marquage lue par le destinataire"
  on public.notifications for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- (insertion via service_role / triggers serveur — pas de policy INSERT client)

-- ---- audit_logs --------------------------------------------------------------------------
-- Aucune policy : table inaccessible aux rôles anon/authenticated.
-- Lecture/écriture exclusivement via service_role (bypass RLS).

commit;
