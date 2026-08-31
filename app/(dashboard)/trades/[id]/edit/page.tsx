// /app/(dashboard)/trades/[id]/edit/page.tsx
// =============================================================================
// Page d'édition d'un trade — affiche le TradeForm en mode "edit",
// pré-rempli avec les valeurs actuelles du trade.
//
// Server component : on charge le trade par id (RLS filtre les trades
// d'autres utilisateurs) et la liste des instruments, puis on délègue au
// client component `TradeForm`.
//
// Points sensibles :
//   1. `params` est une Promise en Next 16 (cf. leçon CI/CD dans
//      TODO_TECHNIQUE.md et migration Next 15+) — on doit l'attendre.
//   2. On filtre explicitement sur `user_id = auth.uid()` en plus de la
//      RLS, pour ne pas tomber sur un trade public d'un autre user même
//      si on devine son id (défense en profondeur, même pattern que le
//      layout `(dashboard)/layout.tsx`).
//   3. Édition autorisée uniquement pour les trades en `draft`. Les
//      trades `live`/`closed`/`forgotten`/`archived` sont verrouillés par
//      les triggers métier (enforce_entry_price_immutability,
//      enforce_capital_immutability) pour cohérence comptable. On
//      affiche un message explicite plutôt que de rendre un form qui se
//      ferait rejeter à la soumission.
//   4. `notFound()` si la ligne n'existe pas ou n'est pas au user : pas
//      d'info sur l'existence de la ressource pour un attaquant.
// =============================================================================
import Link from "next/link";
import { notFound } from "next/navigation";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { createClient } from "@/lib/supabase/server";
import {
  TradeForm,
  type InstrumentOption,
  type TradeFormData,
} from "../../_components/trade-form";

export default async function EditTradePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  // Next 16 : `params` est async, on attend la résolution.
  const { id } = await params;

  const supabase = await createClient();

  // Filet de robustesse, même logique que la page new. Le layout parent
  // redirige normalement, mais on ne s'y fie pas à 100%.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  // Charge le trade par id. RLS "trades: lecture (publics ou propriétaire)"
  // laisse passer nos propres trades (user_id = auth.uid()) et les trades
  // publics des autres. Le `.eq("user_id", user.id)` ci-dessous est
  // redondant avec la RLS pour NOS trades, mais il BLOQUE explicitement
  // le cas pathologique "j'ai deviné l'id d'un trade public d'un autre
  // user, je veux l'éditer". Sans ce filtre, la policy UPDATE
  // (auth.uid() = user_id) le bloquerait de toute façon, mais on teste
  // moins loin. Défense en profondeur.
  const { data: trade, error: tradeError } = await supabase
    .from("trades")
    .select(
      "id, instrument_id, direction, entry_price, quantity, capital, notes, status",
    )
    .eq("id", id)
    .eq("user_id", user.id)
    .maybeSingle();

  if (tradeError) {
    // Erreur DB inattendue. On ne distingue pas dans l'UI (pas d'info
    // utile pour l'utilisateur, et ne pas leaker le type d'erreur), on
    // tombe sur 404. C'est aussi le filet si la table `trades` est down.
    return notFound();
  }

  if (!trade) {
    // Pas trouvé, ou pas le propriétaire. notFound() pour ne pas leaker
    // l'existence d'un trade d'un autre user (404 = "n'existe pas pour
    // toi", même si elle existe pour quelqu'un d'autre).
    return notFound();
  }

  // Charge les instruments pour le dropdown (même requête que la page new).
  const { data: instruments, error: instrumentsError } = await supabase
    .from("instruments")
    .select("id, symbol, name")
    .order("symbol", { ascending: true });

  if (instrumentsError) {
    return (
      <main className="min-h-screen bg-neutral-50">
        <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
          <header>
            <h1 className="text-2xl font-semibold tracking-tight">
              Modifier le trade
            </h1>
          </header>
          <Card>
            <p className="text-sm text-danger">
              Impossible de charger les instruments. Réessaie plus tard.
            </p>
          </Card>
          <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
            Kairo · Phase 2 · édition de brouillon
          </footer>
        </div>
      </main>
    );
  }

  // Garde-fou : si le trade n'est plus en draft, l'édition directe n'est
  // pas autorisée. Les triggers `enforce_entry_price_immutability` et
  // `enforce_capital_immutability` (migration Phase 2) bloqueraient
  // silencieusement les modifs sur entry_price et capital post-pub, et
  // on ne propose pas ici d'édition des champs autorisés (SL/TP,
  // notes, is_public) — c'est un autre écran, à designer. On affiche
  // donc un message clair + retour dashboard, plutôt que de laisser
  // l'utilisateur remplir un form qui se ferait rejeter.
  if (trade.status !== "draft") {
    return (
      <main className="min-h-screen bg-neutral-50">
        <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
          <header>
            <h1 className="text-2xl font-semibold tracking-tight">
              Modifier le trade
            </h1>
          </header>
          <Card>
            <h2 className="text-sm font-semibold">Trade non modifiable</h2>
            <p className="mt-1 text-xs text-neutral-500">
              Ce trade est en statut{" "}
              <code className="rounded bg-neutral-100 px-1 py-0.5 text-[11px]">
                {trade.status}
              </code>{" "}
              et n&apos;est plus éditable via ce formulaire. Les trades
              publiés sont verrouillés sur leur prix d&apos;entrée, leur
              capital et leur quantité pour garantir la cohérence de
              l&apos;historique (whitepaper §04).
            </p>
            <div className="mt-4 flex justify-end">
              <Link href="/">
                <Button variant="secondary">Retour au dashboard</Button>
              </Link>
            </div>
          </Card>
          <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
            Kairo · Phase 2 · édition de brouillon
          </footer>
        </div>
      </main>
    );
  }

  // Pré-remplissage du form. Le TradeForm s'attend à un `initialTrade`
  // de type `TradeFormData` mais, à l'intérieur, il extrait `id` via un
  // cast `as TradeFormData & { id?: string }` (l'identifiant du trade
  // est nécessaire pour le `.eq('id', ...)` de l'UPDATE). On lui passe
  // donc un objet intersection `TradeFormData & { id: string }` — le
  // type est structurellement compatible avec `TradeFormData`, pas de
  // cast laid à l'appel.
  //
  // Notes de conversion :
  //   - numeric(24, 8) → string côté Supabase (préservation précision)
  //     → Number() pour repasser en number JS
  //   - trade_direction enum → string, cast vers "long" | "short"
  //   - notes nullable → "" pour le state initial (le form s'attend à
  //     un string, et c'est la valeur par défaut en création de toute
  //     façon)
  const initialTrade: TradeFormData & { id: string } = {
    id: trade.id,
    instrument_id: trade.instrument_id,
    direction: trade.direction as "long" | "short",
    entry_price: Number(trade.entry_price),
    quantity: Number(trade.quantity),
    capital: Number(trade.capital),
    notes: trade.notes ?? "",
  };

  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
        <header>
          <h1 className="text-2xl font-semibold tracking-tight">
            Modifier le trade
          </h1>
          <p className="mt-1 text-sm text-neutral-500">
            Ajuste les champs de ton brouillon. Tant que tu ne publies pas,
            tu peux tout modifier librement.
          </p>
        </header>

        <TradeForm
          instruments={(instruments ?? []) as InstrumentOption[]}
          initialTrade={initialTrade}
          mode="edit"
        />

        <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
          Kairo · Phase 2 · édition de brouillon
        </footer>
      </div>
    </main>
  );
}
