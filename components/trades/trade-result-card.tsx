// /components/trades/trade-result-card.tsx
// =============================================================================
// Carte "Résultat" — affichage du PnL et du R-multiple d'un trade clôturé
// ou archivé. Server component pur (aucun state, aucune action).
//
// Source de données : public.trade_metrics(p_trade_id uuid), RPC SECURITY
// INVOKER filtrée par user_id = auth.uid(). Le caller (page
// /trades/[id]) passe la première ligne du résultat. Si la RPC échoue
// ou ne renvoie rien, la carte n'est simplement pas rendue — la page
// reste fonctionnelle.
//
// Affichage conditionné par le statut (closed ou archived) :
//   - status === 'closed' ou 'archived' → carte rendue
//   - autres statuts → pas de carte (le trade n'a pas encore de
//     résultat calculable)
//
// Mention "frais non renseignés" : si fees_known = false OU
// slippage_known = false, pnl_net peut différer du PnL réel (la base
// coalesce fees/slippage à 0). Aucun écran de saisie dans l'app.
//
// Devise de cotation : lue depuis instruments.quote_currency (nullable).
// Pour les paires crypto/forex, la devise est posée (USDT, USD). Pour
// les stocks/ETFs, la colonne est NULL dans le seed 022 — fallback
// "devise de cotation" sans nommer l'unité. Aucun suffixe par valeur
// quand quoteCurrency est NULL ; une seule phrase sous la carte
// rappelle l'unité.
//
// Pas de nouvelle dépendance. Pas d'effet de bord. Aucune écriture
// côté client.
// =============================================================================
import { Card } from "@/components/ui/Card";

export type TradeMetrics = {
  status: string;
  exit_price: number | null;
  pnl_gross: number | null;
  pnl_net: number | null;
  rendement_pct: number | null;
  r_multiple: number | null;
  risk_pct: number | null;
  fees_known: boolean;
  slippage_known: boolean;
};

export function TradeResultCard({
  metrics,
  quoteCurrency,
}: {
  metrics: TradeMetrics;
  /**
   * Devise de cotation de l'instrument (USDT/USD/...). Si NULL
   * (stocks/ETFs du seed 022 ou instrument custom sans devise),
   * on n'affiche aucun suffixe après les valeurs et on met une
   * seule phrase sous la carte.
   */
  quoteCurrency: string | null;
}) {
  // Formattage français (espace milliers, virgule décimale). 4 décimales
  // pour les PnL et le prix, 2 pour le R-multiple et le rendement %.
  const fmtNumber = (n: number | null, maxFrac: number = 4): string =>
    n === null
      ? "—"
      : n.toLocaleString("fr-FR", {
          minimumFractionDigits: 0,
          maximumFractionDigits: maxFrac,
        });

  // Couleur par valeur, selon son propre signe. Un trade perdant peut
  // avoir un pnl_gross positif (gain) et un pnl_net négatif (les frais
  // mangent le gain) — chaque valeur est indépendante. Tokens
  // sémantiques du design system (cf. tailwind.config.ts).
  const valueClass = (n: number | null): string =>
    n === null
      ? "text-neutral-700"
      : n > 0
        ? "text-success"
        : n < 0
          ? "text-danger"
          : "text-neutral-700";

  // Suffixe de devise : vide si NULL, sinon l'unité (USDT, USD, etc.).
  // Une seule phrase de pied de carte rappelle l'unité quand NULL.
  const unitSuffix = quoteCurrency ? ` ${quoteCurrency}` : "";

  return (
    <Card>
      <h2 className="text-sm font-semibold">Résultat</h2>

      <dl className="mt-3 grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
        <div>
          <dt className="text-xs font-medium text-neutral-500">
            Prix de sortie
          </dt>
          <dd className="mt-0.5 font-mono tabular-nums text-neutral-900">
            {fmtNumber(metrics.exit_price)}{unitSuffix}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium text-neutral-500">
            PnL brut
          </dt>
          <dd
            className={`mt-0.5 font-mono tabular-nums ${valueClass(metrics.pnl_gross)}`}
          >
            {fmtNumber(metrics.pnl_gross)}{unitSuffix}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium text-neutral-500">
            PnL net
          </dt>
          <dd
            className={`mt-0.5 font-mono tabular-nums ${valueClass(metrics.pnl_net)}`}
          >
            {fmtNumber(metrics.pnl_net)}{unitSuffix}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium text-neutral-500">
            Rendement
          </dt>
          <dd
            className={`mt-0.5 font-mono tabular-nums ${valueClass(metrics.rendement_pct)}`}
          >
            {metrics.rendement_pct === null
              ? "—"
              : `${fmtNumber(metrics.rendement_pct, 2)} %`}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium text-neutral-500">
            R-multiple
          </dt>
          <dd
            className={`mt-0.5 font-mono tabular-nums ${valueClass(metrics.r_multiple)}`}
          >
            {metrics.r_multiple === null
              ? "—"
              : `${metrics.r_multiple > 0 ? "+" : ""}${fmtNumber(metrics.r_multiple, 2)} R`}
          </dd>
        </div>
      </dl>

      {!metrics.fees_known || !metrics.slippage_known ? (
        <p
          role="note"
          className="mt-3 rounded-md border border-warning-border bg-warning-subtle px-3 py-2 text-xs text-warning"
        >
          Frais et slippage non renseignés. Le PnL net affiché peut
          différer du PnL réel.
        </p>
      ) : null}

      <p className="mt-3 text-xs text-neutral-400">
        {quoteCurrency
          ? `Le PnL est libellé en ${quoteCurrency}. Le capital est saisi en euros ; aucune conversion automatique n'est appliquée.`
          : "Montants exprimés dans la devise de cotation de l'instrument."}
      </p>
    </Card>
  );
}