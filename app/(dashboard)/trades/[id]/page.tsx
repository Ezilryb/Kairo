// /app/(dashboard)/trades/[id]/page.tsx
// =============================================================================
// Page de détail d'un trade — hub central pour les actions liées à un trade
// donné (édition brouillon, publication, édition rapide in-window).
//
// Server component : on charge le trade par id (RLS filtre les trades
// d'autres utilisateurs, le `.eq("user_id", user.id)` explicite bloque
// le cas "j'ai deviné l'id d'un trade public d'un autre user", même
// pattern défense en profondeur que partout ailleurs) + l'instrument
// associé via jointure Supabase. Pas de `notFound()` silencieux : on
// préfère 404 explicite, pas de leak d'existence.
//
// Rendu selon `status` :
//   - 'draft'     : vue lecture + lien vers /trades/[id]/edit + bouton
//                   "Publier" (TradePublishButton)
//   - 'live' in   : vue lecture + TradeLiveEdit (countdown + form
//     window        entry_price/SL/TP/notes)
//   - 'live' hors : vue lecture + badge "verrouillé"
//   - autres      : vue lecture simple (closed/forgotten/archived : ces
//                   états auront leur écran de gestion dédié en Point D+,
//                   pour l'instant on les affiche read-only sans crash)
//
// Calcul de la fenêtre 60 s : fait côté serveur au render, le client
// prend le relais avec son propre setInterval. La valeur initiale
// serveur évite le flash "60 s" sur une page déjà à 55 s si le render
// a pris du temps.
// =============================================================================
import Link from "next/link";
import { notFound } from "next/navigation";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { createClient } from "@/lib/supabase/server";
import { TradePublishButton } from "../_components/trade-publish-button";
import { TradeLiveEdit } from "../_components/trade-live-edit";

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

  // Charge le trade par id. `.eq("user_id", user.id)` explicite en plus
  // de la RLS : bloque le cas tordu "j'ai deviné l'id d'un trade public
  // d'un autre user".
  //
  // Note : on NE fait PAS de jointure `instrument:instruments(...)` ici.
  // L'inférence de type de supabase-js ne reconnaît pas la jointure avec
  // un select string et renvoie `GenericStringError`, ce qui casse
  // toute la suite du code (accès aux colonnes du trade). On préfère
  // 2 queries séparées (le trade + l'instrument par son id) — explicite,
  // type-safe, et le coût d'une query supplémentaire est négligeable
  // (instruments en lecture publique, index sur PK).
  const { data: trade, error: tradeError } = await supabase
    .from("trades")
    .select("id, status, direction, entry_price, stop_loss, take_profit, quantity, leverage, capital, risk_percent, fees, slippage, published_at, opened_at, closed_at, last_activity_at, notes, instrument_id")
    .eq("id", id)
    .eq("user_id", user.id)
    .maybeSingle();

  if (tradeError) return notFound();
  if (!trade) return notFound();

  // 2e query : l'instrument pour afficher symbol + name. Lecture
  // publique (policy "instruments: lecture publique" → using (true)),
  // pas de filtre RLS à appliquer côté serveur.
  const { data: instrument } = await supabase
    .from("instruments")
    .select("symbol, name")
    .eq("id", trade.instrument_id)
    .maybeSingle();

  // Calcul de la fenêtre 60 s côté serveur.
  //   - status === 'live' : on est publié
  //   - published_at !== null : toujours vrai pour un trade live, mais
  //     on reste explicite
  //   - now() < published_at + 60 s : on est encore dans la fenêtre
  const publishedAtMs = trade.published_at
    ? new Date(trade.published_at).getTime()
    : 0;
  const windowEndMs = publishedAtMs + WINDOW_MS;
  const nowMs = Date.now();
  const isInWindow =
    trade.status === "live" &&
    publishedAtMs > 0 &&
    nowMs < windowEndMs;
  const initialRemainingSeconds = isInWindow
    ? Math.max(0, Math.floor((windowEndMs - nowMs) / 1000))
    : 0;

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
            <DetailRow label="Prix d'entrée" value={formatNumber(trade.entry_price)} />
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
              label="Risque (%)"
              value={
                trade.risk_percent === null
                  ? "—"
                  : `${formatNumber(trade.risk_percent)} %`
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

        {trade.status !== "draft" && trade.status !== "live" ? (
          <Card>
            <h2 className="text-sm font-semibold">
              Trade en statut{" "}
              <code className="rounded bg-neutral-100 px-1 py-0.5 text-[11px]">
                {trade.status}
              </code>
            </h2>
            <p className="mt-1 text-xs text-neutral-500">
              Cet état (
              {trade.status === "closed"
                ? "clôturé"
                : trade.status === "forgotten"
                  ? "oublié (5 jours d'inactivité)"
                  : trade.status === "archived"
                    ? "archivé"
                    : "inconnu"}
              ) aura son écran de gestion dédié en Phase 2 Point D
              (transitions manuelles + job planifié). Pour l&apos;instant,
              l&apos;affichage est en lecture seule.
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
  // On s'aligne sur les classes du Badge du design system sans
  // l'importer directement : ce badge a une logique conditionnelle
  // (live in-window vs out-of-window) que le Badge générique ne gère
  // pas. Si on importe Badge, on n'utilise pas ses variantes, donc
  // autant rester inline.
  const config: Record<string, { label: string; classes: string }> = {
    draft: {
      label: "Brouillon",
      classes: "bg-neutral-100 text-neutral-700",
    },
    live: isInWindow
      ? {
          label: "Live · fenêtre scalping",
          // Pas de token "warning" dans le design system (seulement
          // success/danger/info). On reste sur info pour un état
          // nominal (le trade est publié, dans la fenêtre, tout va
          // bien). bg-info-subtle est déjà utilisé ailleurs (cf.
          // TradeForm, TradeLiveEdit) pour la même raison.
          classes: "bg-info-subtle text-info",
        }
      : {
          label: "Live · verrouillé",
          classes: "bg-neutral-100 text-neutral-700",
        },
    closed: {
      label: "Clôturé",
      classes: "bg-success-subtle text-success",
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

// numeric(24, 8) → string côté Supabase, Number() pour les calculs JS
// puis toLocaleString pour l'affichage français (espace milliers,
// virgule décimale). 8 décimales max, on en garde 4 pour les prix
// (les cryptos en ont rarement besoin de plus dans l'UI, l'œil lit
// mieux 67 142,3500 que 67 142,35000000).
function formatNumber(n: string | number | null | undefined): string {
  if (n === null || n === undefined) return "—";
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return v.toLocaleString("fr-FR", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 4,
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
