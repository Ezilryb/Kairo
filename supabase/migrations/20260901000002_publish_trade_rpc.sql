-- /supabase/migrations/20260901000002_publish_trade_rpc.sql
-- =============================================================================
-- Phase 2 — Point C/D : RPC publish_trade pour pose de published_at /
-- opened_at côté base.
--
-- Contexte : le trade-publish-button client posait les timestamps via
-- `new Date().toISOString()` avant l'UPDATE. Si l'horloge du navigateur
-- de l'utilisateur est mal réglée (VM, dérive NTP, mauvais fuseau), le
-- timestamp est décalé par rapport à now() côté DB — au-delà du simple
-- "décalage de quelques ms" initialement évalué, on peut parler de
-- minutes. Et ce `published_at` est la référence de TOUTE la logique
-- 60 s qu'on vient de construire sur deux migrations
-- (enforce_entry_price_immutability, enforce_sl_tp_immutability). Si
-- published_at est artificiellement daté dans le passé par rapport à
-- l'horloge DB, la fenêtre peut être considérée comme expirée au
-- moment même de la publication, et l'utilisateur ne voit jamais ses
-- 60 secondes — bug qu'on ne verrait qu'en prod, sur la machine d'un
-- vrai utilisateur.
--
-- Le fix : RPC SECURITY INVOKER (pas SECURITY DEFINER — on n'a pas
-- besoin de contourner la RLS, juste que `now()` soit évalué dans la
-- base, pas envoyé depuis le client). La policy RLS UPDATE
-- ("auth.uid() = user_id") s'applique normalement via les droits de
-- l'appelant, le filtre `user_id = auth.uid()` dans le WHERE est
-- redondant avec la RLS mais explicite (cohérence avec le pattern
-- défense en profondeur appliqué partout).
--
-- Idempotence : la fonction ne fait rien si le trade n'est pas en
-- draft (le WHERE filtre status = 'draft'), et lève une exception
-- explicite si l'UPDATE n'a touché aucune ligne. Le caller
-- (trade-publish-button) distingue les deux cas via updateError.message.
-- Effet de bord utile : empêche la "republication" d'un trade déjà
-- live pour reset la fenêtre 60 s (un UPDATE avec status = 'live' sur
-- une ligne déjà 'live' ne touche rien, l'exception remonte).
-- =============================================================================

create or replace function public.publish_trade(p_trade_id uuid)
returns public.trades
language plpgsql
as $$
declare
  v_trade public.trades;
begin
  update public.trades
  set status = 'live', published_at = now(), opened_at = now()
  where id = p_trade_id
    and user_id = auth.uid()
    and status = 'draft'
  returning * into v_trade;

  if v_trade.id is null then
    raise exception
      'Trade introuvable, déjà publié, ou non autorisé';
  end if;

  return v_trade;
end $$;
