// /app/(dashboard)/trades/_components/trade-live-edit.tsx
// =============================================================================
// Formulaire d'édition rapide d'un trade `live` PENDANT la fenêtre scalping
// de 60 s suivant la publication (whitepaper §04). Affiché sur la page
// /trades/[id] quand status = 'live' ET now() < published_at + 60s.
//
// Champs éditables ici : entry_price, stop_loss, take_profit, notes.
// Capital et quantity JAMAIS exposés : enforce_capital_immutability
// (Phase 2 Point A) interdit toute augmentation post-pub, et on n'a
// pas de raison d'exposer la diminution (sortie partielle = autre écran,
// Point D+).
//
// Countdown : useEffect + setInterval(1s), calcule le remaining à
// chaque tick. Le serveur passe `initialRemainingSeconds` calculé au
// render pour ne pas afficher "60 s" sur une page déjà à 55 s si le
// render a pris du temps. À 0, le form se désactive et un message
// d'expiration s'affiche. Le composant NE recharge PAS la page tout
// seul à 0 : c'est à l'utilisateur de recharger pour voir la vue
// "verrouillé" (badge statique, plus de form).
//
// Cas limite (Point D) : le user ouvre le form à 58 s, soumet à 61 s.
// Le trigger enforce_entry_price_immutability ou enforce_sl_tp_immutability
// lève une exception, `updateError.message` la contient ("entry_price
// est immuable..." ou "stop_loss / take_profit sont immuables..."), on
// l'affiche telle quelle dans le bandeau d'erreur. Aucun mécanisme
// spécial à inventer, c'est exactement le pattern déjà en place dans
// ProfileForm et TradeForm.
// =============================================================================
"use client";

import { useEffect, useState, useTransition } from "react";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { createClient } from "@/lib/supabase/client";

type LiveEditData = {
  entry_price: number;
  stop_loss: number | null;
  take_profit: number | null;
  notes: string;
};

export function TradeLiveEdit({
  tradeId,
  initialEntryPrice,
  initialStopLoss,
  initialTakeProfit,
  initialNotes,
  initialRemainingSeconds,
}: {
  tradeId: string;
  initialEntryPrice: number;
  initialStopLoss: number | null;
  initialTakeProfit: number | null;
  initialNotes: string;
  initialRemainingSeconds: number;
}) {
  const [remaining, setRemaining] = useState(initialRemainingSeconds);
  const [data, setData] = useState<LiveEditData>({
    entry_price: initialEntryPrice,
    stop_loss: initialStopLoss,
    take_profit: initialTakeProfit,
    notes: initialNotes,
  });
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  // Countdown : 1 tick par seconde. On s'arrête dès que remaining tombe
  // à 0 (le cleanup clearInterval évite de continuer à décrémenter
  // inutilement et garantit qu'on ne re-render pas pour rien).
  useEffect(() => {
    if (remaining <= 0) return;
    const id = setInterval(() => {
      setRemaining((r) => Math.max(0, r - 1));
    }, 1000);
    return () => clearInterval(id);
  }, [remaining]);

  const isExpired = remaining <= 0;
  const validation = validate(data);
  const isValid = Object.keys(validation).length === 0;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (isExpired) {
      setError(
        "La fenêtre scalping est expirée. Recharge la page pour voir le trade verrouillé (les modifs sont refusées par la base).",
      );
      return;
    }
    if (!isValid) {
      setError("Corrige les champs en rouge avant de soumettre.");
      return;
    }
    setError(null);
    startTransition(async () => {
      const supabase = createClient();
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();
      if (userError || !user) {
        setError("Session non chargée.");
        return;
      }

      // .eq("user_id", user.id) : cohérence défense en profondeur avec
      // le pattern appliqué partout (TradeForm edit, publish button,
      // page /trades/[id]/edit). La RLS UPDATE le couvre déjà, mais
      // l'explicite évite de dépendre de la RLS pour distinguer "pas
      // le droit" de "ligne absente".
      const { data: updated, error: updateError } = await supabase
        .from("trades")
        .update({
          entry_price: data.entry_price,
          stop_loss: data.stop_loss,
          take_profit: data.take_profit,
          notes: data.notes || null,
        })
        .eq("id", tradeId)
        .eq("user_id", user.id)
        .select();

      if (updateError) {
        // Le message du trigger remonte tel quel :
        //   - "entry_price est immuable après publication (fenêtre scalping de 60 s expirée)"
        //   - "stop_loss / take_profit sont immuables après la fenêtre scalping de 60 s (whitepaper §04)"
        // Cas typique : user a ouvert le form à 58 s, soumis à 61 s.
        setError(updateError.message);
        return;
      }
      if (!updated || updated.length === 0) {
        setError(
          "Mise à jour refusée (RLS, trade verrouillé, ou ligne absente).",
        );
        return;
      }
      // Reset du countdown : on repart de 60 s pour la prochaine
      // fenêtre ? Non — la fenêtre 60 s est globale depuis published_at,
      // pas reset à chaque modif. Donc on ne touche pas à `remaining`,
      // il continue de descendre vers 0.
      // Si la modif a réussi, on synchronise le state local avec ce
      // que la DB a stocké (utile si la DB a normalisé les valeurs).
      const saved = updated[0];
      setData({
        entry_price: Number(saved.entry_price),
        stop_loss:
          saved.stop_loss === null ? null : Number(saved.stop_loss),
        take_profit:
          saved.take_profit === null ? null : Number(saved.take_profit),
        notes: saved.notes ?? "",
      });
    });
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      <Card>
        <div className="flex items-center justify-between gap-4">
          <div>
            <h2 className="text-sm font-semibold">
              Édition rapide (fenêtre scalping)
            </h2>
            <p className="mt-1 text-xs text-neutral-500">
              Tu peux encore ajuster l&apos;entrée, le SL, le TP et les
              notes. Le capital et la quantité ne sont pas éditables ici
              (sortie partielle = autre écran).
            </p>
          </div>
          <div
            className={[
              "flex-shrink-0 rounded-lg px-3 py-2 text-center font-mono tabular-nums text-sm font-semibold",
              isExpired
                ? "bg-neutral-100 text-neutral-500"
                : remaining <= 15
                  ? "bg-danger-subtle text-danger"
                  : "bg-info-subtle text-info",
            ].join(" ")}
            aria-live="polite"
            aria-label={
              isExpired
                ? "Fenêtre scalping expirée"
                : `Fenêtre scalping : ${remaining} secondes restantes`
            }
          >
            {isExpired ? "Expiré" : `${remaining} s`}
          </div>
        </div>
        {isExpired ? (
          <p
            role="alert"
            className="mt-3 rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-xs text-danger"
          >
            La fenêtre scalping de 60 secondes est expirée. Recharge la
            page pour voir le badge &laquo;&nbsp;verrouillé&nbsp;&raquo;
            — les modifs sont refusées par la base.
          </p>
        ) : null}
      </Card>

      <Card>
        <h2 className="text-sm font-semibold">Champs modifiables</h2>
        <div className="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Field
            id="entry_price"
            label="Prix d'entrée"
            type="number"
            step="any"
            min={0}
            value={data.entry_price}
            // entry_price est NOT NULL en DB et > 0 (CHECK constraint),
            // donc on n'autorise pas null dans le state. Si l'user vide
            // le champ, fallback à 0 et la validation rejette — feedback
            // explicite plutôt qu'un NaN silencieux.
            onChange={(v) =>
              setData((d) => ({ ...d, entry_price: v ?? 0 }))
            }
            error={validation.entry_price}
            disabled={isExpired || pending}
          />
          <Field
            id="stop_loss"
            label="Stop Loss (optionnel)"
            type="number"
            step="any"
            min={0}
            value={data.stop_loss}
            onChange={(v) => setData((d) => ({ ...d, stop_loss: v }))}
            error={validation.stop_loss}
            disabled={isExpired || pending}
          />
          <Field
            id="take_profit"
            label="Take Profit (optionnel)"
            type="number"
            step="any"
            min={0}
            value={data.take_profit}
            onChange={(v) => setData((d) => ({ ...d, take_profit: v }))}
            error={validation.take_profit}
            disabled={isExpired || pending}
          />
        </div>
      </Card>

      <Card>
        <h2 className="text-sm font-semibold">Notes</h2>
        <textarea
          value={data.notes}
          onChange={(e) =>
            setData((d) => ({ ...d, notes: e.target.value }))
          }
          rows={3}
          disabled={isExpired || pending}
          className="mt-3 block w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 focus:border-info focus:outline-none focus:ring-2 focus:ring-info focus:ring-offset-1 disabled:cursor-not-allowed disabled:bg-neutral-50 disabled:text-neutral-500"
          placeholder="Raison d'entrée, contexte, observations…"
        />
      </Card>

      {error ? (
        <div
          role="alert"
          className="rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-sm text-danger"
        >
          {error}
        </div>
      ) : null}

      <div className="flex items-center justify-end gap-2">
        <Button
          type="submit"
          variant="primary"
          disabled={pending || !isValid || isExpired}
          aria-busy={pending}
        >
          {pending ? "Enregistrement…" : "Enregistrer"}
        </Button>
      </div>
    </form>
  );
}

function Field({
  id,
  label,
  type,
  step,
  min,
  value,
  unit,
  onChange,
  error,
  disabled,
}: {
  id: string;
  label: string;
  type: string;
  step?: string;
  min?: number;
  value: number | null;
  unit?: string;
  onChange: (v: number | null) => void;
  error?: string;
  disabled?: boolean;
}) {
  return (
    <div>
      <label
        htmlFor={id}
        className="block text-sm font-medium text-neutral-700"
      >
        {label}
      </label>
      <div className="relative mt-1">
        <input
          id={id}
          type={type}
          step={step}
          min={min}
          value={value === null ? "" : value}
          onChange={(e) => {
            const raw = e.target.value;
            if (raw === "") {
              onChange(null);
              return;
            }
            const v = parseFloat(raw);
            onChange(Number.isFinite(v) ? v : null);
          }}
          disabled={disabled}
          className={[
            "block w-full rounded-lg border bg-white px-3 py-2 pr-8 text-sm text-neutral-900",
            "font-mono tabular-nums",
            "focus:outline-none focus:ring-2 focus:ring-offset-1",
            "disabled:cursor-not-allowed disabled:bg-neutral-50 disabled:text-neutral-500",
            error
              ? "border-danger-border focus:border-danger focus:ring-danger"
              : "border-neutral-300 focus:border-info focus:ring-info",
          ].join(" ")}
        />
        {unit ? (
          <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-sm text-neutral-500">
            {unit}
          </span>
        ) : null}
      </div>
      {error ? <p className="mt-1 text-xs text-danger">{error}</p> : null}
    </div>
  );
}

function validate(d: LiveEditData): Record<string, string> {
  const errs: Record<string, string> = {};
  if (!Number.isFinite(d.entry_price) || d.entry_price <= 0) {
    errs.entry_price = "Doit être strictement positif.";
  }
  if (
    d.stop_loss !== null &&
    (!Number.isFinite(d.stop_loss) || d.stop_loss <= 0)
  ) {
    errs.stop_loss = "Doit être strictement positif ou vide.";
  }
  if (
    d.take_profit !== null &&
    (!Number.isFinite(d.take_profit) || d.take_profit <= 0)
  ) {
    errs.take_profit = "Doit être strictement positif ou vide.";
  }
  return errs;
}
