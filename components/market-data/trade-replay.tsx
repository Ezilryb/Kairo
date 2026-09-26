// /components/market-data/trade-replay.tsx
// =============================================================================
// Phase 5 — Market Data & Graphismes (whitepaper §08)
// Composant TradeReplay (client component)
// =============================================================================
// Rejoue l'évolution des bougies sur [opened_at, closed_at] du trade.
// Interface : play/pause, step next/prev, slider pour scrubber manuellement.
//
// Fetch : direct depuis le navigateur vers api.binance.com (CORS OK),
// même provider côté UI que TradeChart. Pas de cache : chaque mount du
// composant refetch (cf. brief §08 — pas de cache préventif).
//
// Si asset_class != 'crypto' → message "non disponible" (cf. TradeChart).
// =============================================================================

'use client';

import { useEffect, useRef, useState, useCallback } from 'react';
import {
  createChart,
  CandlestickSeries,
  type IChartApi,
  type ISeriesApi,
  type Time,
  type CandlestickData,
  type UTCTimestamp,
} from 'lightweight-charts';
import { Play, Pause, SkipBack, SkipForward, Loader2 } from 'lucide-react';
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

export interface TradeReplayProps {
  symbol: string;
  openedAt: string;
  closedAt: string | null;
  assetClass: string;
}

// -----------------------------------------------------------------------------
// Helpers (mêmes règles que TradeChart — on ne dépend pas du provider TS
// côté client, mais on duplique la logique pour éviter un import serveur)
// -----------------------------------------------------------------------------

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

// -----------------------------------------------------------------------------
// Composant
// -----------------------------------------------------------------------------

export function TradeReplay({
  symbol,
  openedAt,
  closedAt,
  assetClass,
}: TradeReplayProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [candles, setCandles] = useState<Candle[]>([]);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [interval, setIntervalState] = useState<Interval>('1h');

  // Refs pour l'animation play/pause (évite stale closures)
  // Note : en React 19 / eslint-plugin-react-hooks ≥ 5, on ne peut plus
  // écrire `ref.current = x` pendant le render. On sync via un useEffect
  // sans deps (s'exécute après chaque render, juste avant le paint).
  const playingRef = useRef(playing);
  const currentIndexRef = useRef(currentIndex);
  useEffect(() => {
    playingRef.current = playing;
  });
  useEffect(() => {
    currentIndexRef.current = currentIndex;
  });

  // -------------------------------------------------------------------------
  // Fetch initial
  // -------------------------------------------------------------------------
  // Note : tous les hooks ci-dessous sont inconditionnels (Rules of Hooks
  // — l'ordre et le nombre de hooks doivent être identiques à chaque
  // render). La garde crypto-only est faite (a) en early return dans
  // chaque effet, et (b) reportée en FIN de composant avant le return
  // final, juste après tous les useCallback.
  useEffect(() => {
    if (assetClass !== 'crypto') return;
    let cancelled = false;
    async function load() {
      setLoading(true);
      setError(null);
      try {
        const start = new Date(openedAt).getTime();
        const end = closedAt ? new Date(closedAt).getTime() : Date.now();
        const chosen = chooseIntervalForDuration(end - start);
        setIntervalState(chosen);
        const data = await fetchCandlesFromBinance(symbol, chosen, start, end);
        if (!cancelled) {
          setCandles(data);
          setCurrentIndex(0);
        }
      } catch (err) {
        if (!cancelled) {
          setError(
            err instanceof Error ? err.message : 'Erreur de chargement'
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
  // Création du chart (1 fois)
  // -------------------------------------------------------------------------
  useEffect(() => {
    if (assetClass !== 'crypto') return;
    if (!containerRef.current) return;
    const chart = createChart(containerRef.current, {
      autoSize: true,
      layout: { background: { color: '#ffffff' }, textColor: '#0a0a0a' },
      grid: {
        vertLines: { color: '#f5f5f5' },
        horzLines: { color: '#f5f5f5' },
      },
      timeScale: { borderColor: '#e5e5e5' },
      rightPriceScale: { borderColor: '#e5e5e5' },
    });
    const series = chart.addSeries(CandlestickSeries, {
      upColor: '#16a34a',
      downColor: '#dc2626',
      borderVisible: false,
      wickUpColor: '#16a34a',
      wickDownColor: '#dc2626',
    });
    seriesRef.current = series;
    chartRef.current = chart;
    return () => {
      chart.remove();
      chartRef.current = null;
      seriesRef.current = null;
    };
    // assetClass dans les deps : si l'user navigue d'un trade crypto
    // vers un trade non-crypto sans unmount (peu probable mais possible
    // via streaming/refresh), on veut recréer le chart avec la bonne
    // garde plutôt que garder un chart stale.
  }, [assetClass]);

  // -------------------------------------------------------------------------
  // Mise à jour des bougies affichées (à chaque currentIndex)
  // -------------------------------------------------------------------------
  useEffect(() => {
    if (!seriesRef.current || candles.length === 0) return;
    const slice = candles.slice(0, currentIndex + 1);
    const data: CandlestickData<Time>[] = slice.map((c) => ({
      time: Math.floor(c.openTime / 1000) as UTCTimestamp,
      open: c.open,
      high: c.high,
      low: c.low,
      close: c.close,
    }));
    seriesRef.current.setData(data);
  }, [candles, currentIndex]);

  // -------------------------------------------------------------------------
  // Animation play/pause (1 bougie / 500ms)
  // -------------------------------------------------------------------------
  useEffect(() => {
    if (!playing) return;
    // On force window.setInterval (overload browser) pour que TypeScript
    // résolve correctement le return type en `number`, ce qui rend
    // clearInterval(number) valide. setInterval global a 2 overloads
    // (Node vs browser) qui embrouillent l'inférence de type ici.
    const handle: number = window.setInterval(() => {
      const next = currentIndexRef.current + 1;
      if (next >= candles.length) {
        setPlaying(false);
        return;
      }
      setCurrentIndex(next);
    }, 500);
    return () => window.clearInterval(handle);
  }, [playing, candles.length]);

  // -------------------------------------------------------------------------
  // Handlers
  // -------------------------------------------------------------------------
  const handlePlayPause = useCallback(() => {
    if (currentIndex >= candles.length - 1) {
      setCurrentIndex(0);
    }
    setPlaying((p) => !p);
  }, [currentIndex, candles.length]);

  const handlePrev = useCallback(() => {
    setPlaying(false);
    setCurrentIndex((i) => Math.max(0, i - 1));
  }, []);

  const handleNext = useCallback(() => {
    setPlaying(false);
    setCurrentIndex((i) => Math.min(candles.length - 1, i + 1));
  }, [candles.length]);

  const handleReset = useCallback(() => {
    setPlaying(false);
    setCurrentIndex(0);
  }, []);

  const handleSliderChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setPlaying(false);
      setCurrentIndex(Number(e.target.value));
    },
    []
  );

  // -------------------------------------------------------------------------
  // Garde-fou : asset_class != 'crypto'
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
            Replay non disponible pour asset_class=
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
          <Badge tone="neutral">Replay {symbol}</Badge>
          <Badge tone="neutral">Interval: {interval}</Badge>
          {loading && (
            <span className="flex items-center gap-1 text-sm text-neutral-500">
              <Loader2 className="h-3 w-3 animate-spin" />
              Chargement…
            </span>
          )}
          {!loading && candles.length > 0 && (
            <span className="text-sm text-neutral-700">
              Bougie {currentIndex + 1} / {candles.length}
            </span>
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
      {!loading && candles.length > 0 && (
        <div className="mt-3 flex items-center gap-3">
          <button
            onClick={handleReset}
            className="rounded-md border border-neutral-300 bg-white px-2 py-1 text-sm text-neutral-700 hover:bg-neutral-50"
            title="Reset"
          >
            ⏮
          </button>
          <button
            onClick={handlePrev}
            disabled={currentIndex === 0}
            className="rounded-md border border-neutral-300 bg-white px-2 py-1 text-sm text-neutral-700 hover:bg-neutral-50 disabled:opacity-50"
            title="Précédent"
          >
            <SkipBack className="h-3 w-3" />
          </button>
          <button
            onClick={handlePlayPause}
            className="flex items-center gap-1 rounded-md border border-neutral-300 bg-white px-3 py-1 text-sm font-medium text-neutral-700 hover:bg-neutral-50"
          >
            {playing ? (
              <>
                <Pause className="h-3 w-3" />
                Pause
              </>
            ) : (
              <>
                <Play className="h-3 w-3" />
                Play
              </>
            )}
          </button>
          <button
            onClick={handleNext}
            disabled={currentIndex >= candles.length - 1}
            className="rounded-md border border-neutral-300 bg-white px-2 py-1 text-sm text-neutral-700 hover:bg-neutral-50 disabled:opacity-50"
            title="Suivant"
          >
            <SkipForward className="h-3 w-3" />
          </button>
          <input
            type="range"
            min={0}
            max={Math.max(0, candles.length - 1)}
            value={currentIndex}
            onChange={handleSliderChange}
            className="flex-1"
          />
        </div>
      )}
    </Card>
  );
}
