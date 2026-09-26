// /app/api/trades/[id]/mae-mfe/route.ts
// =============================================================================
// Phase 5 — Market Data & Graphismes (whitepaper §08)
// Endpoint POST /api/trades/[id]/mae-mfe
// =============================================================================
// Flux complet :
//   1. Auth : getUser() via createClient() (lib/supabase/server)
//   2. Charge le trade + check ownership explicite (user_id = user.id) +
//      charge l'instrument (3 requêtes au lieu d'une jointure pour éviter
//      les problèmes d'inférence de type supabase-js v2 et pour court-
//      circuiter le fetch instrument si l'user n'est pas proprio)
//   3. Vérifie que le trade est CLOSED, asset_class='crypto', symbol connu
//      de Binance
//   4. Fetch les bougies via MarketDataProvider.fetchCandlesForTrade()
//   5. Si 0 bougie → return {skipped: true, reason: 'zero_candles'} (on
//      n'invente pas un 0/0 qui ne reflète aucune mesure réelle)
//   6. Calcule MAE/MFE via MarketDataProvider.computeMAE_MFE()
//   7. Persiste via le RPC set_trade_excursion (SECURITY INVOKER, RLS fait
//      le filtrage user_id côté Postgres)
//   8. Retourne {mae, mfe, candles_count, interval} ou {skipped, reason}
//
// IMPORTANT — Contexte d'authentification :
//   On utilise createClient() depuis @/lib/supabase/server, qui lit le cookie
//   de session de la requête et scope le client à l'utilisateur authentifié.
//   Ce n'est PAS createServiceClient() : on veut que set_trade_excursion
//   reçoive un JWT user (et donc auth.uid() côté Postgres) et que la RLS
//   fasse son travail. Si on utilisait service_role par erreur, auth.uid()
//   serait NULL côté SQL et le WHERE du RPC ne matcherait jamais rien —
//   ça échouerait proprement (pas de trou de sécurité), mais le debug
//   serait pénible. Mieux vaut le faire juste du premier coup.
//
// Garde crypto-only des deux côtés (cf. brief §08 point 0) :
//   - Côté client (TradeTransitionButton) : on ne déclenche cet endpoint
//     que si assetClass === 'crypto' (évite un round-trip inutile).
//   - Côté serveur (cet endpoint) : on revérifie asset_class (défense en
//     profondeur — si un futur appelant oublie la vérif client, le
//     serveur dit "non-crypto, skipped", pas de fetch Binance inutile
//     ni d'erreur bruyante).
//
// Codes de réponse typés :
//   200 {mae, mfe, candles_count, interval}        : succès
//   200 {skipped: true, reason: 'non-crypto'}      : trade non-crypto
//   200 {skipped: true, reason: 'zero_candles'}    : aucune bougie retournée
//   401 NON_AUTHENTICATED                          : pas de session
//   404 TRADE_NOT_FOUND                            : trade inexistant ou pas le proprio
//   400 NOT_CLOSED                                 : trade pas encore clôturé
//   422 SYMBOL_NOT_FOUND                           : symbol inconnu chez Binance
//   429 RATE_LIMITED                               : Binance a rate-limité
//   502 UPSTREAM_ERROR                             : autre erreur Binance
//   500 PERSIST_ERROR                              : set_trade_excursion a échoué
//
// runtime = 'nodejs' : le provider utilise fetch et JSON, pas de contrainte
// edge runtime, mais on explicite pour cohérence avec /api/cron/mark-forgotten.
// =============================================================================

import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import {
  marketDataProvider,
  MarketDataError,
} from '@/lib/market-data/provider';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(
  _request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  // -------------------------------------------------------------------------
  // 1. Auth — client SCOPÉ à la session (cookies de la requête), PAS
  //    createServiceClient(). Voir commentaire en tête de fichier.
  // -------------------------------------------------------------------------
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.json(
      { error: 'Non authentifié', code: 'NON_AUTHENTICATED' },
      { status: 401 }
    );
  }

  // -------------------------------------------------------------------------
  // 2. Charger le trade
  // -------------------------------------------------------------------------
  const { id: tradeId } = await params;
  const { data: trade, error: tradeError } = await supabase
    .from('trades')
    .select(
      'id, user_id, direction, entry_price, status, opened_at, closed_at, instrument_id'
    )
    .eq('id', tradeId)
    .single();

  if (tradeError || !trade) {
    return NextResponse.json(
      { error: 'Trade introuvable ou non autorisé', code: 'TRADE_NOT_FOUND' },
      { status: 404 }
    );
  }

  // -------------------------------------------------------------------------
  // 2a. Check ownership EXPLICITE (défense en profondeur, redondant avec
  //     la RLS mais indispensable ici)
  // -------------------------------------------------------------------------
  // Le SELECT précédent ne filtre pas sur user_id : il s'appuie sur la RLS
  // (politique `is_public OR auth.uid() = user_id`). Or `is_public` est
  // `true` par défaut sur les trades — donc n'importe quel user authentifié
  // pourrait POSTer sur /api/trades/<trade-public-d'un-autre>/mae-mfe.
  // Le RPC set_trade_excursion finirait par refuser l'écriture (par son
  // propre check `auth.uid() = v_user_id`), mais uniquement APRÈS qu'on
  // ait consommé un appel Binance réel sur les bougies de quelqu'un
  // d'autre — épuisement du rate-limit partagé de l'app.
  //
  // Le bon pattern est posé partout dans le projet (SQL et maintenant TS) :
  // défense explicite côté appelant, redondante avec la RLS, pour ne pas
  // traverser inutilement le pipeline quand le résultat final sera "non".
  if (trade.user_id !== user.id) {
    return NextResponse.json(
      { error: 'Trade introuvable ou non autorisé', code: 'TRADE_NOT_FOUND' },
      { status: 404 }
    );
  }

  // 2b. Charger l'instrument séparément (cf. commentaire page chart)
  const { data: instrument, error: instrumentError } = await supabase
    .from('instruments')
    .select('symbol, asset_class')
    .eq('id', trade.instrument_id)
    .single();

  if (instrumentError || !instrument) {
    return NextResponse.json(
      { error: 'Instrument introuvable pour ce trade', code: 'TRADE_NOT_FOUND' },
      { status: 404 }
    );
  }

  // -------------------------------------------------------------------------
  // 3. Préconditions
  // -------------------------------------------------------------------------
  if (trade.status !== 'closed') {
    return NextResponse.json(
      {
        error: `Trade non clôturé (status=${trade.status}). MAE/MFE ne se calcule qu'à la clôture.`,
        code: 'NOT_CLOSED',
      },
      { status: 400 }
    );
  }

  // Garde crypto-only (défense en profondeur, cf. commentaire en tête)
  if (instrument.asset_class !== 'crypto') {
    return NextResponse.json({
      skipped: true,
      reason: 'non-crypto',
      message: `asset_class=${instrument.asset_class} non supporté par le stack Phase 5 (crypto only).`,
    });
  }

  // -------------------------------------------------------------------------
  // 4. Fetch bougies via MarketDataProvider
  // -------------------------------------------------------------------------
  let fetchResult: Awaited<
    ReturnType<typeof marketDataProvider.fetchCandlesForTrade>
  >;
  try {
    fetchResult = await marketDataProvider.fetchCandlesForTrade({
      symbol: instrument.symbol,
      opened_at: trade.opened_at,
      closed_at: trade.closed_at,
    });
  } catch (err) {
    if (err instanceof MarketDataError) {
      if (err.code === 'SYMBOL_NOT_FOUND') {
        return NextResponse.json(
          { error: err.message, code: 'SYMBOL_NOT_FOUND' },
          { status: 422 }
        );
      }
      if (err.code === 'RATE_LIMITED') {
        return NextResponse.json(
          { error: err.message, code: 'RATE_LIMITED' },
          { status: 429 }
        );
      }
    }
    console.error('[mae-mfe] fetchCandlesForTrade error:', err);
    return NextResponse.json(
      { error: 'Erreur upstream Binance', code: 'UPSTREAM_ERROR' },
      { status: 502 }
    );
  }

  // -------------------------------------------------------------------------
  // 5. Cas 0 bougie — on n'invente pas un 0/0
  // -------------------------------------------------------------------------
  // Trades très courts (< résolution de la bougie choisie) ou trou
  // ponctuel côté Binance : fetchCandles peut renvoyer []. mae/mfe restent
  // à NULL en base (sémantique "pas encore calculable", déjà en place
  // depuis la Phase 3). On retourne un skipped explicite pour que le
  // client puisse afficher un message au lieu d'un "0/0 calculé" trompeur.
  if (fetchResult.candles.length === 0) {
    console.warn(
      `[mae-mfe] 0 bougie pour trade ${tradeId} ` +
      `(symbol=${instrument.symbol}, opened_at=${trade.opened_at}, ` +
      `closed_at=${trade.closed_at}). MAE/MFE non persistés.`
    );
    return NextResponse.json({
      skipped: true,
      reason: 'zero_candles',
      message: 'Aucune bougie Binance sur la fenêtre du trade. mae/mfe restent NULL.',
    });
  }

  // -------------------------------------------------------------------------
  // 6. Calcul MAE/MFE
  // -------------------------------------------------------------------------
  // computeMAE_MFE retourne null si candles est vide (cf. provider.ts —
  // defense in depth, on n'invente pas un {mae:0, mfe:0} trompeur). En
  // pratique on ne devrait jamais y arriver : le check `length === 0`
  // ci-dessus (étape 5) court-circuite avant. Mais on test quand même
  // (cohérent avec le pattern "défense explicite redondante" du projet) :
  // si on y arrive, c'est qu'un futur refactor a déplacé le check, et
  // on préfère un skipped propre à un crash runtime.
  const maeMfeResult = marketDataProvider.computeMAE_MFE(
    fetchResult.candles,
    trade.entry_price,
    trade.direction
  );
  if (maeMfeResult === null) {
    console.warn(
      `[mae-mfe] computeMAE_MFE a retourné null pour trade ${tradeId} ` +
      `malgré le check length>0 (candles.length=${fetchResult.candles.length}).`
    );
    return NextResponse.json({
      skipped: true,
      reason: 'zero_candles',
      message: 'computeMAE_MFE a retourné null (defense in depth).',
    });
  }
  const { mae, mfe } = maeMfeResult;

  // -------------------------------------------------------------------------
  // 7. Persistance via RPC set_trade_excursion (SECURITY INVOKER, RLS)
  // -------------------------------------------------------------------------
  const { error: rpcError } = await supabase.rpc('set_trade_excursion', {
    p_trade_id: tradeId,
    p_mae: mae,
    p_mfe: mfe,
  });

  if (rpcError) {
    console.error('[mae-mfe] set_trade_excursion error:', rpcError);
    return NextResponse.json(
      { error: 'Erreur persistance MAE/MFE', code: 'PERSIST_ERROR' },
      { status: 500 }
    );
  }

  // -------------------------------------------------------------------------
  // 8. Réponse succès
  // -------------------------------------------------------------------------
  return NextResponse.json({
    trade_id: tradeId,
    mae,
    mfe,
    candles_count: fetchResult.candles.length,
    interval: fetchResult.interval,
  });
}
