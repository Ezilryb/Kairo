// /app/(dashboard)/trades/_components/trade-transition-button.tsx
// =============================================================================
// Bouton de transition manuelle pour un trade (clôture, réactivation,
// archivage). Client component utilisé sur la page /trades/[id].
//
// Action effectuée : appel du RPC `public.transition_trade(p_trade_id uuid,
// p_new_status public.trade_status, p_exit_price numeric default null)` qui :
//   - valide que la transition est autorisée selon la table SQL
//   - pose closed_at = now() si transition vers 'closed'
//   - historise dans trade_events avec l'event_type correspondant
//   - laisse le trigger `log_sl_tp_changes` mettre à jour l'activité
//   - calcule le leg final v_final_exit_price / v_leg_pnl et cumule
//     realized_pnl_gross (corps de production relevé par
//     pg_get_functiondef)
//
// Pourquoi un RPC plutôt qu'un .update() direct : le RPC est la
// source de vérité pour la table des transitions autorisées.
//
// Phase 10 — clôture avec prix obligatoire :
//   - targetStatus === 'closed' : la migration 026 refuse
//     p_exit_price NULL ou <= 0. Le dialogue intègre donc un champ
//     de prix (slot `form` du ConfirmDialog), et le bouton Confirmer
//     reste désactivé tant que le prix n'est pas strictement positif
//     (prop `confirmDisabled` du ConfirmDialog).
//   - targetStatus === 'live' ou 'archived' : pas de prix. On envoie
//     pas p_exit_price au RPC (DEFAULT NULL côté fonction).
//   - La saisie accepte virgule OU point (parser partagé
//     lib/forms/parse-numeric-input.ts, identique au formulaire de
//     trade).
//
// Phase 9 round 5 (bug fix) :
//   - `useTransition` retiré pour les mêmes raisons : sa promesse est
//     fire-and-forget, le dialog ConfirmDialog se fermait avant la fin
//     du RPC.
//   - `throw` sur erreur : sinon le mécanisme "dialog reste ouvert si
//     onConfirm throw" de ConfirmDialog ne se déclenchait jamais.
//
// CHAÎNAGE AUTOMATIQUE POST-CLÔTURE (Phase 5, §08 point 4) :
//   Si la transition est vers 'closed' ET l'asset_class de l'instrument
//   est 'crypto' (passé en prop), on déclenche automatiquement le calcul
//   + persistance MAE/MFE via POST /api/trades/[id]/mae-mfe. Fire-and-
//   forget (pas await) : on ne bloque pas l'UX de la transition.
// =============================================================================
"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Button, type ButtonVariant } from "@/components/ui/Button";
import { ConfirmDialog } from "@/components/ui/ConfirmDialog";
import { createClient } from "@/lib/supabase/client";
import { parseNumericInput } from "@/lib/forms/parse-numeric-input";

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
   * on skippe.
   */
  assetClass?: string;
}) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  // Saisie du prix de sortie (uniquement pour targetStatus === "closed").
  // type="text" + parseNumericInput → virgule OU point acceptés, idem
  // formulaire de trade (cf. lib/forms/parse-numeric-input.ts).
  const [priceInput, setPriceInput] = useState("");

  // Variant du bouton de confirmation : archivage = danger (terminal,
  // whitepaper §04), les autres transitions restent primary.
  const confirmVariant: ButtonVariant = targetStatus === "archived" ? "danger" : "primary";

  // La clôture impose un prix strictement positif (migration 026). Pour
  // les autres transitions, pas de prix → pas de condition de désactivation.
  //
  // Distinction explicite saisie vide / saisie invalide :
  //   - vide : pas de message d'erreur, le bouton Confirmer est
  //     désactivé en attendant la saisie.
  //   - non vide + parseNumericInput retourne null : message
  //     "Saisie invalide" sous le champ, le bouton Confirmer
  //     reste désactivé.
  //   - non vide + parseNumericInput retourne un nombre ≤ 0 : message
  //     "Le prix doit être strictement positif" sous le champ, le
  //     bouton Confirmer reste désactivé.
  const parsedPrice = useMemo(
    () => (targetStatus === "closed" && priceInput !== ""
      ? parseNumericInput(priceInput)
      : null),
    [targetStatus, priceInput]
  );
  const isEmptyInput = targetStatus === "closed" && priceInput.trim() === "";
  const isInvalidFormat = targetStatus === "closed"
    && priceInput.trim() !== ""
    && parsedPrice === null;
  const isNonPositive = targetStatus === "closed"
    && parsedPrice !== null
    && parsedPrice <= 0;
  const isPriceValid = targetStatus !== "closed"
    || (parsedPrice !== null && parsedPrice > 0);

  const handleConfirm = async () => {
    if (!isPriceValid) return; // double sécurité : client + base (migration 026)
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

    // Arguments RPC : p_exit_price n'est envoyé que pour la clôture
    // (DEFAULT NULL pour les autres transitions — le RPC refuse déjà
    // p_exit_price si new_status <> 'closed' (contrôle préexistant à
    // la 026), on s'aligne en omettant l'argument côté client).
    const rpcArgs: {
      p_trade_id: string;
      p_new_status: TransitionTarget;
      p_exit_price?: number;
    } = {
      p_trade_id: tradeId,
      p_new_status: targetStatus,
    };
    if (targetStatus === "closed" && parsedPrice !== null && parsedPrice > 0) {
      rpcArgs.p_exit_price = parsedPrice;
    }

    const { data: updated, error: updateError } = await supabase.rpc(
      "transition_trade",
      rpcArgs,
    );

    if (updateError) {
      setError(updateError.message);
      throw new Error(updateError.message);
    }
    if (!updated) {
      const msg = "Transition refusée (réponse vide du serveur).";
      setError(msg);
      throw new Error(msg);
    }
    router.refresh();

    // Chaînage automatique post-clôture (Phase 5, §08 point 4) :
    // fire-and-forget le calcul MAE/MFE si crypto.
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
    setPriceInput("");
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
          if (!open) {
            setError(null);
            setPriceInput("");
          }
        }}
        title={label}
        description={confirmMessage}
        confirmLabel={label}
        confirmVariant={confirmVariant}
        onConfirm={handleConfirm}
        errorMessage={error}
        confirmDisabled={!isPriceValid}
        // Slot intégré au dialogue : champ de prix de sortie pour la
        // clôture uniquement. type="text" + inputMode="decimal" pour
        // accepter virgule OU point. Validation appliquée côté
        // ConfirmDialog (confirmDisabled ci-dessus) et côté RPC
        // (corps de production relevé par pg_get_functiondef) —
        // double sécurité. Pas d'autoFocus : ConfirmDialog replace
        // le focus sur le bouton Annuler au tick suivant, ce qui
        // annulerait l'autoFocus et déclencherait une règle de lint.
        form={
          targetStatus === "closed" ? (
            <div className="rounded-md border border-neutral-200 bg-neutral-50 p-3">
              <label
                htmlFor="exit-price"
                className="block text-sm font-medium text-neutral-700"
              >
                Prix de sortie
              </label>
              <p className="mt-1 text-xs text-neutral-500">
                Saisissez le prix de clôture du trade. Doit être strictement
                positif. La virgule et le point sont acceptés comme
                séparateur décimal.
              </p>
              <input
                id="exit-price"
                type="text"
                inputMode="decimal"
                value={priceInput}
                onChange={(e) => setPriceInput(e.target.value)}
                placeholder="ex : 110,50"
                aria-invalid={isInvalidFormat || isNonPositive}
                aria-describedby={isInvalidFormat || isNonPositive ? "exit-price-error" : undefined}
                className={`mt-2 block w-full rounded-lg border bg-white px-3 py-2 font-mono tabular-nums text-sm text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-1 ${
                  isInvalidFormat || isNonPositive
                    ? "border-danger-border focus-visible:border-danger focus-visible:ring-danger"
                    : "border-neutral-300 focus-visible:border-info focus-visible:ring-info"
                }`}
                autoComplete="off"
              />
              {isInvalidFormat || isNonPositive ? (
                <p
                  id="exit-price-error"
                  role="alert"
                  className="mt-1 text-xs text-danger"
                >
                  {isInvalidFormat
                    ? "Saisie invalide."
                    : "Le prix doit être strictement positif."}
                </p>
              ) : isEmptyInput ? (
                <p className="mt-1 text-xs text-neutral-500">
                  Saisissez un prix pour activer la confirmation.
                </p>
              ) : null}
            </div>
          ) : null
        }
      />
    </div>
  );
}