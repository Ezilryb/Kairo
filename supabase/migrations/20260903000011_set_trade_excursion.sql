-- /supabase/migrations/20260903000011_set_trade_excursion.sql
-- =============================================================================
-- Phase 5 — Market Data & Graphismes (whitepaper §08)
-- RPC set_trade_excursion : persistance des MAE / MFE post-clôture
-- =============================================================================
-- Contexte : le calcul de MAE (Maximum Adverse Excursion) et MFE (Maximum
-- Favorable Excursion) se déclenche UNE fois, juste après la transition
-- d'un trade vers 'closed'. Le calcul est fait côté Next.js dans
-- /api/trades/[id]/mae-mfe (endpoint Phase 5), qui fetch les bougies
-- Binance sur [opened_at, closed_at] et dérive mae/mfe depuis le parcours
-- de prix.
--
-- Ce RPC ne fait QUE la persistance : validation des préconditions + UPDATE
-- des colonnes mae/mfe. Pas de calcul ici (séparation : calcul = métier pur
-- côté Next, persistance = contrat SQL strict).
--
-- Défense en profondeur (pattern Phase 2 transition_trade / record_partial_exit) :
--   - SECURITY INVOKER : on s'appuie sur le RLS de la table trades pour
--     bloquer les lectures non autorisées.
--   - WHERE défensif dans le SELECT initial : on vérifie user_id = auth.uid()
--     ET status = 'closed'. Si l'un manque, on raise avec un message
--     unifié (pas de fuite d'info : on ne dit pas "ce trade n'est pas à
--     vous" mais "introuvable, non autorisé, ou non closed").
--   - Pas de validation p_mae >= 0 et p_mfe >= 0 : l'endpoint Next
--     garantit des valeurs >= 0 par construction (clip à 0 dans le
--     calcul). Une double validation côté SQL serait redondante.
--   - Le RPC ne crée pas d'event dans trade_events (MAE/MFE ne sont pas
--     une action de l'utilisateur, c'est un fait dérivé).
-- =============================================================================

create or replace function public.set_trade_excursion(
  p_trade_id uuid,
  p_mae     numeric,
  p_mfe     numeric
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid;
  v_status  public.trade_status;
begin
  -- RLS filtre déjà les trades non visibles. Si SELECT ne retourne rien,
  -- le trade est soit inexistant, soit non autorisé (autre user), soit
  -- filtré par RLS (ex: trade privé d'un autre user). On unifie le
  -- message pour ne pas leaker d'info.
  select user_id, status
    into v_user_id, v_status
  from public.trades
  where id = p_trade_id;

  if v_user_id is null or v_status <> 'closed' then
    raise exception 'Trade introuvable, non autorisé, ou non closed';
  end if;

  -- Double check : même si RLS laisse passer (cas où auth.uid() = user_id
  -- du trade par coïncidence), on confirme ici. En pratique redondant
  -- avec le RLS mais ceinture + bretelles.
  if v_user_id <> auth.uid() then
    raise exception 'Trade introuvable, non autorisé, ou non closed';
  end if;

  update public.trades
     set mae = p_mae,
         mfe = p_mfe
   where id = p_trade_id;
end $$;

comment on function public.set_trade_excursion(uuid, numeric, numeric) is
  'Persiste mae et mfe sur un trade CLOSED. SECURITY INVOKER : RLS bloque les trades non autorisés ; le SELECT interne est défensif (status=''closed'' + user_id=auth.uid()). Pas de validation p_mae/p_mfe >= 0 : l''endpoint Next.js le garantit par construction (clip à 0). N''insère pas dans trade_events (MAE/MFE sont des faits dérivés, pas des actions utilisateur).';

-- Grants : EXECUTE à PUBLIC par défaut suffit (pattern Phase 2 documenté
-- dans TODO_TECHNIQUE.md). Authenticated appelle depuis l'endpoint Next.js
-- via supabase.rpc() avec getUser(). RLS fait le filtrage réel.
