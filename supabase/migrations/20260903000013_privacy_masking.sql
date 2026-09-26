-- /supabase/migrations/20260903000013_privacy_masking.sql
-- =============================================================================
-- Phase 6 — Réseau Social (whitepaper §03 + §09)
-- Masquage confidentialité (3 fonctions SECURITY INVOKER).
--
-- CONTEXTE :
-- Le whitepaper §09 distingue 6 niveaux de visibilité par champ d'un trade
-- publié, et le commentaire de policy "users: lecture publique" de la
-- migration initiale 0001 dit explicitement :
--   "TODO Phase 1/3 : masquer les champs monétaires (capital, position size,
--   PnL absolu) pour les profils privés [...] seuls les chiffres sont
--   masqués via une vue dédiée ou logique API."
-- Ni Phase 1 ni Phase 3 ne l'ont fait. Cette migration l'implémente.
--
-- DEUX FLAGS is_public DISTINCTS — NE PAS CONFONDRE :
--   - trades.is_public : filtre déjà appliqué par la RLS de trades (policy
--     "trades: lecture (publics ou propriétaire)"). Gère si LA LIGNE du
--     trade est visible DU TOUT.
--   - users.is_public : stocké mais jamais utilisé jusque-là. C'est lui
--     qui conditionne le masquage de CERTAINS CHAMPS sur une ligne par
--     ailleurs visible. C'est ce qu'on câble ici.
--
-- WHITE PAPER §09 — Champs toujours visibles (même profil privé) :
--   - Rendement (%, R), Winrate
--   - Historique des Trades (la liste elle-même)
-- → Pas de fonction de masquage pour rendement_pct, r_multiple. Ils restent
-- tels quels.
--
-- WHITE PAPER §09 — Champs masqués pour profil privé :
--   - Capital Réel Investi (= initial_capital) → trade_visible_capital
--   - Taille des Positions (= initial_quantity)  → trade_visible_quantity
--   - PnL Absolu (Monétaire) (= pnl_net)        → trade_visible_pnl_absolute
--
-- LOGIQUE DE MASQUAGE (identique pour les 3 fonctions) :
--   - Si l'appelant est le propriétaire du trade → retourne la vraie valeur
--     (le proprio voit TOUJOURS ses vrais chiffres, même s'il a rendu son
--     profil privé — sinon il ne pourrait pas se rendre compte lui-même
--     qu'il a un profil privé).
--   - Si l'appelant n'est PAS le proprio :
--       - Si users.is_public du proprio = true → retourne la vraie valeur
--       - Si users.is_public du proprio = false → retourne NULL
--
-- CHOIX DES COLONNES SOURCE (initial_* plutôt que current) :
-- Le whitepaper parle de "Capital Réel Investi" et "Taille des Positions" :
-- c'est le montant réellement engagé à l'entrée, pas l'état intermédiaire
-- post-sorties-partielles (capital/quantity restants). initial_capital et
-- initial_quantity sont snapshotés à la publication par publish_trade
-- (migration 004) — référence stable pour le risque et la taille.
--
-- PATTERN : SECURITY INVOKER partout (cf. Phase 3 fonctions financières).
-- La RLS de trades s'applique automatiquement : un user qui ne peut pas
-- SELECT un trade ne peut pas non plus appeler ces fonctions dessus de
-- façon utile (la fonction accède à p_trade qui est passé en argument —
-- mais le contexte d'appel filtre via RLS en amont si on l'appelle depuis
-- un SELECT de trades).
--
-- Note : p_trade est passé en argument (pas SELECT depuis trades dans la
-- fonction) → la RLS ne s'applique PAS dans le corps de la fonction, elle
-- s'applique en amont au point d'appel. C'est exactement le pattern Phase 3
-- pour pnl_gross/pnl_net/rendement_pct/r_multiple.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. trade_visible_capital(trade)
-- -----------------------------------------------------------------------------
-- Retourne initial_capital si l'appelant est le proprio OU si le proprio
-- a un profil public, sinon NULL.
create or replace function public.trade_visible_capital(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when p_trade.user_id = auth.uid() then p_trade.initial_capital
    when exists (
      select 1 from public.users u
      where u.id = p_trade.user_id and u.is_public
    ) then p_trade.initial_capital
    else null
  end
$$;

comment on function public.trade_visible_capital(public.trades) is
  'Masquage whitepaper §09 : retourne initial_capital si le caller est le proprio du trade OU si users.is_public du proprio = true, sinon NULL. Pattern SECURITY INVOKER, suit la même logique que pnl_gross / pnl_net (Phase 3).';


-- -----------------------------------------------------------------------------
-- 2. trade_visible_quantity(trade)
-- -----------------------------------------------------------------------------
-- Retourne initial_quantity si l'appelant est le proprio OU si le proprio
-- a un profil public, sinon NULL. Taille des Positions engagée à l'entrée.
create or replace function public.trade_visible_quantity(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when p_trade.user_id = auth.uid() then p_trade.initial_quantity
    when exists (
      select 1 from public.users u
      where u.id = p_trade.user_id and u.is_public
    ) then p_trade.initial_quantity
    else null
  end
$$;

comment on function public.trade_visible_quantity(public.trades) is
  'Masquage whitepaper §09 : retourne initial_quantity (taille engagée à l''entrée, pas la quantity restante post-sorties-partielles) si le caller est le proprio OU si users.is_public du proprio = true, sinon NULL.';


-- -----------------------------------------------------------------------------
-- 3. trade_visible_pnl_absolute(trade)
-- -----------------------------------------------------------------------------
-- Retourne pnl_net(p_trade) si l'appelant est le proprio OU si le proprio
-- a un profil public, sinon NULL. pnl_net est NULL si le trade n'est pas
-- clôturé (sémantique déjà en place depuis Phase 3, on la propage).
create or replace function public.trade_visible_pnl_absolute(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when p_trade.user_id = auth.uid() then public.pnl_net(p_trade)
    when exists (
      select 1 from public.users u
      where u.id = p_trade.user_id and u.is_public
    ) then public.pnl_net(p_trade)
    else null
  end
$$;

comment on function public.trade_visible_pnl_absolute(public.trades) is
  'Masquage whitepaper §09 : retourne pnl_net(p_trade) si le caller est le proprio OU si users.is_public du proprio = true, sinon NULL. NULL propagé si le trade n''est pas closed (cohérent avec pnl_net).';

commit;
