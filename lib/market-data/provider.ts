// /lib/market-data/provider.ts
// =============================================================================
// Phase 5 — Market Data & Graphismes (whitepaper §08)
// MarketDataProvider : module serveur, source unique pour bougies + MAE/MFE
// =============================================================================
// Sources (cf. brief chef Phase 5) :
//   - Binance public REST = source PRIMAIRE pour bougies OHLCV (klines).
//     Les 2 symboles crypto seedés (BTCUSDT, ETHUSDT) sont déjà au format
//     Binance — pas de mapping nécessaire pour ces 2 lignes.
//   - CoinGecko free API = source SECONDAIRE (contexte prix/market cap).
//     Ne fournit PAS de bougies OHLCV fiables → non utilisé pour les
//     charts/replay/MAE-MFE. Stub ci-dessous, TODO si besoin futur.
//
// Pas de cache de bougies en DB pour ce MVP (cf. brief) : fetch à la demande
// à chaque besoin. Si rate-limit Binance devient un vrai problème, on
// introduira un cache — pas préventivement.
//
// API Binance klines :
//   GET https://api.binance.com/api/v3/klines
//     ?symbol=BTCUSDT
//     &interval=1h
//     &startTime=1499040000000   (ms epoch)
//     &endTime=1499644799999
//     &limit=1000                (max par requête)
//
//   Retour : [[openTime, open, high, low, close, volume, closeTime, ...], ...]
//
// Limites : 1000 bougies/req, ~1200 req/min. Le choix de l'intervalle
// (voir chooseInterval ci-dessous) garantit qu'on reste sous 1000 bougies
// pour un trade de durée typique (< 1 semaine).
// =============================================================================

export type Interval =
  | '1m' | '3m' | '5m' | '15m' | '30m'
  | '1h' | '2h' | '4h' | '6h' | '8h' | '12h'
  | '1d' | '3d' | '1w' | '1M';

export type Candle = {
  /** ms epoch (UTC) */
  openTime: number;
  /** prix d'ouverture de la bougie */
  open: number;
  /** plus haut atteint pendant la bougie */
  high: number;
  /** plus bas atteint pendant la bougie */
  low: number;
  /** prix de clôture de la bougie */
  close: number;
  /** volume tradé pendant la bougie (en asset de base) */
  volume: number;
  /** ms epoch (UTC) */
  closeTime: number;
};

const BINANCE_BASE_URL = 'https://api.binance.com/api/v3';
const MAX_BINANCE_CANDLES_PER_REQUEST = 1000;
const REQUEST_TIMEOUT_MS = 10_000;

// Map statique Binance symbol → CoinGecko id (pour le stub secondaire).
// 2 lignes crypto ne justifient pas une colonne DB dédiée, une constante
// ici suffit. À revoir si le catalogue d'instruments grossit.
const COINGECKO_ID_BY_BINANCE_SYMBOL: Record<string, string> = {
  BTCUSDT: 'bitcoin',
  ETHUSDT: 'ethereum',
};

export class MarketDataProvider {
  private readonly baseUrl: string;

  constructor(baseUrl: string = BINANCE_BASE_URL) {
    this.baseUrl = baseUrl;
  }

  // ---------------------------------------------------------------------------
  // 1. fetchCandles — bougie OHLCV Binance
  // ---------------------------------------------------------------------------
  /**
   * Fetch les bougies Binance sur [startTime, endTime] (inclusifs aux 2 bornes,
   * on déduplique ensuite par openTime). Gère la pagination si > 1000 bougies :
   * on enchaîne les requêtes avec startTime = openTime_de_la_dernière + 1.
   *
   * @throws si le symbol n'existe pas chez Binance (404 → message explicite
   *         côté caller : "graphique non disponible pour cet actif")
   * @throws si rate-limit dépassé (429) ou timeout
   */
  async fetchCandles(
    symbol: string,
    interval: Interval,
    startTime: Date,
    endTime: Date
  ): Promise<Candle[]> {
    if (startTime.getTime() >= endTime.getTime()) {
      return [];
    }

    const allCandles: Candle[] = [];
    const seenOpenTimes = new Set<number>();
    let cursor = startTime.getTime();
    const end = endTime.getTime();
    let safetyCounter = 0;
    const maxIterations = 50;  // garde-fou anti-boucle infinie

    while (cursor < end && safetyCounter < maxIterations) {
      safetyCounter++;
      const url =
        `${this.baseUrl}/klines` +
        `?symbol=${encodeURIComponent(symbol)}` +
        `&interval=${encodeURIComponent(interval)}` +
        `&startTime=${cursor}` +
        `&endTime=${end}` +
        `&limit=${MAX_BINANCE_CANDLES_PER_REQUEST}`;

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

      let res: Response;
      try {
        res = await fetch(url, { signal: controller.signal });
      } finally {
        clearTimeout(timeoutId);
      }

      if (res.status === 404) {
        throw new MarketDataError(
          `Symbol ${symbol} introuvable chez Binance (404). ` +
          `Pas de graphique pour cet actif (souvent : non-crypto).`,
          'SYMBOL_NOT_FOUND'
        );
      }
      if (res.status === 429) {
        throw new MarketDataError(
          `Binance rate-limit atteint (429) pour ${symbol}. Réessayer dans 1 min.`,
          'RATE_LIMITED'
        );
      }
      if (!res.ok) {
        throw new MarketDataError(
          `Binance API error ${res.status} ${res.statusText} pour ${symbol}`,
          'UPSTREAM_ERROR'
        );
      }

      const raw: unknown = await res.json();
      if (!Array.isArray(raw) || raw.length === 0) break;

      // Format Binance : [openTime, o, h, l, c, v, closeTime, ...]
      const batch: Candle[] = [];
      for (const row of raw as unknown[]) {
        if (!Array.isArray(row) || row.length < 7) continue;
        const openTime = Number(row[0]);
        if (seenOpenTimes.has(openTime)) continue;  // dédup si overlap frontière
        seenOpenTimes.add(openTime);
        batch.push({
          openTime,
          open: Number(row[1]),
          high: Number(row[2]),
          low: Number(row[3]),
          close: Number(row[4]),
          volume: Number(row[5]),
          closeTime: Number(row[6]),
        });
      }

      allCandles.push(...batch);
      if (batch.length < MAX_BINANCE_CANDLES_PER_REQUEST) break;
      cursor = batch[batch.length - 1].openTime + 1;
    }

    return allCandles;
  }

  // ---------------------------------------------------------------------------
  // 2. fetchCandlesForTrade — helper haut-niveau (choisit l'intervalle optimal)
  // ---------------------------------------------------------------------------
  /**
   * Détermine l'intervalle optimal selon la durée du trade, puis fetch
   * les bougies correspondantes. Bornes : opened_at → closed_at (ou now()
   * si le trade est encore live).
   *
   * Mapping durée → interval (cf. brief §08) :
   *   < 1h     → 1m
   *   < 1j     → 5m
   *   < 1 sem  → 1h
   *   ≥ 1 sem  → 1d
   */
  async fetchCandlesForTrade(trade: {
    symbol: string;
    opened_at: string;
    closed_at: string | null;
  }): Promise<{ candles: Candle[]; interval: Interval }> {
    const start = new Date(trade.opened_at);
    const end = trade.closed_at ? new Date(trade.closed_at) : new Date();
    const interval = chooseIntervalForDuration(end.getTime() - start.getTime());
    const candles = await this.fetchCandles(trade.symbol, interval, start, end);
    return { candles, interval };
  }

  // ---------------------------------------------------------------------------
  // 3. fetchMarketContext — stub CoinGecko (secondaire, non implémenté MVP)
  // ---------------------------------------------------------------------------
  /**
   * Contexte marché (prix actuel, market cap, etc.) depuis CoinGecko.
   * STUB pour ce MVP : retourne null avec un warning. À implémenter si
   * besoin futur (ex: indicateur "prix actuel" sur la page détail trade).
   * CoinGecko ne fournit PAS de bougies OHLCV fiables (cf. brief) → ne
   * PAS utilisé pour charts/replay/MAE-MFE.
   */
  async fetchMarketContext(
    binanceSymbol: string
  ): Promise<{ price_usd: number; market_cap_usd: number | null } | null> {
    const cgId = COINGECKO_ID_BY_BINANCE_SYMBOL[binanceSymbol];
    if (!cgId) {
      // Pas dans la map : instrument pas supporté par CoinGecko (ou
      // pas encore mappé). Comportement silencieux.
      return null;
    }
    // TODO Phase 5+ : implémenter le fetch CoinGecko si besoin réel.
    //   GET https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd
    //   Pas implémenté pour le MVP car le brief dit "secondaire, pour
    //   contexte prix/market cap seulement, ne pas s'appuyer dessus pour
    //   les charts". Si on en a besoin, on l'ajoutera ici, sans casser
    //   la signature.
    console.warn(
      `[MarketDataProvider] fetchMarketContext stub pour ${binanceSymbol} ` +
      `(cgId=${cgId}) — non implémenté en Phase 5 MVP`
    );
    return null;
  }

  // ---------------------------------------------------------------------------
  // 4. computeMAE_MFE — calcul local depuis une liste de bougies
  // ---------------------------------------------------------------------------
  /**
   * Calcule MAE (Maximum Adverse Excursion) et MFE (Maximum Favorable
   * Excursion) depuis les bougies d'un trade. Toujours clip à 0 (on ne
   * peut pas avoir d'excursion "négative" : un trade qui va dans le
   * bon sens dès l'open a MAE=0, MFE=0).
   *
   * Formules (cf. brief §08) :
   *   Long  : MFE = max(high) - entry_price
   *           MAE = entry_price - min(low)
   *   Short : MFE = entry_price - min(low)
   *           MAE = max(high) - entry_price
   *
   * Si pas de bougies (marché fermé sur toute la période, ou instrument
   * non supporté) → retourne `null` (et PAS {mae:0, mfe:0} qui
   * suggérerait à tort une mesure valide). Le brief est explicite :
   * "on n'invente pas un 0/0 qui ne reflète aucune mesure réelle" —
   * c'est une mine pour un futur appelant qui oublierait de gérer le
   * cas 0 bougie. L'appelant doit tester le retour null (et
   * l'endpoint /api/trades/[id]/mae-mfe le fait déjà en amont via le
   * garde fetchResult.candles.length === 0).
   */
  computeMAE_MFE(
    candles: Candle[],
    entryPrice: number,
    direction: 'long' | 'short'
  ): { mae: number; mfe: number } | null {
    if (candles.length === 0) {
      return null;
    }

    let maxHigh = candles[0].high;
    let minLow = candles[0].low;
    for (const c of candles) {
      if (c.high > maxHigh) maxHigh = c.high;
      if (c.low < minLow) minLow = c.low;
    }

    let mae: number;
    let mfe: number;
    if (direction === 'long') {
      mfe = maxHigh - entryPrice;
      mae = entryPrice - minLow;
    } else {
      // short
      mfe = entryPrice - minLow;
      mae = maxHigh - entryPrice;
    }

    // Clip à 0 (déférence : on ne peut pas avoir d'excursion négative)
    return {
      mae: Math.max(0, mae),
      mfe: Math.max(0, mfe),
    };
  }
}

// -----------------------------------------------------------------------------
// Helpers exportés
// -----------------------------------------------------------------------------

/**
 * Choisit l'intervalle Binance optimal selon la durée du trade (ms).
 * Mapping durée → interval (cf. brief §08) :
 *   < 1h     → 1m
 *   < 1j     → 5m
 *   < 1 sem  → 1h
 *   ≥ 1 sem  → 1d
 */
export function chooseIntervalForDuration(durationMs: number): Interval {
  const HOUR = 60 * 60 * 1000;
  const DAY = 24 * HOUR;
  const WEEK = 7 * DAY;

  if (durationMs < HOUR) return '1m';
  if (durationMs < DAY) return '5m';
  if (durationMs < WEEK) return '1h';
  return '1d';
}

// -----------------------------------------------------------------------------
// Erreur typée (pour que l'endpoint mae-mfe puisse remonter un code propre)
// -----------------------------------------------------------------------------

export class MarketDataError extends Error {
  constructor(
    message: string,
    public readonly code: 'SYMBOL_NOT_FOUND' | 'RATE_LIMITED' | 'UPSTREAM_ERROR' | 'INVALID_INPUT'
  ) {
    super(message);
    this.name = 'MarketDataError';
  }
}

// -----------------------------------------------------------------------------
// Singleton côté serveur
// -----------------------------------------------------------------------------
export const marketDataProvider = new MarketDataProvider();
