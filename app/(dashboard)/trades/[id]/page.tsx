// /app/(dashboard)/trades/[id]/page.tsx
// =============================================================================
// Page de détail d'un trade — hub central pour les actions liées à un trade
// donné (édition brouillon, publication, édition rapide in-window).
//
// Server component : on charge le trade par id (RLS filtre les trades
// d'autres utilisateurs, le `.eq("user_id", user.id)` explicite bloque
// le cas "j'ai deviné l'id d'un trade public d'un autre user", même
// pattern défense en profondeur que partout ailleurs) + l'instrument
// associé via 2 queries séparées (cf. commentaire migration 003).
//
// Phase 10 — carte "Résultat" + RPC trade_metrics :
//   - On appelle la RPC SECURITY INVOKER public.trade_metrics(p_trade_id)
//     pour lire le PnL, le R-multiple et le risque initial. La RPC
//     filtre user_id = auth.uid() (un tiers reçoit 0 ligne).
//   - Si la RPC échoue ou ne renvoie rien (base en retard, RPC pas
//     encore déployée), la page s'affiche normalement SANS la carte
//     Résultat : aucune erreur bloquante côté UI.
//   - Le `quote_currency` de l'instrument est joint à la lecture pour
//     libeller « devise de cotation » du PnL (USDT pour BTCUSDT, USD
//     pour EURUSD, NULL pour stocks/ETFs → libellé sans unité).
//
// Rendu selon `status` :
//   - 'draft'     : vue lecture + lien vers /trades/[id]/edit + bouton
//                   "Publier" (TradePublishButton)
//   - 'live' in   : vue lecture + TradeLiveEdit (countdown + form
//     window        entry_price/SL/TP/notes)
//   - 'live' hors : vue lecture + badge "verrouillé"
//   - 'closed'    : vue lecture + carte Résultat + bouton Archiver
//   - 'archived'  : vue lecture + carte Résultat (archive = simple
//                   conservation post-clôture, whitepaper §04)
//   - 'forgotten' : vue lecture + boutons Réactiver/Clôturer
// =============================================================================
import Link from "next/link";
import { notFound } from "next/navigation";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { createClient } from "@/lib/supabase/server";
import { TradePublishButton } from "../_components/trade-publish-button";
import { TradeLiveEdit } from "../_components/trade-live-edit";
import { TradeTransitionButton } from "../_components/trade-transition-button";
import { TradeEventsTimeline } from "@/components/trades/trade-events-timeline";
import {
  TradeResultCard,
  type TradeMetrics,
} from "@/components/trades/trade-result-card";

const WINDOW_MS = 60 * 1000;

export default async function TradeDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  // Next 16 : `params` est async.
  const { id } = await params;

  const supabase = await createClient();

  // Filet de robustesse, le layout parent redirige normalement.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: trade, error: tradeError } = await supabase
    .from("trades")
    .select("id, status, direction, entry_price, stop_loss, take_profit, quantity, leverage, capital, risk_percent, fees, slippage, published_at, opened_at, closed_at, last_activity_at, notes, instrument_id")
    .eq("id", id)
    .eq("user_id", user.id)
    .maybeSingle();

  if (tradeError) return notFound();
  if (!trade) return notFound();

  // 2e query : l'instrument pour afficher symbol + name + asset_class
  // + quote_currency. Lecture publique (policy "instruments: lecture
  // publique" → using (true)), pas de filtre RLS à appliquer côté
  // serveur. `quote_currency` est nullable (cf. instruments dans
  // 20260821000001_initial_schema.sql lignes 102-103) : NULL pour les
  // stocks/ETFs du seed 022, non-NULL pour les paires crypto/forex.
  const { data: instrument } = await supabase
    .from("instruments")
    .select("symbol, name, asset_class, quote_currency")
    .eq("id", trade.instrument_id)
    .maybeSingle();

  // 3e query : trade_metrics(p_trade_id) — RPC SECURITY INVOKER filtrée
  // par user_id. Renvoie 0 ligne pour un tiers. Si la RPC n'existe
  // pas encore — base en retard par rapport au site — ou si l'appel
  // échoue, on ne casse PAS la page : on continue sans métriques, la
  // carte Résultat ne s'affiche pas, le reste de la page reste lisible.
  const { data: metricsRows, error: metricsError } = await supabase.rpc(
    "trade_metrics",
    { p_trade_id: trade.id }
  );
  // Premier (et seul) élément du tableau, ou null. Normalisation des
  // numériques PostgREST (numeric sérialisé en nombre JSON, mais on
  // reste défensif si le client change de format) en number pour la
  // carte.
  const rawMetrics = !metricsError && Array.isArray(metricsRows) && metricsRows.length > 0
    ? metricsRows[0]
    : null;
  const metrics: TradeMetrics | null = rawMetrics
    ? {
        status: rawMetrics.status,
        exit_price: toNumberOrNull(rawMetrics.exit_price),
        pnl_gross: toNumberOrNull(rawMetrics.pnl_gross),
        pnl_net: toNumberOrNull(rawMetrics.pnl_net),
        rendement_pct: toNumberOrNull(rawMetrics.rendement_pct),
        r_multiple: toNumberOrNull(rawMetrics.r_multiple),
        risk_pct: toNumberOrNull(rawMetrics.risk_pct),
        fees_known: rawMetrics.fees_known === true,
        slippage_known: rawMetrics.slippage_known === true,
      }
    : null;

  // Calcul de la fenêtre 60 s côté serveur.
  const publishedAtMs = trade.published_at
    ? new Date(trade.published_at).getTime()
    : 0;
  const windowEndMs = publishedAtMs + WINDOW_MS;
  // Date.now() au render : préexistant (l'original l'avait déjà), la
  // valeur initiale du countdown est donnée au composant client qui
  // prend le relais avec son setInterval. eslint-disable ciblé sur
  // cette ligne — à refactorer en sous-composant client si on veut
  // un calcul exact à l'arrivée sur la page.
  // eslint-disable-next-line react-hooks/purity
  const nowMs = Date.now();
  const isInWindow =
    trade.status === "live" &&
    publishedAtMs > 0 &&
    nowMs < windowEndMs;
  const initialRemainingSeconds = isInWindow
    ? Math.max(0, Math.floor((windowEndMs - nowMs) / 1000))
    : 0;

  // Le "Risque initial (%)" est lu depuis metrics.risk_pct (calculé par
  // la base à la lecture : |entry - stop_loss| * initial_quantity /
  // initial_capital * 100, NULL si pas de stop_loss ou capital nul).
  // Règle : pas de stop loss = pas de risque affiché. Le fallback sur
  // trade.risk_percent ne joue QUE si metrics est entièrement absent
  // (rétro-compat base en retard) — jamais si metrics.risk_pct est
  // explicitement NULL (le trade n'a pas de stop_loss, on l'affiche "—").
  const initialRiskPct = metrics ? metrics.risk_pct : (
    trade.risk_percent === null ? null : Number(trade.risk_percent)
  );

  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
        <header className="flex items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">
              Trade{" "}
              {instrument ? (
                <span className="text-neutral-700">
                  {instrument.symbol}
                </span>
              ) : (
                <span className="text-neutral-400">[instrument inconnu]</span>
              )}
            </h1>
            <p className="mt-1 text-sm text-neutral-500">
              {instrument
                ? instrument.name
                : "L'instrument associé a été supprimé ou n'est pas accessible."}{" "}
              · {trade.direction.toUpperCase()}
            </p>
          </div>
          <StatusBadge status={trade.status} isInWindow={isInWindow} />
        </header>

        <Card>
          <h2 className="text-sm font-semibold">Détails du trade</h2>
          <dl className="mt-3 grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
            <DetailRow label="Prix d&apos;entrée" value={formatNumber(trade.entry_price)} />
            <DetailRow
              label="Stop Loss"
              value={
                trade.stop_loss === null
                  ? "—"
                  : formatNumber(trade.stop_loss)
              }
            />
            <DetailRow
              label="Take Profit"
              value={
                trade.take_profit === null
                  ? "—"
                  : formatNumber(trade.take_profit)
              }
            />
            <DetailRow label="Quantité" value={formatNumber(trade.quantity)} />
            <DetailRow label="Capital engagé" value={formatCurrency(trade.capital)} />
            <DetailRow
              label="Levier"
              value={trade.leverage ? `×${formatNumber(trade.leverage)}` : "—"}
            />
            <DetailRow
              label="Risque initial (%)"
              value={
                initialRiskPct === null
                  ? "—"
                  : `${formatNumber(initialRiskPct, 2)} %`
              }
            />
            <DetailRow
              label="Publié le"
              value={
                trade.published_at
                  ? new Date(trade.published_at).toLocaleString("fr-FR")
                  : "—"
              }
            />
            <DetailRow
              label="Ouvert le"
              value={
                trade.opened_at
                  ? new Date(trade.opened_at).toLocaleString("fr-FR")
                  : "—"
              }
            />
          </dl>
          {trade.notes ? (
            <div className="mt-4 border-t border-neutral-100 pt-3">
              <p className="text-xs font-medium text-neutral-500">Notes</p>
              <p className="mt-1 whitespace-pre-wrap text-sm text-neutral-700">
                {trade.notes}
              </p>
            </div>
          ) : null}
        </Card>

        {/* Preuve de performance (Phase 9) — timeline immuable des
            trade_events. Lecture pure, aucune migration. Affichée pour
            TOUS les statuts. */}
        <TradeEventsTimeline tradeId={trade.id} />

        {/* Carte "Résultat" — affichée UNIQUEMENT pour un trade clôturé
            ou archivé. Si metrics === null (RPC échoue ou absente),
            la carte ne s'affiche pas — la page reste fonctionnelle. */}
        {metrics && (metrics.status === "closed" || metrics.status === "archived") ? (
          <TradeResultCard
            metrics={metrics}
            quoteCurrency={instrument?.quote_currency ?? null}
          />
        ) : null}

        {/* Actions : transitions manuelles selon statut. */}
        {trade.status === "live" ||
        trade.status === "forgotten" ||
        trade.status === "closed" ? (
          <Card>
            <h2 className="text-sm font-semibold">Actions</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Transitions manuelles sur ce trade. Chaque action est
              confirmée avant exécution et tracée dans l&apos;historique
              du trade (trade_events).
            </p>
            <div className="mt-4 flex flex-wrap items-center justify-end gap-2">
              {trade.status === "live" ? (
                <TradeTransitionButton
                  tradeId={trade.id}
                  targetStatus="closed"
                  label="Clôturer le trade"
                  // Le prix de sortie est saisi dans le dialog
                  // (slot `form` du ConfirmDialog). Le message
                  // annonce la saisie obligatoire et la conséquence
                  // immédiate (PnL calculé à la clôture).
                  confirmMessage="Indiquez le prix de sortie. Le PnL sera calculé et affiché dès la confirmation."
                  variant="secondary"
                  assetClass={instrument?.asset_class}
                />
              ) : null}
              {trade.status === "forgotten" ? (
                <>
                  <TradeTransitionButton
                    tradeId={trade.id}
                    targetStatus="live"
                    label="Réactiver"
                    confirmMessage="Réactiver ce trade oublié ? Il repasse en 'live' et son activité est repoussée (last_activity_at mis à now())."
                    variant="primary"
                  />
                  <TradeTransitionButton
                    tradeId={trade.id}
                    targetStatus="closed"
                    label="Clôturer"
                    confirmMessage="Indiquez le prix de sortie. Le PnL sera calculé et affiché dès la confirmation."
                    variant="secondary"
                    assetClass={instrument?.asset_class}
                  />
                </>
              ) : null}
              {trade.status === "closed" ? (
                <TradeTransitionButton
                  tradeId={trade.id}
                  targetStatus="archived"
                  label="Archiver"
                  confirmMessage="Archiver ce trade clôturé ? L'archivage est terminal : aucune transition depuis 'archived' n'est prévue par le whitepaper §04."
                  variant="secondary"
                />
              ) : null}
            </div>
          </Card>
        ) : null}

        {/* Rendu conditionnel selon status */}
        {trade.status === "draft" ? (
          <Card>
            <h2 className="text-sm font-semibold">Brouillon</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Ce trade n&apos;est pas encore publié. Tu peux ajuster tous les
              champs (entrée, SL, TP, capital, quantité, notes) ou le
              publier. Une fois publié, l&apos;entrée, le capital et la
              quantité seront verrouillés 60 secondes après la publication
              (fenêtre scalping, whitepaper §04).
            </p>
            <div className="mt-4 flex items-center justify-end gap-2">
              <Link href={`/trades/${trade.id}/edit`}>
                <Button variant="secondary">Modifier le brouillon</Button>
              </Link>
              <TradePublishButton tradeId={trade.id} />
            </div>
          </Card>
        ) : null}

        {trade.status === "live" && isInWindow ? (
          <TradeLiveEdit
            tradeId={trade.id}
            initialEntryPrice={Number(trade.entry_price)}
            initialStopLoss={
              trade.stop_loss === null ? null : Number(trade.stop_loss)
            }
            initialTakeProfit={
              trade.take_profit === null ? null : Number(trade.take_profit)
            }
            initialNotes={trade.notes ?? ""}
            initialRemainingSeconds={initialRemainingSeconds}
          />
        ) : null}

        {trade.status === "live" && !isInWindow ? (
          <Card>
            <h2 className="text-sm font-semibold">Trade verrouillé</h2>
            <p className="mt-1 text-xs text-neutral-500">
              La fenêtre scalping de 60 secondes est expirée. Le prix
              d&apos;entrée, le stop loss, le take profit, le capital et la
              quantité sont définitivement verrouillés pour garantir la
              cohérence de l&apos;historique (whitepaper §04).
            </p>
          </Card>
        ) : null}

        {trade.status === "archived" ? (
          <Card>
            <h2 className="text-sm font-semibold">Trade archivé</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Ce trade est archivé — un état terminal (whitepaper §04) :
              aucune transition n&apos;est prévue depuis ce statut.
              L&apos;affichage reste en lecture seule.
            </p>
          </Card>
        ) : null}

        <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
          Kairo · Phase 2 · détail de trade
        </footer>
      </div>
    </main>
  );
}

// -----------------------------------------------------------------------------
// Sous-composants locaux (server-renderable, pas besoin d'isoler)
// -----------------------------------------------------------------------------

function StatusBadge({
  status,
  isInWindow,
}: {
  status: string;
  isInWindow: boolean;
}) {
  const config: Record<string, { label: string; classes: string }> = {
    draft: {
      label: "Brouillon",
      classes: "bg-neutral-100 text-neutral-700",
    },
    live: isInWindow
      ? {
          label: "Live · fenêtre scalping",
          classes: "bg-info-subtle text-info",
        }
      : {
          label: "Live · verrouillé",
          classes: "bg-neutral-100 text-neutral-700",
        },
    closed: {
      label: "Clôturé",
      // Convention UI (cf. TODO_TECHNIQUE.md) : les badges encodent le
      // CYCLE DE VIE du trade, jamais l'issue financière.
      classes: "bg-neutral-100 text-neutral-700",
    },
    forgotten: {
      label: "Oublié",
      classes: "bg-neutral-100 text-neutral-500",
    },
    archived: {
      label: "Archivé",
      classes: "bg-neutral-100 text-neutral-400",
    },
  };
  const c = config[status] ?? {
    label: status,
    classes: "bg-neutral-100 text-neutral-500",
  };
  return (
    <span
      className={[
        "inline-flex flex-shrink-0 items-center rounded-full px-3 py-1 text-xs font-semibold",
        c.classes,
      ].join(" ")}
    >
      {c.label}
    </span>
  );
}

function DetailRow({
  label,
  value,
}: {
  label: string;
  value: React.ReactNode;
}) {
  return (
    <div>
      <dt className="text-xs font-medium text-neutral-500">{label}</dt>
      <dd className="mt-0.5 font-mono tabular-nums text-neutral-900">
        {value}
      </dd>
    </div>
  );
}

function formatNumber(
  n: string | number | null | undefined,
  maxFrac: number = 4
): string {
  if (n === null || n === undefined) return "—";
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return v.toLocaleString("fr-FR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: maxFrac,
  });
}

function formatCurrency(n: string | number | null | undefined): string {
  if (n === null || n === undefined) return "—";
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return (
    v.toLocaleString("fr-FR", {
      minimumFractionDigits: 0,
      maximumFractionDigits: 2,
    }) + " €"
  );
}

// Convertit la valeur renvoyée par la RPC trade_metrics en number
// JS. PostgREST sérialise `numeric` en nombre JSON (pas en chaîne),
// mais on reste défensif si le client ou une migration future change
// le format : la fonction accepte string|number|null|undefined.
function toNumberOrNull(v: string | number | null | undefined): number | null {
  if (v === null || v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}