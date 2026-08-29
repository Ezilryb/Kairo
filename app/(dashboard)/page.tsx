// /app/(dashboard)/page.tsx
// =============================================================================
// Dashboard — désormais dans le route group (dashboard), donc sous la
// protection de (dashboard)/layout.tsx (vérif session + vérif profil).
// Le proxy.ts reste la première ligne de défense (redirect rapide vers
// /login), le layout est l'autorisation réelle (côté serveur, exécuté
// même si le proxy est contourné — défense en profondeur, cf. CVE-2025-29927).
//
// Le route group (dashboard) ne produit PAS de segment d'URL : cette page
// répond sur `/`, comme l'ancienne app/page.tsx avant ce déplacement.
// app/page.tsx a été supprimée pour éviter un conflit de route (deux
// page.tsx répondant sur `/`).
//
// Direction Google Finance, données mockées — Phase 0 / Tâche 3 suite.
// Sera branché sur Supabase en Phase 2 (trades) et Phase 4 (analytics).
// =============================================================================
import {
  Activity,
  ArrowDownRight,
  ArrowUp,
  ArrowUpRight,
  CircleUser,
  Plus,
  TrendingUp,
  Wallet,
} from "lucide-react";
import { Badge, type BadgeTone } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { StatBlock } from "@/components/ui/StatBlock";

// ---- Données mockées --------------------------------------------------------

type TradeStatus = "live" | "draft" | "closed" | "forgotten" | "archived";
type TradeDirection = "long" | "short";
type AssetClass = "crypto" | "stock" | "forex" | "commodity" | "index" | "etf";

type MockTrade = {
  id: string;
  symbol: string;
  assetClass: AssetClass;
  direction: TradeDirection;
  status: TradeStatus;
  entryPrice: number;
  currentPrice: number;
  pnlValue: number;
  pnlPercent: number;
  ago: string;
};

const MOCK_TRADES: MockTrade[] = [
  {
    id: "t1",
    symbol: "BTCUSDT",
    assetClass: "crypto",
    direction: "long",
    status: "live",
    entryPrice: 62_410.5,
    currentPrice: 64_120.0,
    pnlValue: 342.18,
    pnlPercent: 2.74,
    ago: "il y a 12 min",
  },
  {
    id: "t2",
    symbol: "ETHUSDT",
    assetClass: "crypto",
    direction: "short",
    status: "closed",
    entryPrice: 3_412.8,
    currentPrice: 3_298.4,
    pnlValue: 114.4,
    pnlPercent: 3.35,
    ago: "il y a 1 h",
  },
  {
    id: "t3",
    symbol: "AAPL",
    assetClass: "stock",
    direction: "long",
    status: "live",
    entryPrice: 224.1,
    currentPrice: 221.7,
    pnlValue: -96.0,
    pnlPercent: -1.07,
    ago: "il y a 3 h",
  },
  {
    id: "t4",
    symbol: "NQH5",
    assetClass: "index",
    direction: "long",
    status: "forgotten",
    entryPrice: 21_120.0,
    currentPrice: 21_080.0,
    pnlValue: -40.0,
    pnlPercent: -0.19,
    ago: "il y a 6 j",
  },
  {
    id: "t5",
    symbol: "EURUSD",
    assetClass: "forex",
    direction: "short",
    status: "draft",
    entryPrice: 1.0825,
    currentPrice: 0,
    pnlValue: 0,
    pnlPercent: 0,
    ago: "à l'instant",
  },
  {
    id: "t6",
    symbol: "TSLA",
    assetClass: "stock",
    direction: "long",
    status: "closed",
    entryPrice: 348.6,
    currentPrice: 372.4,
    pnlValue: 238.0,
    pnlPercent: 6.83,
    ago: "il y a 2 j",
  },
  {
    id: "t7",
    symbol: "GLD",
    assetClass: "etf",
    direction: "long",
    status: "archived",
    entryPrice: 195.4,
    currentPrice: 198.1,
    pnlValue: 270.0,
    pnlPercent: 1.38,
    ago: "il y a 3 mois",
  },
];

type MockActivity = {
  id: string;
  kind: "follow" | "trade_published" | "system";
  actor: string;
  message: string;
  ago: string;
};

const MOCK_ACTIVITY: MockActivity[] = [
  {
    id: "a1",
    kind: "trade_published",
    actor: "Lucas M.",
    message: "a publié un nouveau trade BTCUSDT (long)",
    ago: "il y a 5 min",
  },
  {
    id: "a2",
    kind: "follow",
    actor: "Marie D.",
    message: "a commencé à vous suivre",
    ago: "il y a 2 h",
  },
  {
    id: "a3",
    kind: "system",
    actor: "Kairo",
    message: "3 trades sont passés en statut OUBLIÉ (inactivité > 5 j)",
    ago: "il y a 1 j",
  },
];

// ---- Helpers de présentation -----------------------------------------------

const STATUS_TONE: Record<TradeStatus, BadgeTone> = {
  // Les statuts de cycle de vie (draft/closed/archived) restent neutres :
  // un trade clôturé peut être à perte, archivé n'est pas un signal négatif.
  // L'issue (gain/perte) est déjà portée par la couleur du PnL (valueClass).
  draft: "neutral",
  live: "info",
  forgotten: "warning", // mérite l'alerte — "à relancer"
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

function formatPrice(value: number, assetClass: AssetClass): string {
  if (value === 0) return "—";
  // Forex : 5 décimales, le reste : 2 décimales. Toutes les branches passent
  // par toLocaleString pour respecter la locale française (espace pour les
  // milliers, virgule décimale) — sans ça, un forex à 1.08250 s'affiche en
  // anglo-saxon à côté d'un crypto en 62 410,50.
  if (assetClass === "forex") {
    return value.toLocaleString("fr-FR", {
      minimumFractionDigits: 5,
      maximumFractionDigits: 5,
    });
  }
  return value.toLocaleString("fr-FR", { maximumFractionDigits: 2 });
}

function formatSigned(value: number, suffix: string = "€"): string {
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  const abs = Math.abs(value);
  return `${sign}${abs.toLocaleString("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${suffix}`;
}

function formatSignedPercent(value: number): string {
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}${Math.abs(value).toFixed(2)}%`;
}

// ---- Composants -------------------------------------------------------------

export default function DashboardPage() {
  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-6xl space-y-6 px-6 py-8">
        {/* Header */}
        <header className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
            <p className="mt-1 text-sm text-neutral-500">
              Bienvenue, Momentum_FR. Voici l'état de ton journal.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="secondary">Exporter</Button>
            <Button variant="primary">
              <Plus className="h-4 w-4" aria-hidden />
              Nouveau trade
            </Button>
          </div>
        </header>

        {/* Stats principales */}
        <section className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <Card>
            <StatBlock
              label="Winrate"
              value="64.2"
              unit="%"
              icon={<Activity className="h-4 w-4" />}
              delta={2.4}
              mono
            />
          </Card>
          <Card>
            <StatBlock
              label="PnL net (30 j)"
              value="+1 248.40"
              unit="€"
              icon={<TrendingUp className="h-4 w-4" />}
              delta={4.6}
              deltaLabel="+4.6%"
            />
          </Card>
          <Card>
            <StatBlock
              label="Trades ouverts"
              value="3"
              icon={<ArrowUp className="h-4 w-4" />}
              delta={0}
              mono
            />
          </Card>
          <Card>
            <StatBlock
              label="Drawdown max"
              value="−1 240"
              unit="€"
              icon={<Wallet className="h-4 w-4" />}
              delta={-3.2}
              deltaLabel="−3.2%"
            />
          </Card>
        </section>

        {/* Trades récents */}
        <Card padding="none">
          <div className="flex items-center justify-between border-b border-neutral-200 px-4 py-3">
            <h2 className="text-sm font-semibold">Trades récents</h2>
            <span className="text-xs text-neutral-500">
              {MOCK_TRADES.length} entrées
            </span>
          </div>
          <ul className="divide-y divide-neutral-100">
            {MOCK_TRADES.map((trade) => (
              <TradeRow key={trade.id} trade={trade} />
            ))}
          </ul>
        </Card>

        {/* Activité récente */}
        <Card padding="none">
          <div className="border-b border-neutral-200 px-4 py-3">
            <h2 className="text-sm font-semibold">Activité</h2>
          </div>
          <ul className="divide-y divide-neutral-100">
            {MOCK_ACTIVITY.map((item) => (
              <li
                key={item.id}
                className="flex items-center gap-3 px-4 py-3"
              >
                <span className="inline-flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-neutral-100 text-neutral-500">
                  {item.kind === "follow" ? (
                    <CircleUser className="h-4 w-4" aria-hidden />
                  ) : item.kind === "trade_published" ? (
                    <ArrowUpRight className="h-4 w-4" aria-hidden />
                  ) : (
                    <Activity className="h-4 w-4" aria-hidden />
                  )}
                </span>
                <div className="min-w-0 flex-1 text-sm">
                  <span className="font-medium">{item.actor}</span>{" "}
                  <span className="text-neutral-600">{item.message}</span>
                </div>
                <span className="flex-shrink-0 text-xs text-neutral-500">
                  {item.ago}
                </span>
              </li>
            ))}
          </ul>
        </Card>

        <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
          Kairo · Phase 0 · données mockées
        </footer>
      </div>
    </main>
  );
}

// ---- Sous-composant inline (row de trade) ----------------------------------
// Volontairement non exporté : c'est un détail d'implémentation du dashboard.
// Si on le réutilise ailleurs (page de profil, page d'instrument), on extraira.

function TradeRow({ trade }: { trade: MockTrade }) {
  const isDraft = trade.status === "draft";
  const isProfit = trade.pnlValue > 0;
  const isLoss = trade.pnlValue < 0;
  const valueClass = isProfit
    ? "text-success"
    : isLoss
      ? "text-danger"
      : "text-neutral-500";

  return (
    <li className="grid grid-cols-12 items-center gap-3 px-4 py-3">
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
        {formatPrice(trade.entryPrice, trade.assetClass)}
      </div>

      {/* Current / exit price */}
      <div className="col-span-4 font-mono text-xs sm:col-span-2 sm:text-sm">
        <div className="text-[10px] uppercase tracking-wide text-neutral-400 sm:hidden">
          {trade.status === "live" ? "Actuel" : "Sortie"}
        </div>
        <span className={isDraft ? "text-neutral-400" : ""}>
          {isDraft ? "—" : formatPrice(trade.currentPrice, trade.assetClass)}
        </span>
      </div>

      {/* PnL */}
      <div
        className={`col-span-4 text-right font-mono text-sm font-medium sm:col-span-3 ${valueClass}`}
      >
        {isDraft ? (
          <span className="text-neutral-400">—</span>
        ) : (
          <>
            <div>{formatSigned(trade.pnlValue)}</div>
            <div className="text-xs opacity-80">
              {formatSignedPercent(trade.pnlPercent)}
            </div>
          </>
        )}
      </div>
    </li>
  );
}
