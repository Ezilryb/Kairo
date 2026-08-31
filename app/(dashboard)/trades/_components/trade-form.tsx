// /app/(dashboard)/trades/_components/trade-form.tsx
// =============================================================================
// Formulaire de création/édition d'un trade en `draft`.
// Client component partagé entre /trades/new (création) et
// /trades/[id]/edit (édition). Le mode est déterminé par la présence
// de `initialTrade` : sans = création, avec = édition.
//
// Composant LOCAL à la feature (sous-dossier `_components/`, préfixe `_`
// pour que Next ne le traite pas comme une route). Ce n'est PAS un
// composant du design system — pas dans `components/ui/`, même pattern
// que `ProfileForm` côté `/profile`. Si on le réutilise ailleurs
// (ex: trade rapide depuis le dashboard), on extraira.
//
// Champs obligatoires du schéma (Point B du cadrage Phase 2) :
//   instrument_id, direction, entry_price, quantity, capital
// Champs persos/psychologie volontairement non exposés ici (vides en
// draft acceptable, à ajouter quand on aura l'écran de métadonnées
// d'un trade). Idem pour leverage (défaut 1) et risk_percent (optionnel).
// =============================================================================
"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { createClient } from "@/lib/supabase/client";

export type InstrumentOption = {
  id: string;
  symbol: string;
  name: string;
};

export type TradeFormData = {
  instrument_id: string;
  direction: "long" | "short";
  entry_price: number;
  quantity: number;
  capital: number;
  notes: string;
};

const EMPTY: TradeFormData = {
  instrument_id: "",
  direction: "long",
  entry_price: 0,
  quantity: 0,
  capital: 0,
  notes: "",
};

export function TradeForm({
  instruments,
  initialTrade,
  mode,
}: {
  instruments: InstrumentOption[];
  initialTrade?: TradeFormData;
  mode: "create" | "edit";
}) {
  const router = useRouter();
  // Pas de présélection d'instrument par défaut : sur un journal de trading,
  // l'actif est la donnée la plus structurante de l'entrée, un défaut
  // silencieux (ex: AAPL via order("symbol")) pollue la base sans qu'on
  // s'en aperçoive. L'option placeholder disabled dans le <select> +
  // la validation `!d.instrument_id` déjà en place suffisent à bloquer
  // la soumission tant que l'utilisateur n'a pas fait un choix explicite.
  const [data, setData] = useState<TradeFormData>(
    initialTrade ?? { ...EMPTY, instrument_id: "" },
  );
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const validation = validate(data);
  const isValid = Object.keys(validation).length === 0;

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!isValid) {
      setError("Corrige les champs en rouge avant de soumettre.");
      return;
    }
    setError(null);
    startTransition(async () => {
      const supabase = createClient();
      const { data: { user }, error: userError } = await supabase.auth.getUser();
      if (userError || !user) {
        setError("Session non chargée.");
        return;
      }

      // On envoie la forme "propre" — c'est createClient qui fait le .select()
      // pour détecter les blocages RLS silencieux (cf. lesson Phase 1).
      if (mode === "create") {
        const { data: inserted, error: insertError } = await supabase
          .from("trades")
          .insert({
            user_id: user.id,
            instrument_id: data.instrument_id,
            direction: data.direction,
            entry_price: data.entry_price,
            quantity: data.quantity,
            capital: data.capital,
            notes: data.notes || null,
            status: "draft",
          })
          .select();
        if (insertError) {
          setError(insertError.message);
          return;
        }
        if (!inserted || inserted.length === 0) {
          setError("Création refusée (RLS ou ligne absente).");
          return;
        }
        router.push("/");
        router.refresh();
      } else {
        // mode === "edit" — on n'autorise l'update que si le trade est encore
        // en draft (cf. policies RLS et logique métier : un trade live n'est
        // pas modifiable via ce form, il faut passer par les autres
        // écrans). Côté DB, la policy RLS update existe pour son propre
        // user_id, mais les triggers métier (enforce_entry_price, etc.)
        // peuvent aussi bloquer selon le statut.
        //
        // Le `.eq("user_id", user.id)` est redondant avec la policy RLS
        // ("auth.uid() = user_id") mais explicite : on ne dépend pas de la
        // RLS pour distinguer "j'ai pas le droit" de "la ligne n'existe
        // pas", et on reste aligné sur le pattern défense en profondeur
        // appliqué dans la page /trades/[id]/edit (cf. commentaire dédié).
        const { data: updated, error: updateError } = await supabase
          .from("trades")
          .update({
            instrument_id: data.instrument_id,
            direction: data.direction,
            entry_price: data.entry_price,
            quantity: data.quantity,
            capital: data.capital,
            notes: data.notes || null,
          })
          .eq("id", initialTrade ? (initialTrade as TradeFormData & { id?: string }).id ?? "" : "")
          .eq("user_id", user.id)
          .select();
        if (updateError) {
          setError(updateError.message);
          return;
        }
        if (!updated || updated.length === 0) {
          setError("Mise à jour refusée (RLS, trade non-draft, ou ligne absente).");
          return;
        }
        router.push("/");
        router.refresh();
      }
    });
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      <Card>
        <h2 className="text-sm font-semibold">Instrument</h2>
        <p className="mt-1 text-xs text-neutral-500">
          Choisis l'actif sur lequel porte le trade. Sélectionne parmi les
          instruments du seed — l'intégration Binance/CoinGecko viendra en
          Phase 5.
        </p>
        <div className="mt-3">
          <label htmlFor="instrument" className="block text-sm font-medium text-neutral-700">
            Instrument
          </label>
          <select
            id="instrument"
            value={data.instrument_id}
            onChange={(e) => setData((d) => ({ ...d, instrument_id: e.target.value }))}
            className={[
              "mt-1 block w-full rounded-lg border bg-white px-3 py-2 text-sm text-neutral-900",
              "focus:outline-none focus:ring-2 focus:ring-offset-1",
              validation.instrument_id
                ? "border-danger-border focus:border-danger focus:ring-danger"
                : "border-neutral-300 focus:border-info focus:ring-info",
            ].join(" ")}
            required
          >
            {instruments.length === 0 ? (
              <option value="">Aucun instrument disponible</option>
            ) : (
              <>
                {/* Placeholder disabled : empêche l'utilisateur de re-sélectionner
                    l'état initial après avoir choisi, et bloque la validation
                    HTML native (required) tant qu'aucun instrument réel n'est
                    sélectionné. La validation TS `!d.instrument_id` fait le
                    reste côté state. */}
                <option value="" disabled>
                  — Choisis un instrument —
                </option>
                {instruments.map((i) => (
                  <option key={i.id} value={i.id}>
                    {i.symbol} — {i.name}
                  </option>
                ))}
              </>
            )}
          </select>
          {validation.instrument_id ? (
            <p className="mt-1 text-xs text-danger">{validation.instrument_id}</p>
          ) : null}
        </div>
      </Card>

      <Card>
        <h2 className="text-sm font-semibold">Position</h2>
        <div className="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div>
            <label className="block text-sm font-medium text-neutral-700">Direction</label>
            <div className="mt-1 flex gap-2">
              {(["long", "short"] as const).map((d) => (
                <label
                  key={d}
                  className={[
                    "flex flex-1 cursor-pointer items-center justify-center gap-2 rounded-lg border px-3 py-2 text-sm font-medium",
                    "transition-colors",
                    data.direction === d
                      ? "border-info bg-info-subtle text-info"
                      : "border-neutral-300 bg-white text-neutral-700 hover:bg-neutral-50",
                  ].join(" ")}
                >
                  <input
                    type="radio"
                    name="direction"
                    value={d}
                    checked={data.direction === d}
                    onChange={() => setData((prev) => ({ ...prev, direction: d }))}
                    className="sr-only"
                  />
                  {d === "long" ? "Long" : "Short"}
                </label>
              ))}
            </div>
          </div>
          <Field
            id="entry_price"
            label="Prix d'entrée"
            type="number"
            step="any"
            min={0}
            value={data.entry_price}
            onChange={(v) => setData((d) => ({ ...d, entry_price: v }))}
            error={validation.entry_price}
          />
          <Field
            id="quantity"
            label="Quantité"
            type="number"
            step="any"
            min={0}
            value={data.quantity}
            onChange={(v) => setData((d) => ({ ...d, quantity: v }))}
            error={validation.quantity}
          />
          <Field
            id="capital"
            label="Capital engagé"
            type="number"
            step="any"
            min={0}
            value={data.capital}
            onChange={(v) => setData((d) => ({ ...d, capital: v }))}
            error={validation.capital}
            unit="€"
          />
        </div>
      </Card>

      <Card>
        <h2 className="text-sm font-semibold">Notes (optionnel)</h2>
        <p className="mt-1 text-xs text-neutral-500">
          Setup, contexte du trade, raison d'entrée… — les champs psychologiques
          (émotion, stress, confiance) seront remplis plus tard.
        </p>
        <textarea
          value={data.notes}
          onChange={(e) => setData((d) => ({ ...d, notes: e.target.value }))}
          rows={3}
          className="mt-3 block w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 focus:border-info focus:outline-none focus:ring-2 focus:ring-info focus:ring-offset-1"
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
          type="button"
          variant="secondary"
          onClick={() => router.push("/")}
          disabled={pending}
        >
          Annuler
        </Button>
        <Button
          type="submit"
          variant="primary"
          disabled={pending || !isValid}
          aria-busy={pending}
        >
          {pending
            ? mode === "create"
              ? "Création…"
              : "Enregistrement…"
            : mode === "create"
              ? "Créer le brouillon"
              : "Enregistrer"}
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
}: {
  id: string;
  label: string;
  type: string;
  step?: string;
  min?: number;
  value: number;
  unit?: string;
  onChange: (v: number) => void;
  error?: string;
}) {
  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-neutral-700">
        {label}
      </label>
      <div className="relative mt-1">
        <input
          id={id}
          type={type}
          step={step}
          min={min}
          value={value || ""}
          onChange={(e) => {
            const v = parseFloat(e.target.value);
            onChange(Number.isFinite(v) ? v : 0);
          }}
          className={[
            "block w-full rounded-lg border bg-white px-3 py-2 pr-8 text-sm text-neutral-900",
            "font-mono tabular-nums",
            "focus:outline-none focus:ring-2 focus:ring-offset-1",
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

function validate(d: TradeFormData): Record<string, string> {
  const errs: Record<string, string> = {};
  if (!d.instrument_id) {
    errs.instrument_id = "Sélectionnez un instrument.";
  }
  if (!Number.isFinite(d.entry_price) || d.entry_price <= 0) {
    errs.entry_price = "Doit être strictement positif.";
  }
  if (!Number.isFinite(d.quantity) || d.quantity <= 0) {
    errs.quantity = "Doit être strictement positif.";
  }
  if (!Number.isFinite(d.capital) || d.capital < 0) {
    errs.capital = "Doit être positif ou nul.";
  }
  return errs;
}
