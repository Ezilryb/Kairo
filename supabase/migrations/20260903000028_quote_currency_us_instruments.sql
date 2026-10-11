-- /supabase/migrations/20260903000028_quote_currency_us_instruments.sql
-- =============================================================================
-- Phase 10 — quote_currency = 'USD' pour AAPL, TSLA, GLD.
--
-- Contexte : le seed 20260903000022_seed_instruments.sql pose
--   quote_currency = 'USDT' pour BTCUSDT et ETHUSDT,
--   quote_currency = 'USD'  pour EURUSD,
--   quote_currency = NULL  pour AAPL, TSLA, GLD
--                         (NULL dans le seed 022 pour AAPL, TSLA, GLD).
-- Or AAPL, TSLA et GLD sont en réalité cotés en USD : valeurs de la
-- colonne `exchange` du seed 022
-- (migrations/20260903000022_seed_instruments.sql lignes 48, 49, 54) :
--   exchange = 'nasdaq' pour AAPL et TSLA,
--   exchange = 'arca'   pour GLD (SPDR Gold Shares coté sur NYSE Arca).
-- La colonne quote_currency est nullable sans contrainte NOT NULL ni
-- CHECK (cf. 20260821000001_initial_schema.sql lignes 102-103), donc
-- l'update suivant est non destructif et conforme au schéma.
--
-- Périmètre strict : cette migration ne touche QUE les trois lignes
-- AAPL, TSLA, GLD. Aucun autre instrument n'est modifié. TESTUSD
-- n'est pas concerné ici.
--
-- Garde de post-condition : un bloc do $instr$ vérifie après l'update
-- que les trois lignes ont bien quote_currency = 'USD'. Le message
-- d'exception liste les symboles manquants.
--
-- Note de ré-exécution manuelle : le seed 022 (ligne 55) et le seed 001
-- (20260831000001_trades_lifecycle.sql ligne 124) utilisent tous deux
-- `on conflict (symbol, exchange) do nothing`. Rejouer ces seeds ne
-- touche donc pas la valeur de quote_currency des lignes déjà
-- présentes.
-- =============================================================================

begin;

-- Mise à jour ciblée : 'USD' pour les 3 instruments US. Le filtre
-- `quote_currency is null` rend l'update idempotent (no-op si déjà
-- appliqué, ce qui est attendu pour les ré-exécutions manuelles).
update public.instruments
   set quote_currency = 'USD'
 where symbol in ('AAPL', 'TSLA', 'GLD')
   and quote_currency is null;

-- Garde : vérification post-update. Si l'un des 3 instruments n'a
-- toujours pas quote_currency = 'USD', la migration avorte avec
-- le nom des symboles manquants.
do $instr$
declare
  v_missing text;
begin
  select string_agg(t.symbol, ', ')
    into v_missing
    from (values ('AAPL'), ('TSLA'), ('GLD')) as t(symbol)
    where not exists (
      select 1
        from public.instruments i
       where i.symbol = t.symbol
         and i.quote_currency = 'USD'
    );

  if v_missing is not null then
    raise exception
      '028 avortée : instruments sans quote_currency = ''USD'' après update : %',
      v_missing;
  end if;
end $instr$;

commit;