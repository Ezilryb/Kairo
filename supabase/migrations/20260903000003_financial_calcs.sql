-- /supabase/migrations/20260903000003_financial_calcs.sql
-- =============================================================================
-- Phase 3 — Calculs Financiers : moteur de calcul (PnL brut/net, rendement,
-- R-multiple, winrate, profit factor, expectancy, max drawdown).
--
-- JUSTIFICATION DU CALCUL CÔTÉ DB (consigne du cadrage, whitepaper §09) :
-- les métriques affichées sur les profils publics (Rendement, R, Winrate,
-- Profit Factor, etc.) NE PEUVENT PAS être calculées côté client. Si
-- c'était le cas, un utilisateur pourrait trafiquer ses stats affichées
-- en interceptant la requête, en modifiant les valeurs retournées, ou
-- simplement en faisant ses propres calculs sur des données partielles.
-- Source de vérité = DB, systématiquement. L'UI ne fait que consommer
-- le résultat des fonctions SQL.
--
-- DEUX FAMILLES DE FONCTIONS :
--
--   1. Fonctions par trade (prennent un row de trades) :
--      - _direction_multiplier(p_direction) : +1 pour long, -1 pour short
--      - pnl_gross(p_trade) : (exit - entry) * quantity * direction
--      - pnl_net(p_trade) : pnl_gross - fees - slippage
--      - rendement_pct(p_trade) : pnl_net / capital * 100
--      - r_multiple(p_trade) : pnl_net / risk_amount
--      Toutes retournent NULL tant que exit_price est NULL (trade non
--      clôturé, ou trade live sans sortie). Le calcul est sur le trade
--      TOTAL, pas sur une sortie partielle individuelle (le PnL d'une
--      sortie partielle se cumule avec celui du trade complet — voir
--      la note sur le modèle de PnL ci-dessous).
--
--   2. Fonctions agrégées par user (prennent un user_id) :
--      - winrate(p_user_id) : % de trades gagnants parmi les closed
--      - profit_factor(p_user_id) : sum(gains) / |sum(pertes)|
--      - expectancy(p_user_id) : winrate * avg_win + (1-winrate) * avg_loss
--      - max_drawdown(p_user_id) : pire drawdown sur l'equity curve
--      Filtre status = 'closed' et optionnellement un p_since pour
--      borner dans le temps.
--
-- SÉCURITÉ : SECURITY INVOKER partout. La RLS sur trades s'applique
-- automatiquement — un user qui appelle winrate(target_user_id) ne
-- verra que les trades visibles (ses propres + publics de l'autre).
-- Pour son propre user_id, RLS laisse passer tous ses trades (privés
-- inclus) et le calcul est exact. C'est la sémantique §09 voulue :
-- "private = stats masquées pour les autres".
--
-- MODÈLE DE PnL : le PnL est calculé sur le trade TOTAL (entry_price
-- d'origine, exit_price final, quantity finale). Les sorties partielles
-- successives réduisent la quantity et le capital restants, mais le
-- PnL "réalisé" à chaque sortie partielle n'est PAS calculé ici —
-- c'est une vue métier qui viendra quand on aura besoin de la courbe
-- d'equity intratrade (probablement Phase 4 analytics). Pour l'instant,
-- exit_price représente la dernière sortie connue et le PnL est calculé
-- comme si c'était une sortie unique. Le trade est un instantané.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- Helpers internes
-- -----------------------------------------------------------------------------
-- Privé au schéma public (préfixe _), pas destiné à être appelé
-- directement par l'UI ou les RPC. Sert juste à factoriser la logique
-- du signe de direction dans pnl_gross / r_multiple.

create or replace function public._direction_multiplier(p_direction public.trade_direction)
returns integer
language sql
immutable
as $$
  select case p_direction
    when 'long'  then 1
    when 'short' then -1
  end
$$;

comment on function public._direction_multiplier(public.trade_direction) is
  'Helper interne : retourne +1 pour long, -1 pour short. Immutable, pas d''accès DB.';


-- -----------------------------------------------------------------------------
-- 1. pnl_gross(trade)
-- -----------------------------------------------------------------------------
-- PnL brut = (exit_price - entry_price) * quantity * direction_multiplier.
-- Pour un long qui sort au-dessus de l'entrée → positif. Pour un long
-- qui sort en dessous → négatif. Inversé pour un short.
--
-- Retourne NULL si :
--   - exit_price est NULL (trade pas encore clôturé, ou trade live
--     sans sortie enregistrée)
--   - status <> 'closed' (un trade live/forgotten/etc. n'a pas de
--     PnL final, son capital et quantity sont en cours)
-- Le NULL est important : il distingue "pas de données" de "0".
-- AVG(pnl_gross) doit ignorer les NULL (et c'est le comportement par
-- défaut de AVG en SQL).
create or replace function public.pnl_gross(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when p_trade.exit_price is null or p_trade.status <> 'closed' then null
    else (p_trade.exit_price - p_trade.entry_price)
         * p_trade.quantity
         * public._direction_multiplier(p_trade.direction)
  end
$$;

comment on function public.pnl_gross(public.trades) is
  'PnL brut d''un trade closed. (exit - entry) * quantity * signe(direction). NULL si non closed ou exit_price manquant.';


-- -----------------------------------------------------------------------------
-- 2. pnl_net(trade) = pnl_gross - fees - slippage
-- -----------------------------------------------------------------------------
-- fees et slippage sont nullable (l'utilisateur peut ne pas les avoir
-- saisis). On utilise coalesce(..., 0) : un trade sans fees/slippage
-- saisie a un PnL net égal au PnL brut. Pas de pénalité "frais
-- inconnu estimé à 0" — c'est l'utilisateur qui décide en saisissant
-- trades.fees.
create or replace function public.pnl_net(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when public.pnl_gross(p_trade) is null then null
    else public.pnl_gross(p_trade)
         - coalesce(p_trade.fees, 0)
         - coalesce(p_trade.slippage, 0)
  end
$$;

comment on function public.pnl_net(public.trades) is
  'PnL net = PnL brut - fees - slippage. NULL si PnL brut NULL. fees/slippage nullables traités comme 0 (l''utilisateur n''a pas saisi de correction).';


-- -----------------------------------------------------------------------------
-- 3. rendement_pct(trade) = pnl_net / capital * 100
-- -----------------------------------------------------------------------------
-- Rendement en pourcentage par rapport au capital engagé initial. NULL
-- si pnl_net NULL (non closed) ou capital = 0 (ne devrait pas arriver
-- en pratique — CHECK constraint entry_price > 0 et capital >= 0 en
-- Phase 0, mais on reste défensif).
create or replace function public.rendement_pct(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  select case
    when public.pnl_net(p_trade) is null or p_trade.capital = 0 then null
    else (public.pnl_net(p_trade) / p_trade.capital) * 100
  end
$$;

comment on function public.rendement_pct(public.trades) is
  'Rendement en % par rapport au capital engagé. pnl_net / capital * 100. NULL si non closed ou capital = 0.';


-- -----------------------------------------------------------------------------
-- 4. r_multiple(trade) = pnl_net / risk_amount
-- -----------------------------------------------------------------------------
-- R-multiple : PnL net divisé par le risque initial. Standard :
--   - Si stop_loss défini : risk = |entry - stop_loss| * quantity
--   - Sinon, si risk_percent défini : risk = risk_percent/100 * capital
--   - Sinon : risk = NULL → r_multiple = NULL
--
-- Le R-multiple est la métrique之首 du trading discipliné (whitepaper
-- §07) : il normalise la performance par le risque pris, ce qui
-- permet de comparer deux trades de tailles différentes. Un trade
-- +1R a gagné exactement son risque initial, +2R a gagné 2x le
-- risque, -1R a perdu son risque.
create or replace function public.r_multiple(p_trade public.trades)
returns numeric
language sql
stable
security invoker
as $$
  with risk as (
    select case
      when p_trade.stop_loss is not null then
        abs(p_trade.entry_price - p_trade.stop_loss) * p_trade.quantity
      when p_trade.risk_percent is not null then
        (p_trade.risk_percent / 100.0) * p_trade.capital
      else
        null
    end as amount
  )
  select case
    when public.pnl_net(p_trade) is null then null
    when (select amount from risk) is null or (select amount from risk) = 0 then null
    else public.pnl_net(p_trade) / (select amount from risk)
  end
$$;

comment on function public.r_multiple(public.trades) is
  'R-multiple = pnl_net / risk_amount. risk = |entry - stop_loss| * quantity, sinon risk_percent/100 * capital. NULL si pas de stop_loss ni risk_percent, ou si pnl_net NULL.';


-- -----------------------------------------------------------------------------
-- 5. winrate(user_id) — % de trades gagnants parmi les closed
-- -----------------------------------------------------------------------------
-- Un trade est gagnant si pnl_net > 0. Le winrate est le ratio
-- wins / total * 100, en pourcentage.
--
-- p_since : optionnel, permet de borner dans le temps (ex: "winrate
-- sur les 90 derniers jours"). NULL = depuis toujours.
--
-- NULL si aucun trade closed (pas de division par 0).
create or replace function public.winrate(p_user_id uuid, p_since timestamptz default null)
returns numeric
language sql
stable
security invoker
as $$
  with closed as (
    select public.pnl_net(t.*) as net
    from public.trades t
    where t.user_id = p_user_id
      and t.status = 'closed'
      and (p_since is null or t.closed_at >= p_since)
  ),
  totals as (
    select
      count(*) as total,
      count(*) filter (where net > 0) as wins
    from closed
  )
  select case
    when total = 0 then null
    else (wins::numeric / total::numeric) * 100
  end
  from totals
$$;

comment on function public.winrate(uuid, timestamptz) is
  'Winrate (% de trades gagnants) parmi les trades closed de l''utilisateur, optionnellement depuis p_since. NULL si aucun trade closed.';


-- -----------------------------------------------------------------------------
-- 6. profit_factor(user_id)
-- -----------------------------------------------------------------------------
-- Profit factor = sum(pnl_net > 0) / abs(sum(pnl_net < 0)).
-- Standard du trading : > 1 = profitable, < 1 = perdant, = 1 = break-even.
--
-- NULL si pas de trade perdant (que des gagnants, ou aucun trade
-- closed) — éviter la division par 0.
create or replace function public.profit_factor(p_user_id uuid, p_since timestamptz default null)
returns numeric
language sql
stable
security invoker
as $$
  with closed as (
    select public.pnl_net(t.*) as net
    from public.trades t
    where t.user_id = p_user_id
      and t.status = 'closed'
      and (p_since is null or t.closed_at >= p_since)
  ),
  sums as (
    select
      coalesce(sum(net) filter (where net > 0), 0) as gross_profit,
      coalesce(abs(sum(net)) filter (where net < 0), 0) as gross_loss
    from closed
  )
  select case
    when gross_loss = 0 then null
    else gross_profit / gross_loss
  end
  from sums
$$;

comment on function public.profit_factor(uuid, timestamptz) is
  'Profit factor = sum(gains) / |sum(pertes)| parmi les closed. NULL si pas de trade perdant. > 1 profitable, < 1 perdant.';


-- -----------------------------------------------------------------------------
-- 7. expectancy(user_id)
-- -----------------------------------------------------------------------------
-- Expectancy = winrate * avg_win + (1 - winrate) * avg_loss.
-- Métrique en valeur absolue (par trade, dans la devise de l'user).
--
-- Cas limites gérés :
--   - Que des gagnants (avg_loss = null) : expectancy = avg_win
--     (logique : tous les trades gagnent la moyenne)
--   - Que des perdants (avg_win = null) : expectancy = avg_loss
--     (logique : tous les trades perdent la moyenne, qui est négative)
--   - Aucun trade : null
create or replace function public.expectancy(p_user_id uuid, p_since timestamptz default null)
returns numeric
language sql
stable
security invoker
as $$
  with closed as (
    select public.pnl_net(t.*) as net
    from public.trades t
    where t.user_id = p_user_id
      and t.status = 'closed'
      and (p_since is null or t.closed_at >= p_since)
  ),
  stats as (
    select
      avg(net) filter (where net > 0) as avg_win,
      avg(net) filter (where net < 0) as avg_loss,
      count(*) filter (where net > 0)::numeric as wins,
      count(*)::numeric as total
    from closed
  )
  select case
    when total = 0 then null
    when avg_loss is null then avg_win
    when avg_win is null then avg_loss
    else (wins / total) * avg_win + ((total - wins) / total) * avg_loss
  end
  from stats
$$;

comment on function public.expectancy(uuid, timestamptz) is
  'Expectancy = winrate * avg_win + (1 - winrate) * avg_loss, par trade closed. NULL si aucun trade.';


-- -----------------------------------------------------------------------------
-- 8. max_drawdown(user_id)
-- -----------------------------------------------------------------------------
-- Max drawdown = la pire perte depuis un pic d'equity sur l'equity
-- curve construite à partir des pnl_net des trades closed, triés par
-- closed_at.
--
-- Algorithme :
--   1. Calcule l'equity cumulée (running sum de pnl_net) triée par
--      closed_at. C'est la courbe d'equity.
--   2. Calcule le peak (max glissant de l'equity) à chaque instant.
--   3. drawdown = peak - equity (toujours >= 0 par construction, le
--      peak est forcément >= equity courante).
--   4. max_drawdown = max(drawdown) sur toute la courbe.
--
-- NULL si aucun trade closed.
--
-- Note : c'est un max drawdown absolu, pas en %. Un max drawdown de
-- 500 signifie qu'à un moment, l'equity était 500 unités en-dessous
-- du pic. Pour un max drawdown en %, diviser par le peak — c'est une
-- autre métrique qu'on ajoutera si besoin.
create or replace function public.max_drawdown(p_user_id uuid, p_since timestamptz default null)
returns numeric
language sql
stable
security invoker
as $$
  with closed as (
    select t.closed_at, public.pnl_net(t.*) as net
    from public.trades t
    where t.user_id = p_user_id
      and t.status = 'closed'
      and (p_since is null or t.closed_at >= p_since)
    order by t.closed_at
  ),
  running as (
    select
      closed_at,
      net,
      sum(net) over (
        order by closed_at
        rows between unbounded preceding and current row
      ) as equity
    from closed
  ),
  with_peak as (
    select
      equity,
      max(equity) over (
        order by closed_at
        rows between unbounded preceding and current row
      ) as peak
    from running
  )
  select max(peak - equity)
  from with_peak
$$;

comment on function public.max_drawdown(uuid, timestamptz) is
  'Max drawdown absolu sur l''equity curve (trades closed triés par closed_at). NULL si aucun trade closed. C''est une valeur absolue (devise de l''user), pas un pourcentage.';


-- -----------------------------------------------------------------------------
-- MAE / MFE : rappels
-- -----------------------------------------------------------------------------
-- Les colonnes mae / mfe existent sur trades (migration 01) mais
-- restent NULL tant que le MarketDataProvider (Phase 5) n'est pas
-- livré. On NE crée PAS de fonctions mae(trade) / mfe(trade) ici :
-- elles n'auraient aucun sens sans données de bougies. Quand la
-- Phase 5 livrera le provider, on ajoutera une migration qui :
--   1. Définira les fonctions mae(trade) / mfe(trade) basées sur
--      l'historique de bougies (probablement via une table bougies
--      partitionnée).
--   2. Backfillera les colonnes pour les trades existants.
--   3. Déclenchera un recalcul incrémental à chaque bougie clôturée.
-- Pour l'instant, on documente le rappel ici et on s'arrête là — pas
-- de fonction qui mentirait avec une valeur par défaut.

commit;
