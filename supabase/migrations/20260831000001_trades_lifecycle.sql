-- /supabase/migrations/20260831000001_trades_lifecycle.sql
-- =============================================================================
-- Phase 2 — Journaling & Machine à États des Trades.
-- Contenu :
--   1. enforce_capital_immutability : interdit l'augmentation de `capital`
--      post-publication, autorise la sortie partielle (diminution) et
--      l'égalité. Pas de fenêtre scalping 60s (le whitepaper §04 n'étend
--      la tolérance qu'à entry_price, SL/TP, et champs d'info, pas au
--      capital — l'interdiction d'ajouter du capital est absolue dès
--      la publication).
--   2. log_partial_exits : insère un trade_event `partial_exit` quand
--      `capital` ou `quantity` diminue sur un trade `live`. Jumeau du
--      trigger `log_sl_tp_changes` déjà en place (même pattern, même
--      security definer, même search_path).
--   3. Seed d'instruments : 6 symboles courants (mêmes que les données
--      mockées du dashboard) pour que la Tâche B (sélection instrument)
--      ait quelque chose à proposer sans attendre l'intégration API
--      Binance/CoinGecko (Phase 5).
--
-- Contexte : la migration initiale `20260821000001_initial_schema.sql` est
-- déjà appliquée sur le projet Supabase de production (avec de vrais
-- utilisateurs). On ne la modifie plus — toute évolution passe par une
-- nouvelle migration. Idempotence non requise (la migration s'exécute
-- une fois), mais `on conflict (symbol, exchange) do nothing` sur le
-- seed d'instruments pour permettre une ré-exécution manuelle si besoin.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. enforce_capital_immutability
-- -----------------------------------------------------------------------------
-- Le whitepaper §04 autorise les sorties partielles ("réduction de
-- position") mais interdit d'ajouter du capital à une position publiée.
-- Donc :
--   - old.status <> 'draft' + new.capital >  old.capital → BLOQUÉ (ajout interdit)
--   - new.capital <  old.capital                           → AUTORISÉ (sortie partielle)
--   - new.capital == old.capital                           → AUTORISÉ (pas de changement)
-- ATTENTION : on vérifie `old.status`, pas `new.status`. Si on vérifiait
-- `new.status`, la transition `draft → live` qui s'accompagne d'une
-- augmentation de capital (cas d'usage normal : ajuster sa taille de
-- position au moment de publier) serait bloquée — alors que le whitepaper
-- n'interdit l'ajout de capital qu'aux positions déjà publiées. Le pattern
-- jumeau `enforce_entry_price_immutability` (migration initiale) utilise
-- déjà `old.status` — c'est le bon réflexe.
-- Pas de fenêtre scalping : le verrouillage est immédiat dès la publication.
-- Le trigger s'applique aussi sur closed/forgotten/archived : un trade
-- reste une position historique, on ne peut pas l'augmenter post-pub
-- même après clôture (cohérence comptable).
create or replace function public.enforce_capital_immutability()
returns trigger language plpgsql as $$
begin
  if old.status <> 'draft' and new.capital > old.capital then
    raise exception
      'capital ne peut pas augmenter après publication (whitepaper §04, interdiction d''ajout de capital)';
  end if;
  return new;
end $$;

create trigger trades_enforce_capital_immutability
  before update on public.trades
  for each row execute function public.enforce_capital_immutability();

-- -----------------------------------------------------------------------------
-- 2. log_partial_exits
-- -----------------------------------------------------------------------------
-- Quand capital OU quantity diminue sur un trade `live`, INSERT dans
-- trade_events avec event_type = 'partial_exit'. Pattern strictement
-- identique à log_sl_tp_changes :
--   - security definer : le trigger insert dans trade_events, l'utilisateur
--     courant (authenticated) a la policy RLS INSERT, mais on garde
--     definer pour cohérence avec le trigger jumeau et filet de sécurité
--     contre une policy RLS évolutive
--   - search_path = public : évite les attaques par hijacking du search_path
--     (bonne pratique SECURITY DEFINER)
--   - last_activity_at n'est PAS mis à jour ici : log_sl_tp_changes le
--     fait déjà sur tout UPDATE non-draft (cf. code initial). Pas de
--     double mise à jour, pas de logique dupliquée.
-- Pas de trigger sur closed/forgotten : on ne sort pas d'une position
-- oubliée ou clôturée, c'est un événement lié à un trade vivant.
create or replace function public.log_partial_exits()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.status = 'live' then
    if new.capital < old.capital or new.quantity < old.quantity then
      insert into public.trade_events
        (trade_id, user_id, event_type, old_values, new_values)
      values
        (old.id, old.user_id, 'partial_exit',
         jsonb_build_object(
           'capital', old.capital,
           'quantity', old.quantity
         ),
         jsonb_build_object(
           'capital', new.capital,
           'quantity', new.quantity
         ));
    end if;
  end if;
  return new;
end $$;

create trigger trades_log_partial_exits
  before update on public.trades
  for each row execute function public.log_partial_exits();

-- -----------------------------------------------------------------------------
-- 3. Seed d'instruments
-- -----------------------------------------------------------------------------
-- Mêmes 6 symboles que les données mockées du dashboard, pour que
-- l'UX de la Tâche B (sélection d'instrument) soit cohérente avec ce
-- que les utilisateurs ont déjà vu. base_currency est null pour les
-- stocks/ETFs (pas de notion de paire), quote_currency = USD pour les
-- actions US. crypto et forex ont base+quote explicites.
-- on conflict do nothing : permet une ré-exécution manuelle propre.
insert into public.instruments (symbol, name, asset_class, exchange, base_currency, quote_currency) values
  ('BTCUSDT', 'Bitcoin / US Dollar Tether',  'crypto',  'binance', 'BTC',  'USDT'),
  ('ETHUSDT', 'Ethereum / US Dollar Tether', 'crypto',  'binance', 'ETH',  'USDT'),
  ('AAPL',    'Apple Inc.',                   'stock',   'nasdaq',  null,   'USD'),
  ('TSLA',    'Tesla Inc.',                   'stock',   'nasdaq',  null,   'USD'),
  ('EURUSD',  'Euro / US Dollar',             'forex',   'oanda',   'EUR',  'USD'),
  ('GLD',     'SPDR Gold Shares',             'etf',     'nyse',    null,   'USD')
on conflict (symbol, exchange) do nothing;

commit;
