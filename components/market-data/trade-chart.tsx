// /components/market-data/trade-chart.tsx
// =============================================================================
// Phase 5 — Market Data & Graphismes (whitepaper §08)
// Composant TradeChart (client component)
// =============================================================================
// Affiche les bougies OHLCV Binance sur [opened_at, closed_at] du trade.
// Deux modes :
//   - Standard : bougies de base + ligne horizontale d'entry/exit
//   - Pro      : + volume (HistogramSeries) + markers pour les events du
//                trade (entry_modified, sl_modified, tp_modified,
//                partial_exit) + capture d'écran (chart.takeScreenshot)
//
// Implémenté en MVP, explicitement stubé hors scope Phase 5 (cf. brief
// §08 + feedback chef 5) :
//   - zones de gain/perte (coloriser la zone entre entry et exit)
//     → demande un AreaSeries custom ou un workaround priceLine — pas
//       une primitive native de lightweight-charts, à traiter dans une
//       itération UI/UX dédiée, sans engagement de numéro de phase
//       précis à ce stade
//   - indicateurs techniques (SMA, EMA, RSI, MACD, …)
//     → demande une lib de calcul (technicalindicators) ou du code
//       custom non trivial — hors scope Phase 5 (stack crypto + MAE/MFE)
//
// Fetch : direct depuis le navigateur vers api.binance.com (CORS autorisé,
// pas besoin de proxy serveur ici). Le calcul + persistance MAE/MFE se
// font via /api/trades/[id]/mae-mfe (endpoint Phase 5) — pas via ce
// composant, qui est en lecture seule.
//
// Si l'asset_class n'est pas 'crypto' (stack Phase 5 = crypto only, cf.
// brief §08), on affiche un message "Graphique non disponible" au lieu
// d'un graphique vide ou d'une erreur silencieuse.
// =============================================================================

'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import {
  createChart,
  createSeriesMarkers,
  CandlestickSeries,
  HistogramSeries,
  LineSeries,
  type IChartApi,
  type ISeriesApi,
  type Time,
  type CandlestickData,
  type HistogramData,
  type SeriesMarker,
  type UTCTimestamp,
} from 'lightweight-charts';
import { Camera, Loader2, TrendingUp, TrendingDown } from 'lucide-react';
import { Card } from '@/components/ui/Card';
import { Badge } from '@/components/ui/Badge';

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

type Candle = {
  openTime: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
  closeTime: number;
};

type Interval = '1m' | '3m' | '5m' | '15m' | '30m' | '1h' | '4h' | '1d' | '1w';

type TradeEvent = {
  event_type:
    | 'entry_modified'
    | 'sl_modified'
    | 'tp_modified'
    | 'partial_exit'
    | 'created'
    | 'published'
    | 'closed'
    | string;
  created_at: string;
  old_values?: Record<string, unknown> | null;
  new_values?: Record<string, unknown> | null;
};

type Mode = 'standard' | 'pro';

export interface TradeChartProps {
  symbol: string;
  direction: 'long' | 'short';
  entryPrice: number;
  exitPrice: number | null;
  openedAt: string;     // ISO timestamptz
  closedAt: string | null;
  events: TradeEvent[];
  assetClass: string;   // 'crypto' | 'stock' | 'forex' | ...
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/**
 * Choisit l'intervalle Binance optimal selon la durée du trade.
 * Doit rester en MIRROR de lib/market-data/provider.ts:chooseIntervalForDuration
 * (côté client, on ne dépend pas du module serveur).
 */
function chooseIntervalForDuration(durationMs: number): Interval {
  const HOUR = 60 * 60 * 1000;
  const DAY = 24 * HOUR;
  const WEEK = 7 * DAY;
  if (durationMs < HOUR) return '1m';
  if (durationMs < DAY) return '5m';
  if (durationMs < WEEK) return '1h';
  return '1d';
}

async function fetchCandlesFromBinance(
  symbol: string,
  interval: Interval,
  startTime: number,
  endTime: number
): Promise<Candle[]> {
  const all: Candle[] = [];
  const seen = new Set<number>();
  let cursor = startTime;
  const end = endTime;

  // Garde-fou pagination
  for (let i = 0; i < 50 && cursor < end; i++) {
    const url =
      `https://api.binance.com/api/v3/klines` +
      `?symbol=${encodeURIComponent(symbol)}` +
      `&interval=${encodeURIComponent(interval)}` +
      `&startTime=${cursor}` +
      `&endTime=${end}` +
      `&limit=1000`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Binance ${res.status} ${res.statusText}`);
    const raw: unknown = await res.json();
    if (!Array.isArray(raw) || raw.length === 0) break;
    for (const row of raw as unknown[]) {
      if (!Array.isArray(row) || row.length < 7) continue;
      const openTime = Number(row[0]);
      if (seen.has(openTime)) continue;
      seen.add(openTime);
      all.push({
        openTime,
        open: Number(row[1]),
        high: Number(row[2]),
        low: Number(row[3]),
        close: Number(row[4]),
        volume: Number(row[5]),
        closeTime: Number(row[6]),
      });
    }
    if ((raw as unknown[]).length < 1000) break;
    cursor = Number((raw as unknown[][])[(raw as unknown[]).length - 1][0]) + 1;
  }
  return all;
}

function eventTypeToMarker(
  eventType: string
): { color: string; shape: SeriesMarker<Time>['shape']; label: string } | null {
  switch (eventType) {
    case 'entry_modified':
      return { color: '#3b82f6', shape: 'arrowUp', label: 'Entry modif' };
    case 'sl_modified':
      return { color: '#f97316', shape: 'arrowDown', label: 'SL modif' };
    case 'tp_modified':
      return { color: '#10b981', shape: 'arrowUp', label: 'TP modif' };
    case 'partial_exit':
      return { color: '#a855f7', shape: 'circle', label: 'Partial exit' };
    default:
      return null;
  }
}

// -----------------------------------------------------------------------------
// Composant
// -----------------------------------------------------------------------------

export function TradeChart({
  symbol,
  direction,
  entryPrice,
  exitPrice,
  openedAt,
  closedAt,
  events,
  assetClass,
}: TradeChartProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const candleSeriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null);
  const volumeSeriesRef = useRef<ISeriesApi<'Histogram'> | null>(null);

  const [mode, setMode] = useState<Mode>('standard');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [interval, setIntervalState] = useState<Interval>('1h');
  const [candles, setCandles] = useState<Candle[]>([]);

  // -------------------------------------------------------------------------
  // Fetch initial des bougies
  // -------------------------------------------------------------------------
  // Note : tous les hooks ci-dessous sont inconditionnels (Rules of Hooks
  // — l'ordre et le nombre de hooks doivent être identiques à chaque
  // render). La garde crypto-only est faite (a) en early return dans
  // chaque effet, et (b) reportée en FIN de composant avant le return
  // final, juste après handleScreenshot.
  useEffect(() => {
    if (assetClass !== 'crypto') return;
    let cancelled = false;
    async function load() {
      setLoading(true);
      setError(null);
      try {
        const start = new Date(openedAt).getTime();
        const end = closedAt
          ? new Date(closedAt).getTime()
          : Date.now();
        const dur = end - start;
        const chosenInterval = chooseIntervalForDuration(dur);
        setIntervalState(chosenInterval);
        const data = await fetchCandlesFromBinance(
          symbol,
          chosenInterval,
          start,
          end
        );
        if (!cancelled) {
          setCandles(data);
        }
      } catch (err) {
        if (!cancelled) {
          setError(
            err instanceof Error
              ? err.message
              : 'Erreur de chargement des bougies'
          );
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [symbol, openedAt, closedAt, assetClass]);

  // -------------------------------------------------------------------------
  // Création du chart
  // -------------------------------------------------------------------------
  useEffect(() => {
    if (assetClass !== 'crypto') return;
    if (!containerRef.current || candles.length === 0) return;

    const chart = createChart(containerRef.current, {
      autoSize: true,
      layout: {
        background: { color: '#ffffff' },
        textColor: '#0a0a0a',
      },
      grid: {
        vertLines: { color: '#f5f5f5' },
        horzLines: { color: '#f5f5f5' },
      },
      timeScale: {
        borderColor: '#e5e5e5',
      },
      rightPriceScale: {
        borderColor: '#e5e5e5',
      },
    });

    const candleSeries = chart.addSeries(CandlestickSeries, {
      upColor: '#16a34a',
      downColor: '#dc2626',
      borderVisible: false,
      wickUpColor: '#16a34a',
      wickDownColor: '#dc2626',
    });
    candleSeriesRef.current = candleSeries;

    // Volume (mode Pro uniquement)
    let volumeSeries: ISeriesApi<'Histogram'> | null = null;
    if (mode === 'pro') {
      volumeSeries = chart.addSeries(HistogramSeries, {
        color: '#a3a3a3',
        priceFormat: { type: 'volume' },
        priceScaleId: 'volume',
      });
      volumeSeries.priceScale().applyOptions({
        scaleMargins: { top: 0.8, bottom: 0 },
      });
      volumeSeriesRef.current = volumeSeries;
    } else {
      volumeSeriesRef.current = null;
    }

    // Données bougies (format lightweight-charts)
    const candleData: CandlestickData<Time>[] = candles.map((c) => ({
      time: Math.floor(c.openTime / 1000) as UTCTimestamp,
      open: c.open,
      high: c.high,
      low: c.low,
      close: c.close,
    }));
    candleSeries.setData(candleData);

    if (volumeSeries) {
      const volumeData: HistogramData<Time>[] = candles.map((c) => ({
        time: Math.floor(c.openTime / 1000) as UTCTimestamp,
        value: c.volume,
        color: c.close >= c.open ? '#16a34a' : '#dc2626',
      }));
      volumeSeries.setData(volumeData);
    }

    // -------------------------------------------------------------------------
    // Lignes horizontales : entry + exit
    // -------------------------------------------------------------------------
    // Construction séparée entry/exit (pas de fusion + filtre par valeur) :
    // si entryPrice === exitPrice (trade at break-even, cas réel), le
    // filtre par valeur matchait les 4 points pour chaque ligne →
    // timestamps dupliqués rejetés ou mal rendus par lightweight-charts.
    // On construit deux LineData[] distinctes dès le départ.
    const startTime = Math.floor(candles[0].openTime / 1000) as UTCTimestamp;
    const endTime = Math.floor(
      candles[candles.length - 1].closeTime / 1000
    ) as UTCTimestamp;

    const lineColor = direction === 'long' ? '#16a34a' : '#dc2626';
    const entryLine = chart.addSeries(LineSeries, {
      color: lineColor,
      lineWidth: 2,
      lineStyle: 0, // solid
      priceLineVisible: false,
      lastValueVisible: true,
      title: `Entry ${entryPrice}`,
    });
    entryLine.setData([
      { time: startTime, value: entryPrice },
      { time: endTime, value: entryPrice },
    ]);

    if (exitPrice != null) {
      const exitLine = chart.addSeries(LineSeries, {
        color: '#0a0a0a',
        lineWidth: 2,
        lineStyle: 2, // dashed
        priceLineVisible: false,
        lastValueVisible: true,
        title: `Exit ${exitPrice}`,
      });
      exitLine.setData([
        { time: startTime, value: exitPrice },
        { time: endTime, value: exitPrice },
      ]);
    }

    // -------------------------------------------------------------------------
    // Markers pour les events (entry/sl/tp modifs, partial exits)
    // -------------------------------------------------------------------------
    const markers: SeriesMarker<Time>[] = [];
    for (const ev of events) {
      const meta = eventTypeToMarker(ev.event_type);
      if (!meta) continue;
      const ts = new Date(ev.created_at).getTime() / 1000;
      if (ts < startTime || ts > endTime) continue;
      markers.push({
        time: ts as UTCTimestamp,
        position:
          meta.shape === 'arrowDown' ? 'aboveBar' : 'belowBar',
        color: meta.color,
        shape: meta.shape,
        text: meta.label,
      });
    }
    if (markers.length > 0) {
      // v5 : setMarkers n'existe plus sur la série, on utilise le plugin
      // createSeriesMarkers qui retourne un ISeriesMarkersPluginApi. Pour le
      // MVP on instancie le plugin à chaque re-render (léger, ~50 markers
      // max par trade) — pas de besoin de garder la ref pour setMarkers([]).
      createSeriesMarkers(candleSeries, markers);
    }

    chart.timeScale().fitContent();
    chartRef.current = chart;

    return () => {
      chart.remove();
      chartRef.current = null;
      candleSeriesRef.current = null;
      volumeSeriesRef.current = null;
    };
  }, [candles, mode, entryPrice, exitPrice, direction, events, assetClass]);

  // -------------------------------------------------------------------------
  // Capture d'écran (mode Pro)
  // -------------------------------------------------------------------------
  const handleScreenshot = useCallback(() => {
    if (!chartRef.current) return;
    const canvas = chartRef.current.takeScreenshot();
    const dataUrl = canvas.toDataURL('image/png');
    const link = document.createElement('a');
    link.download = `trade-${symbol}-${new Date().toISOString().slice(0, 10)}.png`;
    link.href = dataUrl;
    link.click();
  }, [symbol]);

  // -------------------------------------------------------------------------
  // Garde-fou : asset_class != 'crypto' → message explicite (cf. brief)
  // -------------------------------------------------------------------------
  // Posée ICI (après tous les hooks, juste avant le return final) pour
  // respecter les Rules of Hooks : l'ordre et le nombre de hooks doivent
  // être identiques à chaque render. Les early return `if (assetClass !==
  // 'crypto') return;` en tête de chaque useEffect évitent quant à eux
  // un fetch Binance inutile dans le scénario de garde.
  if (assetClass !== 'crypto') {
    return (
      <Card className="p-6">
        <div className="flex items-center gap-2 text-neutral-700">
          <Badge tone="neutral">Non supporté</Badge>
          <span>
            Graphique non disponible pour asset_class=
            <code className="mx-1 rounded bg-neutral-100 px-1.5 py-0.5 text-sm">
              {assetClass}
            </code>
            . Le stack Phase 5 (Binance) couvre uniquement les actifs
            crypto.
          </span>
        </div>
      </Card>
    );
  }

  // -------------------------------------------------------------------------
  // Render
  // -------------------------------------------------------------------------
  return (
    <Card className="p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Badge tone={direction === 'long' ? 'success' : 'danger'}>
            {direction === 'long' ? (
              <TrendingUp className="mr-1 h-3 w-3" />
            ) : (
              <TrendingDown className="mr-1 h-3 w-3" />
            )}
            {direction.toUpperCase()} {symbol}
          </Badge>
          <Badge tone="neutral">Interval: {interval}</Badge>
          {loading && (
            <span className="flex items-center gap-1 text-sm text-neutral-500">
              <Loader2 className="h-3 w-3 animate-spin" />
              Chargement…
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setMode(mode === 'standard' ? 'pro' : 'standard')}
            className="rounded-md border border-neutral-300 bg-white px-3 py-1 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
          >
            {mode === 'standard' ? 'Mode Pro' : 'Mode Standard'}
          </button>
          {mode === 'pro' && (
            <button
              onClick={handleScreenshot}
              className="flex items-center gap-1 rounded-md border border-neutral-300 bg-white px-3 py-1 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
            >
              <Camera className="h-3 w-3" />
              Capture
            </button>
          )}
        </div>
      </div>
      {error ? (
        <div className="flex h-96 items-center justify-center text-sm text-danger">
          Erreur : {error}
        </div>
      ) : (
        <div ref={containerRef} className="h-96 w-full" />
      )}
    </Card>
  );
}
