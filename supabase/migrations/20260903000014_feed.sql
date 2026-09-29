-- /supabase/migrations/20260903000014_feed.sql
-- =============================================================================
-- Phase 6 — Réseau Social (whitepaper §03 + §09)
-- Fonction get_feed : feed personnalisé des trades publics des users suivis.
--
-- Cadrage chef (Phase 6 brief) :
--   - Trades publics (trades.is_public = true) des users suivis par
--     p_user_id (jointure sur followers).
--   - Triés par published_at décroissant (le moment où un trade devient
--     visible socialement — pas closed_at, on veut un feed de publications,
--     pas de clôtures).
--   - Pagination par curseur (p_before) plutôt qu'offset, pour éviter
--     doublons/trous si de nouveaux trades arrivent pendant le scroll.
--   - Applique trade_visible_capital/_quantity/_pnl_absolute sur chaque
--     ligne (cf. migration 013) — le feed est justement l'endroit où le
--     masquage compte le plus (un user qui followe un profil privé ne
--     verra pas les chiffres masqués).
--   - SECURITY INVOKER, RLS de trades s'applique en plus (defense in
--     depth habituelle du projet).
--
-- COLONNES DU RETOUR (jeu raisonnable pour une carte de feed social) :
--   - Identité du trade         : trade_id
--   - Identité du propriétaire  : owner_pseudo, owner_avatar_url
--   - Contenu                   : symbol, direction, asset_class
--   - Métriques toujours        : rendement_pct, r_multiple (whitepaper §09
--                                 : visibles même profil privé)
--   - Métriques masquables      : capital_visible, quantity_visible,
--                                 pnl_net_visible (NULL si profil privé)
--   - Engagement                : like_count, comment_count (COUNT(*)
--                                 à la demande — pas de colonne
--                                 dénormalisée pour ce MVP)
--   - Tri / pagination          : published_at
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- get_feed
-- -----------------------------------------------------------------------------
-- p_user_id : UUID du user dont on veut le feed. Doit correspondre à
--             auth.uid() (sinon raise — un user ne peut demander que son
--             propre feed).
-- p_before  : Curseur de pagination. Trades avec published_at < p_before.
--             NULL = première page (les plus récents).
-- p_limit   : Nombre max de trades retournés. Default 20. On clamp à ≥1
--             via greatest(p_limit, 1) — p_limit=0 ne retournerait rien
--             et p_limit<0 ferait planter LIMIT.
--
-- Le check p_user_id = auth.uid() est explicite (pas juste "RLS fait son
-- travail"). Raison : la CTE filtre déjà via EXISTS sur followers, donc un
-- user qui passerait un autre user_id recevrait silencieusement un feed
-- vide — bug d'utilisation difficile à détecter. Le raise explicite
-- remontre le problème à l'appelant dès le dev.
--
-- STABLE (pas IMMUTABLE) : la fonction accède à auth.uid() (volatile par
-- nature) et à plusieurs tables — STABLE est l'option correcte pour une
-- fonction SELECT-only dans une seule requête.
create or replace function public.get_feed(
  p_user_id uuid,
  p_before timestamptz default null,
  p_limit   int default 20
)
returns table (
  trade_id         uuid,
  owner_pseudo     text,
  owner_avatar_url text,
  symbol           text,
  direction        public.trade_direction,
  asset_class      public.asset_class,
  capital_visible  numeric,
  quantity_visible numeric,
  pnl_net_visible  numeric,
  rendement_pct    numeric,
  r_multiple       numeric,
  like_count       bigint,
  comment_count    bigint,
  published_at     timestamptz
)
language plpgsql
stable
security invoker
as $$
begin
  if p_user_id is distinct from auth.uid() then
    raise exception
      'get_feed: p_user_id (%) ne correspond pas à auth.uid() (%)',
      p_user_id, auth.uid();
  end if;

  return query
    select
      t.id,
      u.pseudo,
      u.avatar_url,
      i.symbol,
      t.direction,
      i.asset_class,
      public.trade_visible_capital(t.*),
      public.trade_visible_quantity(t.*),
      public.trade_visible_pnl_absolute(t.*),
      public.rendement_pct(t.*),
      public.r_multiple(t.*),
      (select count(*) from public.likes l where l.trade_id = t.id),
      (select count(*) from public.trade_comments c
         where c.trade_id = t.id and c.deleted_at is null),
      t.published_at
    from public.trades t
    join public.users u       on u.id = t.user_id
    join public.instruments i on i.id = t.instrument_id
    where t.is_public = true
      and t.published_at is not null
      and exists (
        select 1 from public.followers f
        where f.follower_id = p_user_id
          and f.followee_id = t.user_id
      )
      and (p_before is null or t.published_at < p_before)
    order by t.published_at desc
    limit greatest(p_limit, 1);
end $$;
comment on function public.get_feed(uuid, timestamptz, int) is
  'Feed personnalisé : trades publics (trades.is_public = true) des users suivis, triés par published_at décroissant. Pagination par curseur (p_before). Applique le masquage §09 via trade_visible_capital/_quantity/_pnl_absolute. SECURITY INVOKER, p_user_id doit correspondre à auth.uid() sinon raise.';

commit;
