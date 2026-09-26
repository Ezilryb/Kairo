# Phase 5 — Protocole de test manuel (Market Data & Graphismes)

> **Pourquoi un test manuel et pas pgTAP ?** La Phase 5 est majoritairement
> TypeScript/frontend (MarketDataProvider, composants chart, replay).
> pgTAP ne couvre que la partie SQL — ici, le seul bout SQL est le RPC
> `set_trade_excursion`, déjà couvert par `supabase/tests/05_market_data_test.sql`
> (5 tests pgTAP). Le reste doit être validé visuellement et via
> l'observateur réseau du navigateur, comme on le ferait pour n'importe
> quelle app Next.js.

> **Différence avec le patron Phase 2 (route Cron)** : la route
> `/api/cron/mark-forgotten` est testable en `curl` brut (header
> `Authorization: Bearer $CRON_SECRET` statique). La route
> `/api/trades/[id]/mae-mfe` est authentifiée par session utilisateur
> (cookies SSR de Supabase) — un `curl` ne porterait pas le bon JWT
> sans recopier la session. D'où le passage à un protocole navigateur.

---

## Pré-requis

1. Build OK : `npm run build` (Phase 5 ajoute la dépendance
   `lightweight-charts`).
2. Migrations SQL appliquées dans l'ordre :
   - `supabase/migrations/20260901000001_trades_sl_tp_window.sql`
   - `supabase/migrations/20260901000002_publish_trade_rpc.sql`
   - `supabase/migrations/20260901000003_trade_transitions.sql`
   - `supabase/migrations/20260903000001_exit_price_and_partial_exit_rpc.sql`
   - `supabase/migrations/20260903000002_fee_profiles.sql`
   - `supabase/migrations/20260903000003_financial_calcs.sql`
   - `supabase/migrations/20260903000004_realized_pnl.sql`
   - `supabase/migrations/20260903000005_setup_timeframe.sql`
   - `supabase/migrations/20260903000006_log_entry_price_changes.sql`
   - `supabase/migrations/20260903000007_helpers_derives.sql`
   - `supabase/migrations/20260903000008_plan_adherence_score.sql`
   - `supabase/migrations/20260903000009_analytics_crosstab.sql`
   - `supabase/migrations/20260903000010_crosstab_extra_dimensions.sql`
   - **`supabase/migrations/20260903000011_set_trade_excursion.sql`** (Phase 5)
3. pgTAP test passé : `supabase/tests/05_market_data_test.sql` (5 assertions,
   doit retourner vert).
4. Au moins 1 trade crypto seedé en base (BTCUSDT ou ETHUSDT) et
   au moins 1 trade non-crypto (pour tester la garde).

---

## Test 1 — Chaînage automatique post-clôture (MAE/MFE)

**Objectif** : vérifier qu'à la transition `closed`, le calcul MAE/MFE se
déclenche automatiquement, persiste en base, et apparaît dans la page chart
après quelques secondes.

### Étapes navigateur

1. Connecte-toi à Kairo (cookie de session valide).
2. Navigue vers un trade **live** sur BTCUSDT (ou ETHUSDT), ouvert depuis
   au moins ~1h et ~1h dans le passé (pour que Binance ait des bougies).
3. Ouvre les DevTools → onglet **Network** (filter : `mae-mfe`).
4. Clique sur **"Clôturer le trade"** → confirme.
5. Observe :
   - L'onglet Network montre **immédiatement** (sans reload manuel) une
     requête `POST /api/trades/<id>/mae-mfe`.
   - Le panneau Network affiche une **response 200** avec un body du type :
     ```json
     {
       "trade_id": "...",
       "mae": 1.234,
       "mfe": 5.678,
       "candles_count": 12,
       "interval": "1h"
     }
     ```
6. Dans la base, vérifie la persistance :
   ```sql
   SELECT id, status, mae, mfe
   FROM public.trades
   WHERE id = '<id-du-trade>';
   -- mae et mfe doivent être non NULL
   ```
7. Navigue vers `/trades/<id>/chart`. Le bloc **MAE / MFE** doit afficher
   les valeurs persistées.

### Critères de validation

- [ ] POST mae-mfe déclenché automatiquement (pas de clic manuel sur
  "Calculer MAE/MFE" requis)
- [ ] Response 200 + body conforme
- [ ] mae et mfe persistés en base (`SELECT` confirme)
- [ ] Affichage correct sur `/trades/<id>/chart`

### Cas de défaillance attendus

- **Trade < 1h** (résolution 1m insuffisante) : 200 + body
  `{skipped: true, reason: 'zero_candles', message: '...'}`. mae/mfe restent
  NULL en base. Bouton manuel sur `/chart` permet de retenter.
- **Rate-limit Binance (429)** : 429 + body `{error, code: 'RATE_LIMITED'}`.
  Logger côté serveur, réessayer après 1 min.

---

## Test 2 — Garde crypto-only (asset_class != 'crypto')

**Objectif** : vérifier qu'un trade sur un actif non-crypto (stock, forex,
etc.) ne déclenche PAS le calcul MAE/MFE, et que l'endpoint répond
proprement `skipped: true` au lieu d'une erreur.

### Étapes navigateur

1. Navigue vers un trade **live** sur un instrument **non-crypto** (par
   ex. AAPL, EURUSD, ou tout instrument seedé avec asset_class != 'crypto').
2. Ouvre les DevTools → onglet Network.
3. Clique sur **"Clôturer le trade"** → confirme.
4. Observe :
   - **PAS de requête** `POST /api/trades/<id>/mae-mfe` (le client filtre
     en amont grâce à `assetClass === 'crypto'`).
   - La transition elle-même réussit (status → 'closed').
5. Pour vérifier la garde côté serveur, ouvre une 2e session de DevTools
   ou utilise `curl` avec un cookie de session valide (cookie obtenu via
   login) :
   ```bash
   curl -X POST https://<host>/api/trades/<id>/mae-mfe \
     -H "Cookie: sb-<project>-auth-token=<token>" \
     -H "Content-Type: application/json"
   # Doit retourner 200 + {skipped: true, reason: 'non-crypto', ...}
   ```

### Critères de validation

- [ ] Pas de requête mae-mfe déclenchée par le client
- [ ] Endpoint serveur retourne 200 + `skipped: true, reason: 'non-crypto'`
- [ ] Pas d'erreur dans la console navigateur
- [ ] mae/mfe restent NULL en base (sémantique "pas applicable")

---

## Test 3 — Affichage du graphique (TradeChart)

**Objectif** : vérifier que les bougies s'affichent correctement, que les
lignes entry/exit sont visibles, et que le mode Pro ajoute volume + markers.

### Étapes navigateur

1. Navigue vers `/trades/<id>/chart` pour un trade crypto **closed** (avec
   entry_price connu, exit_price connu si possible).
2. Observe :
   - Les bougies OHLCV s'affichent dans la zone centrale (couleur verte
     pour hausse, rouge pour baisse).
   - La ligne d'entry (verte si long, rouge si short) traverse le
     graphique horizontalement.
   - Si le trade a un exit_price : la ligne d'exit (noire en pointillés)
     apparaît aussi.
3. Clique sur **"Mode Pro"** (en haut à droite) :
   - L'histogramme de volume apparaît en bas du graphique.
   - Si le trade a des events (entry/sl/tp modified, partial_exit) :
     des markers (flèches ou cercles colorés) apparaissent sur les
     bougies concernées.
4. Clique sur **"Capture"** (en mode Pro) :
   - Un fichier PNG nommé `trade-<SYMBOL>-<YYYY-MM-DD>.png` est téléchargé.
   - Ouvre-le : le graphique est intégralement capturé (bougies + lignes
     entry/exit + volume + markers).

### Vérification dédiée des marqueurs d'events (migrés v4 → v5)

**Pourquoi cette section dédiée** : la migration de lightweight-charts
v4.2.3 → v5.2.1 a déplacé la gestion des marqueurs hors du cœur de
l'API (cf. commentaire du chef). En v4 c'était `series.setMarkers()`,
en v5 c'est `createSeriesMarkers(series, markers)` (plugin séparé).
Le TypeScript qui compile ne garantit pas que les marqueurs s'affichent
— il garantit seulement que les signatures sont correctes. Cette étape
vise explicitement à valider le RENDU des marqueurs après la migration.

**Pré-requis** : le trade testé doit avoir au moins 1 event
entry_modified, sl_modified, tp_modified ou partial_exit dans
trade_events. Pour en générer un en dev :
1. Créer un trade crypto (BTCUSDT ou ETHUSDT).
2. Le publier (status → live).
3. Pendant la fenêtre 60s : modifier entry_price ou stop_loss via
   /trades/[id]/edit ou /trades/[id] (si on-window). Ça log un
   `entry_modified` ou `sl_modified` dans trade_events.
4. Alternative : faire une partial_exit (transition vers closed avec
   un exit_price donné, ou un record_partial_exit) → log un
   `partial_exit`.

**Procédure de validation visuelle** :
1. Sur `/trades/<id>/chart` avec un trade qui a ≥ 1 event de marker :
   - En **Mode Standard** : pas de markers visibles (par design, on
     n'affiche les markers qu'en Pro).
   - En **Mode Pro** (cliquer sur "Mode Pro") : les markers
     apparaissent IMMÉDIATEMENT (pas de rechargement manuel de la
     page) au-dessus ou en-dessous des bougies concernées, avec
     un code couleur :
     - `entry_modified` : flèche bleue vers le haut, label "Entry modif"
     - `sl_modified` : flèche orange vers le bas, label "SL modif"
     - `tp_modified` : flèche verte vers le haut, label "TP modif"
     - `partial_exit` : cercle violet, label "Partial exit"
2. Cliquer sur **"Capture"** : vérifier que les markers sont
   également présents dans la capture PNG (sinon, le plugin
   n'aurait pas été inclus dans la layer à exporter).
3. Test de régression critique : si on supprime tous les events
   d'un trade en base, le graphique doit s'afficher SANS marker
   (pas de marker résiduel), et le code de TradeChart ne doit pas
   crasher (la branche `if (markers.length > 0)` avant l'appel à
   `createSeriesMarkers` couvre ce cas).

**Critères de validation marqueurs** :
- [ ] Mode Standard : 0 marker visible
- [ ] Mode Pro : markers présents ET positionnés sur les bonnes
  bougies (timestamp de l'event)
- [ ] Code couleur respecté (cf. tableau ci-dessus)
- [ ] Capture PNG : markers présents
- [ ] Trade sans event : 0 marker, pas de crash

### Critères de validation

- [ ] Bougies visibles
- [ ] Lignes entry/exit positionnées correctement
- [ ] Mode Pro : volume + markers affichés (cf. section dédiée ci-dessus)
- [ ] Capture PNG fonctionnelle
- [ ] En cas d'asset_class non-crypto, message "Graphique non disponible"
  affiché à la place (pas de crash, pas de graphique vide)

---

## Test 4 — Replay du trade (TradeReplay)

**Objectif** : vérifier que le replay permet de scrubber dans l'évolution
des bougies du trade.

### Étapes navigateur

1. Navigue vers `/trades/<id>/replay` pour un trade crypto.
2. Observe :
   - Le graphique s'affiche (vide au début ou avec 1 bougie selon
     currentIndex initial).
   - Le compteur "Bougie 1 / N" s'affiche.
3. Clique sur **"Play"** :
   - Les bougies s'ajoutent une par une (1 bougie / 500ms).
   - Le compteur s'incrémente.
   - En fin de timeline, le play s'arrête automatiquement.
4. Clique sur **"Pause"** puis utilise les boutons **prev/next** et le
   **slider** pour scrubber manuellement.

### Critères de validation

- [ ] Le replay s'anime correctement
- [ ] Le scrub manuel fonctionne (slider, prev/next)
- [ ] Pas de crash si N=0 (cas théorique, trade < résolution bougie)
- [ ] En cas d'asset_class non-crypto, message "Replay non disponible"
  affiché

---

## Test 5 — Bouton manuel de recalcul MAE/MFE

**Objectif** : si le chaînage automatique a échoué (rate-limit, bug, etc.),
le user peut re-déclencher manuellement depuis la page chart.

### Étapes navigateur

1. Navigue vers `/trades/<id>/chart` pour un trade crypto **closed** dont
   mae/mfe sont NULL.
2. Observe le bloc "MAE / MFE" : il affiche "MAE = — · MFE = —" (ou rien
   si pas encore calculé).
3. Clique sur **"Calculer MAE / MFE"** :
   - Le bouton affiche un spinner pendant le calcul.
   - À la fin, la ligne `MAE = X · MFE = Y` apparaît.
   - Un message "Persisté : N bougies, interval=X" s'affiche.
4. Recharge la page : les valeurs sont toujours là (persistées).

### Critères de validation

- [ ] Bouton manuel fonctionne comme l'auto-chaînage
- [ ] Valeurs persistent après reload

---

## Test 6 — Erreurs attendues (smoke tests)

### 6.1 Trade inexistant

```bash
curl -X POST https://<host>/api/trades/00000000-0000-0000-0000-deadbeef0000/mae-mfe \
  -H "Cookie: sb-<project>-auth-token=<token>"
# Doit retourner 404 + {error: 'Trade introuvable ou non autorisé', code: 'TRADE_NOT_FOUND'}
```

### 6.2 Trade live (pas closed)

Crée un trade, garde-le en `live` (ne clôture pas), puis :

```bash
curl -X POST https://<host>/api/trades/<id-live>/mae-mfe \
  -H "Cookie: sb-<project>-auth-token=<token>"
# Doit retourner 400 + {error: 'Trade non clôturé...', code: 'NOT_CLOSED'}
```

### 6.3 Non authentifié

```bash
curl -X POST https://<host>/api/trades/<id>/mae-mfe
# Doit retourner 401 + {error: 'Non authentifié', code: 'NON_AUTHENTICATED'}
```

---

## Sanity check global (avant clôture de phase)

```bash
npm run build
# Doit retourner 0 erreur, ~13 routes statiques/dynamiques (les 11
# préexistantes + /trades/[id]/chart et /trades/[id]/replay).
```

Et :

```sql
-- Dans Supabase SQL Editor, avec les migrations 005→011 appliquées
SELECT proname, pronargs, prorettype::regtype
FROM pg_proc
WHERE proname IN (
  '_direction_multiplier', '_trading_session', '_day_of_week', '_duration_bucket',
  'plan_adherence_score', 'analytics_crosstab',
  'transition_trade', 'record_partial_exit', 'publish_trade',
  'mark_forgotten_trades', 'set_trade_excursion'
)
ORDER BY proname;
-- Doit retourner 11 lignes, dont set_trade_excursion(uuid, numeric, numeric)
```

---

## Limitations connues (à savoir avant validation)

- **Stack crypto only** : les instruments stock/forex/etf n'ont pas de
  graphique / replay / MAE-MFE. Comportement attendu (cf. brief §08
  point 0) : message explicite, pas d'erreur silencieuse.
- **Pas de cache** : chaque mount du composant chart/replay refetch
  Binance. Si tu ouvres 50 charts en parallèle, c'est 50 fetches Binance.
  Pas un problème en MVP, à monitorer.
- **Pas de retry sur rate-limit** : si Binance retourne 429, l'endpoint
  répond 429 au client. Le user peut retenter via le bouton manuel
  sur `/chart`. Pas d'auto-retry pour le MVP.
- **Timeframe fixe par trade** : choisi par la fonction
  `chooseIntervalForDuration` (1h < trade < 1j → 5m, etc.). L'utilisateur
  ne peut pas choisir un autre timeframe via l'UI (pour l'instant).
