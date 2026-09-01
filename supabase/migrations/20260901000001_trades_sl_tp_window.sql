-- /supabase/migrations/20260901000001_trades_sl_tp_window.sql
-- =============================================================================
-- Phase 2 — Point C : fermeture du trou whitepaper §04 sur la fenêtre
-- scalping de SL / TP.
--
-- Contexte : la migration initiale (Phase 0) a posé un verrou temporel
-- 60 s sur entry_price (trigger `enforce_entry_price_immutability`) mais
-- le whitepaper §04 est explicite : "L'utilisateur dispose d'exactement
-- 60 secondes après publication pour modifier l'entrée, le SL, le TP
-- ou les infos. Après cette minute, verrouillage définitif."
-- La fenêtre n'a jamais été appliquée à SL / TP. Le trigger
-- `log_sl_tp_changes` (Phase 0) se contente de logger chaque changement
-- dans trade_events, sans contrainte temporelle — SL / TP restaient
-- donc modifiables indéfiniment sur un trade publié. Trou détecté en
-- Phase 2 Point C, juste avant de construire l'UI countdown 60 s
-- autour de cette hypothèse précisément.
--
-- Choix technique : NOUVEAU trigger `enforce_sl_tp_immutability`,
-- séparé du `log_sl_tp_changes` existant, plutôt qu'extension de ce
-- dernier. Trois raisons :
--   1. Séparation des responsabilités : le verrou est une contrainte
--      métier (raise exception), le log est un effet de bord (insert
--      dans trade_events). Deux responsabilités = deux triggers.
--   2. Déboguabilité : si on doit désactiver temporairement le log
--      (debug, migration de données, etc.), la contrainte reste en
--      place, et vice-versa.
--   3. Cohérence avec le pattern Phase 2 Point A : `enforce_capital_
--      immutability` (contrainte) est déjà séparé de `log_partial_exits`
--      (historisation), on reproduit la même symétrie.
--
-- `log_sl_tp_changes` n'est pas modifié. Il continue à historiser
-- normalement chaque changement de SL / TP dans la fenêtre (avant que
-- la contrainte ne bloque quoi que ce soit). Aucune interaction
-- néfaste : si le verrou lève une exception, le log ne s'exécute pas
-- (les triggers BEFORE UPDATE s'exécutent dans l'ordre alphabétique et
-- une exception interrompt la chaîne).
--
-- Ordre final des triggers BEFORE UPDATE sur `trades` (alphabétique par
-- nom de trigger, pas de fonction — Postgres trie sur le nom du trigger
-- lui-même, pas sur la fonction qu'il appelle) :
--   1. set_trades_updated_at                   (Phase 0 — nommé "set_", pas "trades_")
--   2. trades_enforce_capital_immutability     (Phase 2 Point A)
--   3. trades_enforce_entry_price_immutability (Phase 0)
--   4. trades_enforce_sl_tp_immutability       (Phase 2 Point C, nouveau)
--   5. trades_log_partial_exits                (Phase 2 Point A)
--   6. trades_log_sl_tp_changes                (Phase 0)
-- Note : `set_trades_updated_at` commence par "s", tous les autres par
-- "trades_" (t) — s < t alphabétiquement, il s'exécute donc en PREMIER.
-- Aucun impact fonctionnel ici (set_updated_at ne fait que
-- new.updated_at := now(), aucun autre trigger ne lit updated_at), mais
-- l'ordre exact compte pour les audits futurs.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- enforce_sl_tp_immutability
-- -----------------------------------------------------------------------------
-- Verrou temporel 60 s post-publication sur stop_loss et take_profit.
-- Pattern strictement identique à `enforce_entry_price_immutability`
-- (Phase 0) :
--   - old.status <> 'draft' : on ne verrouille rien tant que le trade
--     n'est pas publié
--   - old.published_at is not null : garde-fou, ne devrait jamais
--     être faux pour un trade non-draft mais on reste explicite
--   - now() > old.published_at + interval '60 seconds' : la borne
--     est STRICTEMENT supérieure (cf. commentaire jumeau dans
--     enforce_entry_price_immutability) — 60 s pile est encore
--     toléré, 60 s + ε bloque.
--
-- Une seule fonction pour SL et TP : la règle métier est identique
-- pour les deux champs, le message d'erreur est uniforme, et un
-- seul `is distinct from` par champ garde la lecture claire.
--
-- La règle de transition `draft → live` n'est pas affectée : pendant
-- cette transition, `old.status = 'draft'`, donc on n'entre jamais
-- dans la branche du verrou. La logique de `enforce_entry_price_
-- immutability` (mêmes conditions) s'applique à entry_price, pas à
-- SL / TP — pas de risque d'interférence.
create or replace function public.enforce_sl_tp_immutability()
returns trigger language plpgsql as $$
begin
  if (new.stop_loss is distinct from old.stop_loss
      or new.take_profit is distinct from old.take_profit) then
    if old.status <> 'draft'
       and old.published_at is not null
       and now() > old.published_at + interval '60 seconds' then
      raise exception
        'stop_loss / take_profit sont immuables après la fenêtre scalping de 60 s (whitepaper §04)';
    end if;
  end if;
  return new;
end $$;

create trigger trades_enforce_sl_tp_immutability
  before update on public.trades
  for each row execute function public.enforce_sl_tp_immutability();

commit;
