-- /supabase/migrations/20260903000007_helpers_derives.sql
-- =============================================================================
-- Phase 4 — Analytics Engine avancé (whitepaper §07)
-- Helpers privés (_trading_session, _day_of_week, _duration_bucket)
-- =============================================================================
-- 3 dimensions du croisement §07 sont DÉRIVÉES à la volée depuis opened_at /
-- closed_at, sans nouvelle colonne en base :
--
--   - Session  : _trading_session(p_opened_at) → 'asia' | 'europe' | 'us'
--   - Jour     : _day_of_week(p_opened_at)     → 0-6 (0=dimanche, 6=samedi)
--   - Durée    : _duration_bucket(p_duration)  → 'lt_15m' | '15m_1h' | ...
--
-- Préfixe `_` = helper privé (pattern _direction_multiplier, Phase 3). Ces
-- fonctions ne sont pas destinées à être appelées directement par l'UI :
-- elles sont des briques du moteur analytics_crosstab.
--
-- Toutes IMMUTABLE car pures (pas de lecture de table, pas de now()).
-- LANGUAGE sql = inline par le planner quand utilisées dans une requête.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. _trading_session — bucket UTC fixe (Asia / Europe / US)
-- -----------------------------------------------------------------------------
-- Bornes UTC NON chevauchantes, total = 24h :
--   - asia   : 00:00 - 07:59  (8h, couvre Tokyo + Shanghai + Sydney)
--   - europe : 08:00 - 15:59  (8h, couvre Londres + Francfort + Paris)
--   - us     : 16:00 - 23:59  (8h, couvre New York + Chicago)
--
-- Simplification volontaire : on ne tient pas compte de l'heure d'été (DST)
-- ni du timezone de l'utilisateur (colonne users.timezone si elle existe).
-- À affiner quand la précision deviendra un vrai besoin produit.
create or replace function public._trading_session(p_opened_at timestamptz)
returns text
language sql
immutable
as $$
  select case
    when extract(hour from p_opened_at at time zone 'UTC') between 0  and 7  then 'asia'
    when extract(hour from p_opened_at at time zone 'UTC') between 8  and 15 then 'europe'
    when extract(hour from p_opened_at at time zone 'UTC') between 16 and 23 then 'us'
  end
$$;

comment on function public._trading_session(timestamptz) is
  'Helper privé : retourne la session de trading (asia/europe/us) selon l''heure UTC de p_opened_at. Buckets fixes non chevauchants (8h chacun). Ne tient pas compte du DST ni du timezone utilisateur — à affiner si la précision devient un vrai besoin produit.';

-- -----------------------------------------------------------------------------
-- 2. _day_of_week — jour de la semaine (0=dimanche, 6=samedi)
-- -----------------------------------------------------------------------------
-- Convention PostgreSQL : extract(dow from ...) → 0=dimanche, 6=samedi.
-- IMPORTANT : on force `at time zone 'UTC'` (cohérent avec _trading_session
-- juste au-dessus) pour deux raisons :
--   1. Cohérence avec le projet (timestamps UTC, whitepaper §05) et avec
--      la fonction sœur. Sans le `at time zone 'UTC'`, le jour calendaire
--      retourné dépend du TimeZone GUC de la session courante.
--   2. La déclaration `immutable` serait sinon techniquement mensongère :
--      le résultat dépendrait d'un état de session (TimeZone), pas
--      uniquement de p_ts.
-- On expose tel quel ; l'UI peut convertir en libellé si besoin.
create or replace function public._day_of_week(p_ts timestamptz)
returns int
language sql
immutable
as $$
  select extract(dow from p_ts at time zone 'UTC')::int
$$;

comment on function public._day_of_week(timestamptz) is
  'Helper privé : retourne le jour de la semaine (0=dimanche, 6=samedi) en UTC, selon la convention PostgreSQL extract(dow). Ancré en UTC via `at time zone ''UTC''` pour ne pas dépendre du TimeZone GUC de session. L''UI peut convertir en libellé.';

-- -----------------------------------------------------------------------------
-- 3. _duration_bucket — bucket de durée d'un trade
-- -----------------------------------------------------------------------------
-- 5 buckets + 'unknown' pour p_duration NULL (cas où opened_at ou
-- closed_at manquent — typiquement trade encore live ou forgotten).
-- Bornes volontairement inclusives à gauche : '< 15min' = strictement
-- inférieur à 15min, '15min-1h' = [15min, 1h[, etc.
create or replace function public._duration_bucket(p_duration interval)
returns text
language sql
immutable
as $$
  select case
    when p_duration is null then 'unknown'
    when p_duration <  interval '15 minutes' then 'lt_15m'
    when p_duration <  interval '1 hour'     then '15m_1h'
    when p_duration <  interval '4 hours'    then '1h_4h'
    when p_duration <  interval '1 day'      then '4h_1d'
    else                                          'gt_1d'
  end
$$;

comment on function public._duration_bucket(interval) is
  'Helper privé : bucketise une durée de trade en 5 catégories (lt_15m, 15m_1h, 1h_4h, 4h_1d, gt_1d) + ''unknown'' si NULL. Bornes inclusives à gauche.';
