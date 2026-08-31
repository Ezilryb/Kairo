// /app/(dashboard)/trades/new/page.tsx
// =============================================================================
// Page de création d'un trade — affiche le TradeForm en mode "create".
// Server component : on charge la liste des instruments (lecture publique
// côté DB, cf. policy RLS "instruments: lecture publique") et on délègue
// toute l'interaction au client component `TradeForm`.
//
// Pourquoi un server component ici : la liste des instruments est déjà
// connue côté serveur (seedée par la migration Phase 2). Pas besoin
// d'attendre un client pour la fetch, on la prépare au render, on la
// passe en prop. Le TradeForm reste côté client pour le state local du
// formulaire, le `useTransition`, et l'appel `.insert()` authentifié.
//
// Le layout parent `(dashboard)/layout.tsx` garantit qu'on a un user +
// un profil applicatif. On garde un filet de robustesse sur `getUser()`
// au cas où (redirect déjà fait, mais on ne fait pas confiance au
// layout à 100%).
// =============================================================================
import { Card } from "@/components/ui/Card";
import { createClient } from "@/lib/supabase/server";
import { TradeForm, type InstrumentOption } from "../_components/trade-form";

export default async function NewTradePage() {
  const supabase = await createClient();

  // Filet de robustesse : le layout parent redirige normalement vers
  // /login si pas de user, mais si pour une raison quelconque on arrive
  // ici sans user (bug layout, race condition), on rend `null` plutôt que
  // de planter sur les requêtes suivantes.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  // Liste des instruments pour le dropdown. Lecture publique (RLS `using
  // (true)`), donc pas de filtre user_id. Tri par symbol pour une UX
  // prévisible (alphabétique).
  const { data: instruments, error: instrumentsError } = await supabase
    .from("instruments")
    .select("id, symbol, name")
    .order("symbol", { ascending: true });

  // Si la lecture échoue (table inaccessible, etc.), on affiche un message
  // clair plutôt qu'un dropdown vide silencieux. Le bouton de soumission
  // du TradeForm serait désactivé de toute façon (validation
  // `instrument_id` requis), mais autant expliquer pourquoi.
  if (instrumentsError) {
    return (
      <main className="min-h-screen bg-neutral-50">
        <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
          <header>
            <h1 className="text-2xl font-semibold tracking-tight">
              Nouveau trade
            </h1>
          </header>
          <Card>
            <p className="text-sm text-danger">
              Impossible de charger les instruments. Réessaie plus tard.
            </p>
          </Card>
          <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
            Kairo · Phase 2 · création de brouillon
          </footer>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
        <header>
          <h1 className="text-2xl font-semibold tracking-tight">
            Nouveau trade
          </h1>
          <p className="mt-1 text-sm text-neutral-500">
            Crée un brouillon de trade. Tu pourras le publier depuis le
            dashboard une fois les champs remplis (publication = Point C de
            la Phase 2).
          </p>
        </header>

        <TradeForm
          instruments={(instruments ?? []) as InstrumentOption[]}
          mode="create"
        />

        <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
          Kairo · Phase 2 · création de brouillon
        </footer>
      </div>
    </main>
  );
}
