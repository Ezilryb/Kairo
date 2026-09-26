// /app/(dashboard)/trades/[id]/chart/mae-mfe-button.tsx
// =============================================================================
// Phase 5 — Bouton client pour déclencher le calcul + persistance MAE/MFE
// =============================================================================
// POST /api/trades/[id]/mae-mfe → fetch bougies Binance + calcul côté
// serveur + persistance via set_trade_excursion. Affiche le résultat et
// l'erreur éventuelle. Re-render automatique (router.refresh()) pour
// mettre à jour mae/mfe dans la page parente.
//
// Spinner couvrant toute l'attente : useTransition ne couvre que
// router.refresh() (rapide), pas le fetch (lent — appel Binance réel).
// On a donc un état loading explicite, indépendant de pending, qui est
// armé avant le fetch et libéré dans un finally.
// =============================================================================

'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Calculator } from 'lucide-react';

interface Props {
  tradeId: string;
}

interface MaeMfeSuccess {
  trade_id: string;
  mae: number;
  mfe: number;
  candles_count: number;
  interval: string;
}

interface MaeMfeSkipped {
  skipped: true;
  reason: 'non-crypto' | 'zero_candles';
  message: string;
}

interface MaeMfeError {
  error: string;
  code?: string;
}

type MaeMfeResponse = MaeMfeSuccess | MaeMfeSkipped;

export function MaeMfeButton({ tradeId }: Props) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  // Loading explicite pour le fetch (lent). pending (useTransition)
  // ne couvre que le router.refresh() qui suit — on a besoin des deux.
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<MaeMfeResponse | null>(null);

  // Pendant que l'un OU l'autre est actif → bouton désactivé + spinner.
  const busy = loading || pending;

  const handleClick = async () => {
    setError(null);
    setResult(null);
    setLoading(true);
    try {
      const res = await fetch(`/api/trades/${tradeId}/mae-mfe`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      });
      const json: MaeMfeResponse | MaeMfeError = await res.json();
      if (!res.ok) {
        const err = json as MaeMfeError;
        setError(err.error ?? `HTTP ${res.status}`);
        return;
      }
      setResult(json as MaeMfeResponse);
      // Re-fetch côté serveur pour rafraîchir mae/mfe dans la page
      startTransition(() => {
        router.refresh();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur réseau');
    } finally {
      // finally : libère le spinner quoi qu'il arrive (succès / erreur
      // / exception). Sans ça, une exception laisse loading=true pour
      // toujours.
      setLoading(false);
    }
  };

  return (
    <div className="flex flex-col items-end gap-2">
      <button
        onClick={handleClick}
        disabled={busy}
        className="flex items-center gap-2 rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm font-medium text-neutral-700 hover:bg-neutral-50 disabled:opacity-50"
      >
        {busy ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <Calculator className="h-4 w-4" />
        )}
        {busy ? 'Calcul en cours…' : 'Calculer MAE / MFE'}
      </button>
      {result && 'mae' in result && (
        <p className="text-xs text-neutral-600">
          Persisté : {result.candles_count} bougies, interval=
          {result.interval}
        </p>
      )}
      {result && 'skipped' in result && (
        <p className="text-xs text-neutral-500 italic">
          Skipped : {result.reason} — {result.message}
        </p>
      )}
      {error && (
        <p className="max-w-md text-right text-xs text-danger">{error}</p>
      )}
    </div>
  );
}
