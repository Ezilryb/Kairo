// /components/account/delete-account-confirmation.tsx
// =============================================================================
// Phase 8 — RGPD & Export/Migration (whitepaper §10 + §11)
// Composant de confirmation de suppression de compte.
//
// Cadrage chef (Phase 8 brief, point 1) :
//   "Confirmation par saisie du pseudo avant d'appeler l'endpoint"
//   → mécanique exacte à l'appréciation du dev. On opte pour un input
//   pseudo + bouton "Supprimer définitivement" actif uniquement quand
//   le pseudo saisi correspond exactement au pseudo de l'utilisateur
//   connecté. Double-friction : un clic accidentel ne supprime rien.
//
// Cadrage chef (Phase 8 round 2, point 5) :
//   "Ce que je ne veux pas, c'est un trou silencieux sur une action
//   aussi irréversible que la suppression de compte." → composant
//   livré cette phase, branché directement sur /api/account/delete.
//
// Pourquoi client component :
//   - State local pour gérer les 3 phases (idle / confirming / submitting)
//   - Fetch côté navigateur pour appeler la route POST /api/account/delete
//   - Validation instantanée du pseudo à chaque frappe
//
// UX et sécurité :
//   - Pas de modale portal complexe (focus trap, escape, etc.) cette
//     phase : un toggle sur une Card de confirmation suffit, on reste
//     dans la même page (pas de navigation). À faire évoluer si on
//     observe des problèmes d'accessibilité en revue UX.
//   - Pas de modale "êtes-vous sûr" non plus (un toggle + un input
//     pseudo + un bouton texte sur deux clics au minimum est déjà
//     une friction largement suffisante pour une action de ce type).
//   - Bouton "Supprimer définitivement" en variant="danger" pour
//     signaler visuellement le caractère irréversible.
//   - Aucune persistance du pseudo saisi (state local React).
//   - Après 204 : on redirige vers /login avec window.location.replace
//     (pas router.push) pour forcer un full reload — la session
//     Supabase est invalidée côté serveur par le DELETE auth.users,
//     un simple push côté client garderait un état mémoire incohérent.
//
// Limites connues :
//   - Pas de confirmation par mot de passe (SSO uniquement, pas de
//     password local). C'est volontaire et explicité dans le brief.
//   - Pas de période de grâce type "annulation sous 30 jours" (le
//     whitepaper ne le décrit pas, hors scope Phase 8).
// =============================================================================
"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";

export interface DeleteAccountConfirmationProps {
  /** Pseudo actuel de l'utilisateur connecté — utilisé pour la double
   *  confirmation par saisie. Requis pour que le bouton ne s'active
   *  qu'avec une correspondance exacte (casse incluse). */
  userPseudo: string;
}

export function DeleteAccountConfirmation({
  userPseudo,
}: DeleteAccountConfirmationProps) {
  const [phase, setPhase] = useState<"idle" | "confirming" | "submitting">(
    "idle",
  );
  const [typedPseudo, setTypedPseudo] = useState("");
  const [error, setError] = useState<string | null>(null);

  // Le bouton "Supprimer définitivement" n'est actif QUE si le pseudo
  // saisi correspond exactement au pseudo de l'utilisateur. Comparaison
  // stricte (===), pas de trim ni de case-insensitive : on veut la
  // friction maximale, pas la commodité.
  const pseudoMatches = typedPseudo === userPseudo;

  const handleSubmit = async () => {
    if (!pseudoMatches) return; // Garde — le bouton est disabled de toute façon.
    setError(null);
    setPhase("submitting");
    try {
      const res = await fetch("/api/account/delete", { method: "POST" });
      if (res.status === 204) {
        // Suppression OK. On force un full reload vers /login pour
        // vider complètement l'état mémoire client (session, stores,
        // caches) et laisser Supabase Auth invalider la session.
        // window.location.replace évite que "Back" ramène à la page
        // supprimée.
        window.location.replace("/login?deleted=1");
        return;
      }
      // Erreur côté serveur — on essaie d'extraire un message.
      let message = "Erreur lors de la suppression.";
      try {
        const body = await res.json();
        if (body?.error) message = body.error;
      } catch {
        // JSON parse fail → on garde le message par défaut.
      }
      setError(message);
      setPhase("confirming");
    } catch (err) {
      console.error("[delete-account] fetch error:", err);
      setError("Erreur réseau. Réessaie dans un instant.");
      setPhase("confirming");
    }
  };

  // ----- Phase idle : juste le bouton "Supprimer mon compte" -----
  if (phase === "idle") {
    return (
      <div>
        <Button
          variant="danger"
          size="md"
          onClick={() => setPhase("confirming")}
        >
          Supprimer mon compte
        </Button>
        <p className="mt-2 text-xs text-neutral-500">
          Action irréversible : ton profil, tes trades, tes commentaires et
          tes likes seront définitivement supprimés.
        </p>
      </div>
    );
  }

  // ----- Phase confirming / submitting : Card de confirmation -----
  return (
    <Card padding="lg" className="border-danger">
      <div className="space-y-4">
        <div>
          <h3 className="text-base font-semibold text-danger">
            Confirmer la suppression du compte
          </h3>
          <p className="mt-1 text-sm text-neutral-700">
            Cette action est <strong>irréversible</strong>. Toutes tes
            données seront supprimées (profil, trades, commentaires, likes,
            relations). Un audit log sera conservé 5 ans pour la
            traçabilité RGPD, mais sans lien actif vers ton compte.
          </p>
        </div>

        <div>
          <label
            htmlFor="confirm-pseudo"
            className="block text-sm font-medium text-neutral-800"
          >
            Pour confirmer, tape ton pseudo&nbsp;:{" "}
            <code className="rounded bg-neutral-100 px-1.5 py-0.5 text-xs">
              {userPseudo}
            </code>
          </label>
          <input
            id="confirm-pseudo"
            type="text"
            value={typedPseudo}
            onChange={(e) => setTypedPseudo(e.target.value)}
            disabled={phase === "submitting"}
            autoComplete="off"
            spellCheck={false}
            autoFocus
            className={[
              "mt-2 block w-full rounded-lg border px-3 py-2 text-sm",
              "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-info focus-visible:ring-offset-2",
              "disabled:cursor-not-allowed disabled:bg-neutral-50",
              pseudoMatches
                ? "border-success"
                : "border-neutral-300",
            ].join(" ")}
            aria-describedby="confirm-pseudo-help"
          />
          <p
            id="confirm-pseudo-help"
            className="mt-1 text-xs text-neutral-500"
          >
            {pseudoMatches
              ? "✓ Pseudo correct. Tu peux confirmer la suppression."
              : "Le pseudo doit correspondre exactement (casse incluse)."}
          </p>
        </div>

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <div className="flex flex-wrap items-center justify-end gap-2">
          <Button
            variant="secondary"
            size="md"
            onClick={() => {
              setPhase("idle");
              setTypedPseudo("");
              setError(null);
            }}
            disabled={phase === "submitting"}
          >
            Annuler
          </Button>
          <Button
            variant="danger"
            size="md"
            onClick={handleSubmit}
            loading={phase === "submitting"}
            disabled={!pseudoMatches || phase === "submitting"}
          >
            Supprimer définitivement
          </Button>
        </div>
      </div>
    </Card>
  );
}
