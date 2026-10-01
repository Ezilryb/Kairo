// /app/(dashboard)/trades/[id]/chart/page.tsx
// =============================================================================
// Phase 5 — Market Data & Graphismes (whitepaper §08)
// Page serveur : /trades/[id]/chart
// =============================================================================
// Charge le trade + son instrument + ses events, puis rend le composant
// client TradeChart. Le calcul + persistance MAE/MFE est déclenché
// séparément (POST /api/trades/[id]/mae-mfe), pas depuis cette page.
// =============================================================================

import { createClient } from '@/lib/supabase/server';
import { redirect, notFound } from 'next/navigation';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';
import { TradeChart } from '@/components/market-data/trade-chart';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';
import { MaeMfeButton } from './mae-mfe-button';

export const dynamic = 'force-dynamic';

export default async function TradeChartPage({
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
    .select(
      'id, user_id, direction, entry_price, exit_price, status, opened_at, closed_at, instrument_id, mae, mfe'
    )
    .eq('id', id)
    .single();
  if (!trade) notFound();

  // Instrument (lookup séparé pour éviter les soucis d'inférence de
  // type avec les jointures supabase-js v2, cf. TODO_TECHNIQUE)
  const { data: instrument } = await supabase
    .from('instruments')
    .select('symbol, asset_class, name')
    .eq('id', trade.instrument_id)
    .single();
  if (!instrument) notFound();

  // Events pour overlay markers
  const { data: events } = await supabase
    .from('trade_events')
    .select('event_type, created_at, old_values, new_values')
    .eq('trade_id', id)
    .order('created_at', { ascending: true });

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
              Graphique — {instrument.symbol}
            </h1>
            <p className="mt-1 text-sm text-neutral-500">
              {instrument.name} · {instrument.asset_class}
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Badge tone="neutral">Status: {trade.status}</Badge>
            <Link
              href={`/trades/${id}/replay`}
              className="rounded-md border border-neutral-300 bg-white px-3 py-1 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
            >
              Mode Replay →
            </Link>
          </div>
        </div>

        <TradeChart
          symbol={instrument.symbol}
          direction={trade.direction}
          entryPrice={trade.entry_price}
          exitPrice={trade.exit_price}
          openedAt={trade.opened_at}
          closedAt={trade.closed_at}
          events={events ?? []}
          assetClass={instrument.asset_class}
        />

        {/* Carte MAE/MFE : calculable seulement sur trade CLOSED + asset crypto.
            Bouton client qui POST /api/trades/[id]/mae-mfe. */}
        {trade.status === 'closed' && instrument.asset_class === 'crypto' && (
          <Card className="p-4">
            <div className="flex items-center justify-between">
              <div>
                <h2 className="text-lg font-semibold">
                  MAE / MFE
                </h2>
                <p className="text-sm text-neutral-600">
                  Excursions max du trade, calculées depuis les bougies Binance
                  sur [{new Date(trade.opened_at).toISOString().slice(0, 16)} UTC →{' '}
                  {trade.closed_at
                    ? new Date(trade.closed_at).toISOString().slice(0, 16)
                    : 'live'}{' '}
                  UTC].
                </p>
                {trade.mae != null && trade.mfe != null && (
                  <p className="mt-2 text-sm text-neutral-700">
                    <span className="font-medium">MAE</span> ={' '}
                    <code className="rounded bg-neutral-100 px-1.5 py-0.5">
                      {trade.mae}
                    </code>{' '}
                    ·{' '}
                    <span className="font-medium">MFE</span> ={' '}
                    <code className="rounded bg-neutral-100 px-1.5 py-0.5">
                      {trade.mfe}
                    </code>
                  </p>
                )}
              </div>
              <MaeMfeButton tradeId={id} />
            </div>
          </Card>
        )}
      </div>
    </main>
  );
}
