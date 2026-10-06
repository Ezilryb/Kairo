// /app/(dashboard)/page.tsx
// =============================================================================
// Dashboard — branchement sur données réelles (Phase 10 / Dashboard).
// =============================================================================
// Cette page est désormais un server component async qui lit les KPIs
// financiers de l'utilisateur connecté via les RPCs SECURITY INVOKER de la
// migration 021. Plus aucune donnée mockée — c'était l'item A4 de l'audit
// visuel Phase 9 (footer "Phase 0 · données mockées" + chiffres en dur).
//
// Sémantique des KPIs (cohérente avec la maquette Phase 0, mais câblée
// sur la réalité) :
//   - Winrate          % de trades gagnants parmi les closed, fenêtre 30 j
//   - PnL net (30 j)   somme des pnl_net des trades closed sur 30 j
//   - Trades ouverts   compte exact des trades status = 'live'
//   - Drawdown max     pire drawdown absolu en € sur l'equity curve 30 j
//   - Trades récents   5 derniers trades (toutes statuses), PnL calculé DB
//
// Pas de delta % sur les StatBlocks V1 : aucune baseline honnête
// (vs période précédente ? moyenne mobile ?). Afficher un delta inventé
// serait une métrique qui ment. Différé, à cadrer dans une phase
// dédiée.
//
// Section "Activité" du mock Phase 0 SUPPRIMÉE : pas de source de
// données (notifications / feed personnel). Différée, à cadrer dans
// une future phase.
//
// Footer "Phase X" SUPPRIMÉ : audit A4, alignement avec le reste du
// dashboard (les footers "Phase X" sont à retirer des autres pages dans
// un round dédié, hors scope ici).
// =============================================================================
import {
  Activity,
  ArrowDownRight,
  ArrowUp,
  ArrowUpRight,
  Plus,
  TrendingUp,
  Wallet,
} from "lucide-react";
import Link from "next/link";
import { Badge, type BadgeTone } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { StatBlock } from "@/components/ui/StatBlock";
import { createClient } from "@/lib/supabase/server";

// ---- Types -----------------------------------------------------------------
// Le retour de .rpc() côté Supabase JS s'aligne sur la signature RETURNS TABLE
// de la fonction SQL : numeric(24,8) arrive en `string` (perte de précision
// évitée côté JS), `public.trade_status` enum arrive en string littéral.

type TradeStatus = "draft" | "live" | "closed" | "forgotten" | "archived";
type TradeDirection = "long" | "short";
type AssetClass = "crypto" | "stock" | "forex" | "commodity" | "index" | "etf";

type RecentTrade = {
  id: string;
  status: TradeStatus;
  direction: TradeDirection;
  entry_price: string | null;
  exit_price: string | null;
  quantity: string | null;
  capital: string | null;
  closed_at: string | null;
  updated_at: string | null;
  created_at: string | null;
  instrument_id: string;
  symbol: string;
  asset_class: AssetClass;
  pnl_net: string | null;
  rendement_pct: string | null;
};

// ---- Constantes ------------------------------------------------------------

const DAY_MS = 24 * 60 * 60 * 1000;
const WINDOW_DAYS = 30;
const RECENT_TRADES_LIMIT = 5;

// ---- Helpers de présentation -----------------------------------------------

const STATUS_TONE: Record<TradeStatus, BadgeTone> = {
  // Convention UI documentée dans TODO_TECHNIQUE.md, section
  // "Conventions UI" : les badges de statut encodent le cycle de vie,
  // jamais l'issue financière. Un trade clôturé peut l'être à perte,
  // le badge ne le dit pas — c'est la valeur PnL affichée à côté qui
  // porte la couleur (success/danger). Reprise à l'identique de la
  // page détail trade pour garder la cohérence visuelle.
  draft: "neutral",
  live: "info",
  forgotten: "warning",
  closed: "neutral",
  archived: "neutral",
};

const STATUS_LABEL: Record<TradeStatus, string> = {
  draft: "Brouillon",
  live: "Live",
  forgotten: "Oublié",
  closed: "Clôturé",
  archived: "Archivé",
};

function formatPrice(
  value: string | number | null | undefined,
  assetClass: AssetClass,
): string {
  if (value === null || value === undefined) return "—";
  const v = Number(value);
  if (!Number.isFinite(v) || v === 0) return "—";
  // Forex : 5 décimales (lots standard), le reste : 2 décimales.
  // Toutes les branches passent par toLocaleString pour respecter la
  // locale française (espace pour les milliers, virgule décimale) —
  // sans ça, un forex à 1.08250 s'affiche en anglo-saxon à côté d'un
  // crypto en 62 410,50.
  if (assetClass === "forex") {
    return v.toLocaleString("fr-FR", {
      minimumFractionDigits: 5,
      maximumFractionDigits: 5,
    });
  }
  return v.toLocaleString("fr-FR", { maximumFractionDigits: 2 });
}

function formatSigned(
  value: string | number | null | undefined,
  suffix = "€",
): string {
  if (value === null || value === undefined) return "—";
  const v = Number(value);
  if (!Number.isFinite(v)) return "—";
  const sign = v > 0 ? "+" : v < 0 ? "−" : "";
  const abs = Math.abs(v);
  return `${sign}${abs.toLocaleString("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${suffix}`;
}

function formatSignedPercent(
  value: string | number | null | undefined,
): string {
  if (value === null || value === undefined) return "—";
  const v = Number(value);
  if (!Number.isFinite(v)) return "—";
  const sign = v > 0 ? "+" : v < 0 ? "−" : "";
  return `${sign}${Math.abs(v).toFixed(2)}%`;
}

function formatPercentValue(value: string | number | null | undefined): string {
  // Pour les StatBlocks (Winrate) : valeur en %, sans signe.
  if (value === null || value === undefined) return "—";
  const v = Number(value);
  if (!Number.isFinite(v)) return "—";
  return v.toFixed(1);
}

function formatCount(value: number | null | undefined): string {
  if (value === null || value === undefined) return "—";
  return String(value);
}

// ---- Page -----------------------------------------------------------------

export default async function DashboardPage() {
  const supabase = await createClient();

  // Filet de robustesse — le layout de (dashboard) garantit déjà qu'on
  // a un user ici (sinon redirect /login). Si la session a expiré entre
  // layout et render, on évite un crash en retournant un fragment vide.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  // Pseudo pour le sous-titre ("Bienvenue, {pseudo}").
  const { data: profile } = await supabase
    .from("users")
    .select("pseudo")
    .eq("id", user.id)
    .maybeSingle();

  // ISO string côté DB — la RPC attend timestamptz, Supabase sérialise
  // correctement le format ISO 8601 avec timezone.
  const sinceIso = new Date(Date.now() - WINDOW_DAYS * DAY_MS).toISOString();

  // 5 fetchs en parallèle. Promise.all fail-fast : une seule erreur
  // réseau remonte. En lecture de dashboard, on accepte le fallback
  // "—" sur les 4 KPIs si l'un des RPCs échoue — c'est un écran de
  // consultation, pas une action irréversible. `error` est volontairement
  // non géré en V1 ; on remonte à un cycle SI on observe du bruit en
  // logs navigateur (cf. TODO_TECHNIQUE.md leçons logging).
  const [
    winrateRpc,
    pnlRpc,
    drawdownRpc,
    openTradesResult,
    recentTradesRpc,
  ] = await Promise.all([
    supabase.rpc("winrate", { p_user_id: user.id, p_since: sinceIso }),
    supabase.rpc("sum_pnl", { p_user_id: user.id, p_since: sinceIso }),
    supabase.rpc("max_drawdown", { p_user_id: user.id, p_since: sinceIso }),
    supabase
      .from("trades")
      .select("id", { count: "exact", head: true })
      .eq("user_id", user.id)
      .eq("status", "live"),
    supabase.rpc("recent_trades_with_pnl", {
      p_user_id: user.id,
      p_limit: RECENT_TRADES_LIMIT,
    }),
  ]);

  // winrate / sum_pnl / max_drawdown sont des fonctions `RETURNS numeric`
  // (scalaires) — leur `data` est directement la valeur, PAS un tableau.
  // Bug V1 initial : on indexait `data[0]` comme si c'était une table
  // function ; côté Supabase JS ça retournait `undefined` systématiquement
  // et les 3 KPIs affichaient "—" en silence, alors que les vraies valeurs
  // étaient bien en base. `recent_trades_with_pnl` est `RETURNS TABLE` —
  // son `data` est bien un tableau, manipulé séparément plus bas.
  const winrateValue = winrateRpc.data as number | string | null | undefined;
  const pnlNetValue = pnlRpc.data as number | string | null | undefined;
  const drawdownValue = drawdownRpc.data as number | string | null | undefined;

  // pnl_net : tonalité dérivée du signe (success si > 0, danger si < 0,
  // neutral si 0). On ne surcharge pas StatBlock.tone ici, on laisse la
  // fonction getTone interne faire son boulot à partir du delta — sauf
  // que V1 n'a pas de delta, donc on force tone via la prop.
  const pnlNetNumber =
    pnlNetValue === null || pnlNetValue === undefined ? null : Number(pnlNetValue);
  const pnlTone =
    pnlNetNumber === null
      ? "neutral"
      : pnlNetNumber > 0
        ? "success"
        : pnlNetNumber < 0
          ? "danger"
          : "neutral";

  const recentTrades: RecentTrade[] =
    (recentTradesRpc.data ?? []) as RecentTrade[];

  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-6xl space-y-6 px-6 py-8">
        {/* Header */}
        <header className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
            <p className="mt-1 text-sm text-neutral-500">
              {profile?.pseudo
                ? `Bienvenue, ${profile.pseudo}. Voici l'état de ton journal.`
                : "Voici l'état de ton journal."}
            </p>
          </div>
          <div className="flex items-center gap-2">
            {/*
              Exporter : <a> natif (pas Next.js <Link>) parce que la cible
              est une route API qui renvoie Content-Disposition: attachment,
              forçant le navigateur à télécharger le JSON. <Link> sert aux
              transitions client-side entre pages Next.js, ce qui n'a pas
              de sens ici. Les cookies de session Supabase sont envoyés
              automatiquement par le navigateur sur cette navigation, le
              serveur vérifie getUser() côté route et force le bon filename
              via le header.
              Pattern <a><Button> identique à <Link><Button> rendu DOM
              (cf. trades/[id]/page.tsx:267), cohérent avec le reste du
              projet.
            */}
            <a href="/api/account/export">
              <Button variant="secondary">Exporter</Button>
            </a>
            <Link href="/trades/new">
              <Button variant="primary">
                <Plus className="h-4 w-4" aria-hidden />
                Nouveau trade
              </Button>
            </Link>
          </div>
        </header>

        {/* Stats principales */}
        <section className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <Card>
            <StatBlock
              label="Winrate"
              value={formatPercentValue(winrateValue)}
              unit="%"
              icon={<Activity className="h-4 w-4" />}
              mono
            />
          </Card>
          <Card>
            <StatBlock
              label="PnL net (30 j)"
              value={formatSigned(pnlNetValue)}
              icon={<TrendingUp className="h-4 w-4" />}
              tone={pnlTone}
            />
          </Card>
          <Card>
            <StatBlock
              label="Trades ouverts"
              value={formatCount(openTradesResult.count)}
              icon={<ArrowUp className="h-4 w-4" />}
              mono
            />
          </Card>
          <Card>
            <StatBlock
              label="Drawdown max"
              value={formatSigned(drawdownValue)}
              icon={<Wallet className="h-4 w-4" />}
              tone={
                drawdownValue === null || drawdownValue === undefined
                  ? "neutral"
                  : Number(drawdownValue) > 0
                    ? "danger"
                    : "neutral"
              }
            />
          </Card>
        </section>

        {/* Trades récents */}
        <Card padding="none">
          <div className="flex items-center justify-between border-b border-neutral-200 px-4 py-3">
            <h2 className="text-sm font-semibold">Trades récents</h2>
            <span className="text-xs text-neutral-500">
              {recentTrades.length} entrées
            </span>
          </div>
          {recentTrades.length === 0 ? (
            <div className="px-4 py-8 text-center text-sm text-neutral-500">
              Aucun trade pour l'instant. Commence par en créer un.
            </div>
          ) : (
            <ul className="divide-y divide-neutral-100">
              {recentTrades.map((trade) => (
                <TradeRow key={trade.id} trade={trade} />
              ))}
            </ul>
          )}
        </Card>
      </div>
    </main>
  );
}

// ---- Sous-composant inline (row de trade) ----------------------------------
// Volontairement non exporté : c'est un détail d'implémentation du dashboard.
// Si on le réutilise ailleurs (page de profil, page d'instrument), on extraira.
//
// Phase 10 — row cliquable : wrapper sémantique <li> + <Link> portant le
// grid. Le clic mène à /trades/[id] où vit l'écran de gestion du trade
// (publication pour les drafts, transitions live→closed→archived pour
// les autres, timeline immuable des trade_events pour tous).
// hover:bg-neutral-50 pour le feedback visuel, transition-colors pour
// fluidifier. <Link> rend un <a href> focusable nativement → clavier OK.

function TradeRow({ trade }: { trade: RecentTrade }) {
  const isDraft = trade.status === "draft";
  const pnlValue = trade.pnl_net === null ? null : Number(trade.pnl_net);
  const hasPnl = pnlValue !== null && Number.isFinite(pnlValue);
  const isProfit = hasPnl && pnlValue > 0;
  const isLoss = hasPnl && pnlValue < 0;
  const valueClass = isProfit
    ? "text-success"
    : isLoss
      ? "text-danger"
      : "text-neutral-500";

  return (
    <li>
      <Link
        href={`/trades/${trade.id}`}
        className="grid grid-cols-12 items-center gap-3 px-4 py-3 hover:bg-neutral-50 transition-colors"
      >
        {/* Status + symbol + direction */}
        <div className="col-span-12 flex items-center gap-2 sm:col-span-4">
          <Badge tone={STATUS_TONE[trade.status]} size="sm">
            {STATUS_LABEL[trade.status]}
          </Badge>
          <span className="font-medium">{trade.symbol}</span>
          <span className="text-neutral-400" aria-hidden>
            {trade.direction === "long" ? (
              <ArrowUpRight className="inline h-3.5 w-3.5" />
            ) : (
              <ArrowDownRight className="inline h-3.5 w-3.5" />
            )}
          </span>
          <span className="sr-only">
            position {trade.direction === "long" ? "longue" : "courte"}
          </span>
        </div>

        {/* Entry price */}
        <div className="col-span-4 font-mono text-xs text-neutral-500 sm:col-span-3 sm:text-sm">
          <div className="text-[10px] uppercase tracking-wide text-neutral-400 sm:hidden">
            Entrée
          </div>
          {formatPrice(trade.entry_price, trade.asset_class)}
        </div>

        {/* Current / exit price */}
        <div className="col-span-4 font-mono text-xs sm:col-span-2 sm:text-sm">
          <div className="text-[10px] uppercase tracking-wide text-neutral-400 sm:hidden">
            {trade.status === "live" ? "Actuel" : "Sortie"}
          </div>
          <span className={isDraft ? "text-neutral-400" : ""}>
            {isDraft
              ? "—"
              : formatPrice(trade.exit_price, trade.asset_class)}
          </span>
        </div>

        {/* PnL (€) + rendement (%) */}
        <div
          className={`col-span-4 text-right font-mono text-sm font-medium sm:col-span-3 ${valueClass}`}
        >
          {!hasPnl ? (
            <span className="text-neutral-400">—</span>
          ) : (
            <>
              <div>{formatSigned(pnlValue)}</div>
              <div className="text-xs opacity-80">
                {formatSignedPercent(trade.rendement_pct)}
              </div>
            </>
          )}
        </div>
      </Link>
    </li>
  );
}