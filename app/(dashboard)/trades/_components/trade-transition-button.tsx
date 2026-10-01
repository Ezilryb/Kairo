// /app/(dashboard)/trades/_components/trade-transition-button.tsx
// =============================================================================
// Bouton de transition manuelle pour un trade (clôture, réactivation,
// archivage). Client component utilisé sur la page /trades/[id].
//
// Action effectuée : appel du RPC `public.transition_trade(p_trade_id
// uuid, p_new_status public.trade_status)` (cf. migration
// 20260901000003_trade_transitions.sql) qui :
//   - valide que la transition est autorisée selon la table SQL
//   - pose closed_at = now() si transition vers 'closed'
//   - historise dans trade_events avec l'event_type correspondant
//   - laisse le trigger `log_sl_tp_changes` (modifié en Point D pour
//     ne pas écraser last_activity_at au forgotten) mettre à jour
//     l'activité automatiquement
//
// Pourquoi un RPC plutôt qu'un .update() direct : le RPC est la
// source de vérité pour la table des transitions autorisées (cf.
// cadrage Point D). Si on laissait l'UI faire un .update() direct,
// on devrait dupliquer la validation côté client, avec le risque
// que les 2 divergent. Le RPC est SECURITY INVOKER, la RLS s'applique,
// l'UI ne fait qu'invoquer la transition demandée par l'utilisateur.
//
// Phase 9 round 5 (bug fix) : voir TradePublishButton pour le détail.
//   - `useTransition` retiré pour les mêmes raisons : sa promesse est
//     fire-and-forget, le dialog ConfirmDialog se fermait avant la fin
//     du RPC.
//   - `throw` sur erreur : sinon le mécanisme "dialog reste ouvert si
//     onConfirm throw" de ConfirmDialog ne se déclenchait jamais.
//
// Phase 9 round 4 (F1) : confirmation via ConfirmDialog (Card + saisie
// explicite), remplace le `confirm()` natif. Variant du bouton de
// confirmation : archivage = danger (terminal, whitepaper §04), les
// autres transitions restent primary.
//
// L'UI n'affiche QUE les boutons correspondant aux transitions
// valides pour le statut actuel (cf. table des transitions dans la
// migration 03). Pas la peine d'exposer un bouton qui se ferait
// rejeter par construction. Le RPC reste la garde ultime au cas
// où (si quelqu'un ajoute un bouton "transitionner depuis n'importe
// où" sans vérifier, le RPC lèvera "Transition non autorisée").
//
// CHAÎNAGE AUTOMATIQUE POST-CLÔTURE (Phase 5, §08 point 4) :
//   Si la transition est vers 'closed' ET l'asset_class de l'instrument
//   est 'crypto' (passé en prop), on déclenche automatiquement le calcul
//   + persistance MAE/MFE via POST /api/trades/[id]/mae-mfe. Fire-and-
//   forget (pas await) : on ne bloque pas l'UX de la transition (déjà
//   ressentie par l'utilisateur comme "instantanée"). Le user peut
//   naviguer vers /trades/[id]/chart et voir mae/mfe après quelques
//   secondes. Si le calcul échoue, on log (les logs serveur) et le
//   user peut toujours cliquer le bouton manuel sur la page chart.
//
// Garde crypto-only des deux côtés (cf. brief §08) :
//   - Côté client (ce bouton) : on skippe l'appel si assetClass !== 'crypto'
//   - Côté serveur (/api/trades/[id]/mae-mfe) : revérifie asset_class et
//     retourne {skipped: true, reason: 'non-crypto'} (cf. endpoint)
// =============================================================================
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button, type ButtonVariant } from "@/components/ui/Button";
import { ConfirmDialog } from "@/components/ui/ConfirmDialog";
import { createClient } from "@/lib/supabase/client";

// targetStatus est restreint aux valeurs que l'UI est susceptible
// d'exposer (cf. table des transitions valides du RPC). `draft` est
// exclu (la publication passe par publish_trade), `forgotten` est
// exclu (transition automatique via le job OUBLIÉ, pas d'exposition
// manuelle).
export type TransitionTarget = "live" | "closed" | "archived";

export function TradeTransitionButton({
  tradeId,
  targetStatus,
  label,
  confirmMessage,
  variant = "secondary",
  assetClass,
}: {
  tradeId: string;
  targetStatus: TransitionTarget;
  label: string;
  confirmMessage: string;
  variant?: "primary" | "secondary";
  /**
   * Optionnel. Si fourni, et que la transition est vers 'closed', et
   * que assetClass === 'crypto', on déclenche automatiquement le calcul
   * MAE/MFE via /api/trades/[id]/mae-mfe. Si assetClass !== 'crypto',
   * on skippe (les non-crypto n'ont pas de graphique, donc pas de
   * MAE/MFE).
   */
  assetClass?: string;
}) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);

  // Variant du bouton de confirmation : archivage = danger (terminal,
  // whitepaper §04), les autres transitions restent primary (réversibles
  // ou moins structurantes selon la state machine).
  const confirmVariant: ButtonVariant = targetStatus === "archived" ? "danger" : "primary";

  const handleConfirm = async () => {
    setError(null);
    const supabase = createClient();
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();
    if (userError || !user) {
      const msg = "Session non chargée.";
      setError(msg);
      throw new Error(msg);
    }

    // RPC SECURITY INVOKER : la RLS + le filtre user_id du WHERE
    // du RPC s'appliquent via les droits de l'appelant. On n'a
    // pas besoin de .eq("user_id", user.id) ici — c'est le RPC
    // qui filtre. Voir le commentaire en tête de la migration
    // 20260901000003_trade_transitions.sql pour le détail.
    //
    // `rpc` sur une fonction qui retourne `public.trades` (un
    // objet unique) renvoie l'objet directement, pas un tableau.
    // On vérifie `!updated` plutôt que `updated.length === 0`.
    const { data: updated, error: updateError } = await supabase.rpc(
      "transition_trade",
      { p_trade_id: tradeId, p_new_status: targetStatus },
    );

    if (updateError) {
      // Messages possibles (tous en français, déjà lisibles) :
      //   - "Transition non autorisée : X → Y (whitepaper §04)"
      //   - "Trade introuvable ou non autorisé"
      // On remonte tel quel, comme partout ailleurs dans le projet.
      setError(updateError.message);
      throw new Error(updateError.message);
    }
    if (!updated) {
      // Filet de sécurité : rpc n'a pas renvoyé d'erreur mais n'a
      // pas non plus renvoyé la ligne. Ne devrait pas arriver (le
      // RPC lève une exception dans ce cas), mais on reste explicite.
      const msg = "Transition refusée (réponse vide du serveur).";
      setError(msg);
      throw new Error(msg);
    }
    // Refresh serveur : la page re-render avec le nouveau statut,
    // les boutons de transition sont recalculés (les boutons valides
    // changent selon le statut). Pas de router.push (on reste sur
    // la même URL, on ne perd pas le contexte).
    router.refresh();

    // Chaînage automatique post-clôture (Phase 5, §08 point 4) :
    // si transition vers 'closed' et asset crypto, fire-and-forget
    // le calcul + persistance MAE/MFE. L'endpoint revérifie crypto
    // côté serveur (défense en profondeur) et skippe proprement si
    // non. Le user peut voir mae/mfe sur /trades/[id]/chart après
    // quelques secondes. Pas d'await : on ne bloque pas l'UX de la
    // transition.
    if (targetStatus === "closed" && assetClass === "crypto") {
      fetch(`/api/trades/${tradeId}/mae-mfe`, { method: "POST" }).catch(
        (err) => {
          console.error(
            "[TradeTransitionButton] MAE/MFE fire-and-forget failed:",
            err
          );
        }
      );
    }
    // Succès : le dialog se ferme automatiquement (géré par ConfirmDialog
    // après que onConfirm résolve sans throw).
  };

  return (
    <div className="flex flex-col items-end gap-2">
      <Button
        type="button"
        variant={variant}
        onClick={() => setConfirming(true)}
      >
        {label}
      </Button>
      {error && !confirming ? (
        <p role="alert" className="text-xs text-danger">
          {error}
        </p>
      ) : null}
      <ConfirmDialog
        open={confirming}
        onOpenChange={(open) => {
          setConfirming(open);
          if (!open) setError(null);
        }}
        title={label}
        description={confirmMessage}
        confirmLabel={label}
        confirmVariant={confirmVariant}
        onConfirm={handleConfirm}
        errorMessage={error}
      />
    </div>
  );
}
