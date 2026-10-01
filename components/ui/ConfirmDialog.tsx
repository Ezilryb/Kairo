// /components/ui/ConfirmDialog.tsx
// =============================================================================
// Phase 9 — Finitions UI/UX (audit quick win F1)
// Composant ConfirmDialog — confirmation modale remplaçant le `confirm()`
// natif du navigateur.
//
// Cadrage chef (Phase 9 audit round 4) :
//   "Aligner les confirmations sur le pattern DeleteAccountConfirmation
//    (Card + confirmation explicite), pas un `confirm()` custom qui ne
//    ferait que déplacer le problème."
//
// Pourquoi un composant pur (sans bouton déclencheur interne) :
//   - Le caller garde le contrôle de son bouton et de son état d'ouverture
//     (useState local phase, error, pending) — exactement le pattern Phase 8
//     DeleteAccountConfirmation, mais en version factorisée et réutilisable.
//   - Le caller peut injecter sa propre action async (publish_trade RPC,
//     transition_trade RPC, etc.) sans couplage au composant.
//   - Permet d'ajouter des confirmations futures (changement de statut
//     trade, actions admin, etc.) sans dupliquer le markup.
//
// Différences avec `confirm()` natif :
//   - Visible (le navigateur ne bloque plus le rendu)
//   - Style cohérent avec le design system (Card + Button)
//   - Accessibilité : focus-visible sur les boutons (cf. quick win D1),
//     role="alertdialog" + aria-labelledby / aria-describedby pour les
//     screen readers
//   - Gestion d'erreur intégrée : si onConfirm throw, le dialog reste
//     ouvert avec le message d'erreur (pas de fermeture silencieuse)
//
// Limites connues :
//   - Pas de focus trap (à ajouter si accessibilité audit trouve des
//     problèmes, hors scope Phase 9 — voir TODO_TECHNIQUE.md)
//   - Pas de fermeture par Escape (idem)
//   - Le caller doit gérer son propre state d'ouverture + loading
// =============================================================================
"use client";

import { useEffect, useRef, useState } from "react";
import { Card } from "@/components/ui/Card";
import { Button, type ButtonVariant } from "@/components/ui/Button";

export interface ConfirmDialogProps {
  /** Contrôle l'affichage du dialog. */
  open: boolean;
  /** Callback quand l'utilisateur ferme le dialog (Annuler ou Escape future). */
  onOpenChange: (open: boolean) => void;
  /** Titre court (1 ligne), affiché en gras en haut du dialog. */
  title: string;
  /** Description plus longue, en texte neutre. Peut contenir des sauts de ligne. */
  description: string;
  /** Label du bouton de confirmation (ex : "Publier", "Clôturer", "Archiver"). */
  confirmLabel: string;
  /** Label du bouton d'annulation (défaut : "Annuler"). */
  cancelLabel?: string;
  /** Variant visuel du bouton de confirmation. "danger" par défaut — les
   *  actions irréversibles sont le cas d'usage principal. */
  confirmVariant?: ButtonVariant;
  /**
   * Action async déclenchée par le bouton de confirmation.
   * Si elle throw, le dialog reste ouvert avec le message d'erreur affiché
   * (le caller n'a pas besoin de gérer son propre state d'erreur pour ça).
   */
  onConfirm: () => Promise<void>;
  /**
   * Indicateur de chargement (ex : le caller a son propre pending).
   * Utilisé principalement pour désactiver le bouton pendant l'appel.
   * Si non fourni, le composant gère son propre état loading (true pendant
   * l'exécution de onConfirm).
   */
  loading?: boolean;
  /** Message d'erreur à afficher dans le dialog (ex : retourné par le RPC). */
  errorMessage?: string | null;
}

export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel,
  cancelLabel = "Annuler",
  confirmVariant = "danger",
  onConfirm,
  loading: externalLoading,
  errorMessage,
}: ConfirmDialogProps) {
  // Loading interne : true pendant l'exécution de onConfirm. Si le caller
  // passe son propre loading (externalLoading), on prend cette valeur en
  // priorité — le caller a probablement un useTransition qui couvre
  // déjà son appel.
  //
  // Phase 9 round 5 (bug fix) : useState au lieu de useRef. Muter un ref
  // ne déclenche jamais de re-render → le bouton "Confirmer" ne s'afficherait
  // jamais en état "chargement" tant qu'aucun externalLoading n'est passé.
  // useState force le re-render et permet au dialog de gérer son propre
  // loading correctement.
  const [internalLoading, setInternalLoading] = useState(false);
  const cancelRef = useRef<HTMLButtonElement | null>(null);

  // Focus initial sur le bouton Annuler à l'ouverture — c'est le choix
  // "safe" (l'utilisateur doit confirmer explicitement, pas valider par
  // Entrée par accident). Cohérent avec la convention UX "Annuler est
  // l'option par défaut sauf mention explicite contraire".
  useEffect(() => {
    if (open) {
      // Tick suivant pour laisser le DOM se monter.
      const id = window.setTimeout(() => {
        cancelRef.current?.focus();
      }, 0);
      return () => window.clearTimeout(id);
    }
  }, [open]);

  if (!open) return null;

  const isLoading = externalLoading ?? internalLoading;

  const handleConfirm = async () => {
    setInternalLoading(true);
    try {
      await onConfirm();
      // Si on arrive ici sans throw, on ferme le dialog.
      onOpenChange(false);
    } catch {
      // Le caller a probablement fourni un errorMessage via son propre
      // state (le pattern Phase 8 DeleteAccountConfirmation). On ne fait
      // rien d'autre — le dialog reste ouvert pour que l'utilisateur voie
      // l'erreur et puisse réessayer ou annuler.
    } finally {
      setInternalLoading(false);
    }
  };

  return (
    <div
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="confirm-dialog-title"
      aria-describedby="confirm-dialog-description"
      className="fixed inset-0 z-50 flex items-center justify-center bg-neutral-900/50 px-4"
    >
      <Card padding="lg" className="w-full max-w-md shadow-lg">
        <div className="space-y-4">
          <h3
            id="confirm-dialog-title"
            className="text-base font-semibold"
          >
            {title}
          </h3>
          <p
            id="confirm-dialog-description"
            className="whitespace-pre-line text-sm text-neutral-700"
          >
            {description}
          </p>
          {errorMessage ? (
            <p
              role="alert"
              className="rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-sm text-danger"
            >
              {errorMessage}
            </p>
          ) : null}
          <div className="flex flex-wrap items-center justify-end gap-2">
            <Button
              ref={cancelRef}
              variant="secondary"
              size="md"
              onClick={() => onOpenChange(false)}
              disabled={isLoading}
            >
              {cancelLabel}
            </Button>
            <Button
              variant={confirmVariant}
              size="md"
              onClick={handleConfirm}
              loading={isLoading}
            >
              {confirmLabel}
            </Button>
          </div>
        </div>
      </Card>
    </div>
  );
}
