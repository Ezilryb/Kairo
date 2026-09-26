-- /supabase/migrations/20260903000006_log_entry_price_changes.sql
-- =============================================================================
-- Phase 4 — Analytics Engine avancé (whitepaper §07)
-- Trigger log_entry_price_changes : historise les modifications d'entry_price
-- =============================================================================
-- Contexte : §07 / Plan Adherence Score inclut une composante "Entrée" qui
-- compte les events entry_modified sur le trade. L'enum trade_event_type
-- déclare entry_modified depuis la migration initiale, mais AUCUN trigger ni
-- RPC n'insérait cette valeur (vérifié en Phase 4, voir TODO_TECHNIQUE).
-- Sans ce trigger, impossible de savoir si l'utilisateur a modifié son prix
-- d'entrée pendant la fenêtre scalping 60s.
--
-- Jumeau exact (en surface) de log_sl_tp_changes, mais sur entry_price seul.
-- Pattern strictement identique : SECURITY DEFINER, search_path = public,
-- insert dans trade_events avec old_values.entry_price et new_values.entry_price.
--
-- Ordre des triggers sur trades (UPDATE) — alphabétique sur le NOM du trigger :
--   1. log_entry_price_changes (e)  ← ce trigger, s'exécute en premier
--   2. log_sl_tp_changes       (s)  ← Phase 0/2
--   3. set_trades_updated_at   (s)  ← Phase 0 (touché en dernier)
-- C'est OK fonctionnellement : les 2 triggers qui écrivent dans trade_events
-- sont indépendants (colonnes différentes), aucun risque d'interférence.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Fonction
-- -----------------------------------------------------------------------------
create or replace function public.log_entry_price_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Filtre 1 : on ne loggue que les modifs sur trades non-draft.
  --   Un brouillon (status='draft') est en construction : les modifs
  --   d'entry_price pendant cette phase sont de l'exploration, pas
  --   un événement significatif pour le score.
  -- Filtre 2 : is distinct from — évite de logger une "modif" vers la
  --   même valeur (cas d'un UPDATE qui ne change pas entry_price).
  if old.status <> 'draft'
     and new.entry_price is distinct from old.entry_price then
    insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
    values (
      old.id,
      old.user_id,
      'entry_modified',
      jsonb_build_object('entry_price', old.entry_price),
      jsonb_build_object('entry_price', new.entry_price)
    );
  end if;
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- 2. Trigger
-- -----------------------------------------------------------------------------
-- AFTER UPDATE (et non BEFORE) : on est certain que la modif a passé
-- enforce_entry_price_immutability (BEFORE UPDATE) avant d'écrire dans
-- trade_events. Si on était en BEFORE, on risquerait de logger une modif
-- qui sera levée juste après par enforce_entry_price_immutability.
create trigger trades_log_entry_price_changes
  after update on public.trades
  for each row execute function public.log_entry_price_changes();

-- -----------------------------------------------------------------------------
-- 3. Commentaires
-- -----------------------------------------------------------------------------
comment on function public.log_entry_price_changes() is
  'Trigger AFTER UPDATE sur trades : historise les modifs d''entry_price sur trades non-draft dans trade_events (event_type=entry_modified). Jumeau de log_sl_tp_changes, alimente la composante "Entrée" du Plan Adherence Score (§07).';
