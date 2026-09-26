-- /supabase/migrations/20260903000012_likes.sql
-- =============================================================================
-- Phase 6 — Réseau Social (whitepaper §03 + §09)
-- Table likes (manquante depuis Phase 0 — followers et trade_comments créés,
-- likes absents alors que le whitepaper §03 cite "Feed, followers, likes,
-- commentaires").
--
-- Cadrage chef (Phase 6 brief) :
--   - Pas de colonne dénormalisée like_count sur trades pour ce MVP. Même
--     réflexe que "pas de cache de bougies préventif" Phase 5 : COUNT(*)
--     suffit à l'échelle actuelle, on dénormalisera seulement si ça devient
--     un problème réel mesuré.
--   - Pas de like sur les commentaires pour ce MVP (whitepaper ne le mentionne
--     pas, on reste au périmètre décrit).
--   - UNIQUE (trade_id, user_id) : un user ne peut liker un trade qu'une fois
--     (cf. UX standard des feeds sociaux).
--
-- RLS (mêmes prédicats que trade_comments pour la lecture, cf. migration
-- initiale 0001) :
--   - SELECT : lecture si le trade est lisible (EXISTS sur trades où le
--     trade est public OU appartient au caller). Les likes suivent la
--     visibilité du trade sous-jacent, pas du liker.
--   - INSERT : auth.uid() = user_id (like par soi-même uniquement). On ne
--     peut pas liker "au nom de" quelqu'un d'autre. Couvre aussi le cas
--     "le trade doit être lisible" via une sous-requête EXISTS — pas la
--     peine d'être créatif, on s'appuie sur la RLS de trades (un user qui
--     ne peut pas SELECT un trade ne peut pas non plus INSERT un like
--     dessus, via la FK trade_id + l'EXISTS dans la policy INSERT).
--   - DELETE : auth.uid() = user_id (unlike par soi-même uniquement).
--
-- Note : la contrainte FK trade_id → trades(id) ON DELETE CASCADE propage
-- la suppression d'un trade à ses likes, idem pour user_id → users(id).
-- Donc la suppression d'un user ou d'un trade nettoie automatiquement
-- les likes associés, sans trigger supplémentaire.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- Table
-- -----------------------------------------------------------------------------
create table public.likes (
  id          uuid primary key default gen_random_uuid(),
  trade_id    uuid not null references public.trades (id) on delete cascade,
  user_id     uuid not null references public.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (trade_id, user_id)
);

comment on table public.likes is
  'Likes des utilisateurs sur les trades publiés (Phase 6 Réseau Social). UNIQUE (trade_id, user_id) — un user ne peut liker un trade qu''une fois. CASCADE sur trade/user pour nettoyage automatique.';

create index likes_trade_id_idx on public.likes (trade_id);
create index likes_user_id_idx  on public.likes (user_id);

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.likes enable row level security;

-- Lecture : un like est visible si le trade sous-jacent est lisible.
-- Pattern identique à trade_comments (cf. migration initiale 0001).
create policy "likes: lecture si le trade est lisible"
  on public.likes for select
  using (
    exists (
      select 1 from public.trades t
      where t.id = trade_id
        and (t.is_public or t.user_id = auth.uid())
    )
  );

-- Insert : like par soi-même, et le trade sous-jacent doit être lisible
-- (sous-requête EXISTS — sinon on pourrait liker un trade privé d'un autre
-- user en bypassant la policy SELECT de trades via INSERT direct).
create policy "likes: insertion par soi-même, trade lisible"
  on public.likes for insert
  with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.trades t
      where t.id = trade_id
        and (t.is_public or t.user_id = auth.uid())
    )
  );

-- Delete : unlike par soi-même uniquement.
create policy "likes: suppression par soi-même (unlike)"
  on public.likes for delete
  using (auth.uid() = user_id);

-- (aucune policy UPDATE : un like est immuable. Pour le retirer, on DELETE
-- et on re-INSERT si on change d'avis. Évite les UPDATE silencieux qui
-- modifieraient la sémantique "qui a liké quoi et quand".)

commit;
