-- /supabase/migrations/20260903000022_seed_instruments.sql
-- =============================================================================
-- Seed des 6 instruments "vitrine" pour la maquette Phase 10 / Dashboard.
-- =============================================================================
-- Contexte : la table public.instruments, après rattrapage de l'infra
-- (Phase 9 round 6), ne contient qu'une seule ligne résiduelle 'TESTUSD'
-- (utilisée par les suites de tests pgTAP — on n'y touche pas).
-- Phase 10 a besoin d'instruments réels pour que le dropdown
-- `/trades/new` ait des choix cohérents (BTCUSDT, ETHUSDT, AAPL,
-- TSLA, EURUSD, GLD), et pour que les Trades récents du Dashboard
-- affichent des symbols plausibles en démo.
--
-- DÉCISION asset_class / exchange (1 ligne par instrument) :
--   - BTCUSDT, ETHUSDT : crypto, binance (l'exchange crypto le plus
--     courant pour ces symbols sur le marché européen, cohérent avec
--     le seed fee_profiles de la migration 002)
--   - AAPL, TSLA        : stock,  nasdaq (place de cotation US des
--     grandes tech)
--   - EURUSD            : forex,  oanda (broker forex populaire, sert
--     juste d'identifiant d'exchange pour respecter la contrainte
--     unique (symbol, exchange) — NULL serait ambigu, plusieurs
--     lignes NULL = NULL coexisteraient)
--   - GLD               : etf,    arca (NYSE Arca, où SPDR Gold Shares
--     est listé)
--
-- BASE / QUOTE CURRENCY :
--   Renseignés pour les paires crypto et forex où la notion est
--   pertinente. Pour les actions et ETF (capitalisation en USD, pas de
--   notion de paire), on laisse NULL — c'est nullable dans le schéma
--   (cf. 20260821000001_initial_schema.sql:100-102).
--
-- IDEMPOTENCE : `on conflict (symbol, exchange) do nothing` — pattern
-- identique à 002_fee_profiles.sql:108. Permet une ré-exécution
-- manuelle propre si la migration doit être rejouée.
--
-- TESTUSD N'EST PAS TOUCHÉ : il est référencé par les fichiers de tests
-- pgTAP (01_schema_test.sql notamment) via les instrument_id ...0001
-- des trades de setup, le supprimer casserait les régressions tests.
-- =============================================================================

begin;

insert into public.instruments (symbol, name, asset_class, exchange, base_currency, quote_currency) values
  -- Crypto (Binance, cohérent avec seed fee_profiles 002)
  ('BTCUSDT', 'Bitcoin / Tether',      'crypto', 'binance', 'BTC',  'USDT'),
  ('ETHUSDT', 'Ethereum / Tether',     'crypto', 'binance', 'ETH',  'USDT'),
  -- Stocks US (Nasdaq)
  ('AAPL',    'Apple Inc.',            'stock',  'nasdaq',  null,   null),
  ('TSLA',    'Tesla Inc.',            'stock',  'nasdaq',  null,   null),
  -- Forex (Oanda — broker forex populaire, sert juste d'identifiant
  -- d'exchange pour respecter la contrainte unique)
  ('EURUSD',  'Euro / US Dollar',      'forex',  'oanda',   'EUR',  'USD'),
  -- ETF (NYSE Arca)
  ('GLD',     'SPDR Gold Shares',      'etf',    'arca',    null,   null)
on conflict (symbol, exchange) do nothing;

commit;