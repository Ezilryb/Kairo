// /app/(dashboard)/trades/[id]/replay/page.tsx
// =============================================================================
// Phase 5 — Market Data & Graphismes (whitepaper §08)
// Page serveur : /trades/[id]/replay
// =============================================================================
// Charge le trade + son instrument, puis rend le composant client
// TradeReplay. Le replay n'a pas besoin des events (juste les bougies).
// =============================================================================

import { createClient } from '@/lib/supabase/server';
import { redirect, notFound } from 'next/navigation';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';
import { TradeReplay } from '@/components/market-data/trade-replay';
import { Badge } from '@/components/ui/Badge';

export const dynamic = 'force-dynamic';

export default async function TradeReplayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  // Trade (RLS fait le filtrage user_id)
  const { data: trade } = await supabase
    .from('trades')
    .select('id, user_id, status, opened_at, closed_at, instrument_id')
    .eq('id', id)
    .single();
  if (!trade) notFound();

  // Instrument (lookup séparé)
  const { data: instrument } = await supabase
    .from('instruments')
    .select('symbol, asset_class, name')
    .eq('id', trade.instrument_id)
    .single();
  if (!instrument) notFound();

  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-6xl space-y-6 px-6 py-8">
        <Link
          href={`/trades/${id}`}
          className="inline-flex items-center gap-1 text-sm text-neutral-600 hover:text-neutral-900"
        >
          <ArrowLeft className="h-4 w-4" />
          Retour au trade
        </Link>

        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">
              Replay — {instrument.symbol}
            </h1>
            <p className="mt-1 text-sm text-neutral-500">
              {instrument.name} · {instrument.asset_class}
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Badge tone="neutral">Status: {trade.status}</Badge>
            <Link
              href={`/trades/${id}/chart`}
              className="rounded-md border border-neutral-300 bg-white px-3 py-1 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
            >
              Mode Chart →
            </Link>
          </div>
        </div>

        <TradeReplay
          symbol={instrument.symbol}
          openedAt={trade.opened_at}
          closedAt={trade.closed_at}
          assetClass={instrument.asset_class}
        />
      </div>
    </main>
  );
}
