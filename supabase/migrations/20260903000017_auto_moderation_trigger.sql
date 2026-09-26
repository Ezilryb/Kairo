-- /supabase/migrations/20260903000017_auto_moderation_trigger.sql
-- =============================================================================
-- Phase 7 — Modération & Sanctions (whitepaper §12)
-- Trigger AFTER INSERT on reports : masquage automatique du post signalé
-- + alerte compte si 4+ posts masqués en 24h.
--
-- LOGIQUE DU MASQUAGE (seuil 2) :
--   - Ne s'applique que si le signalement cible un POST (trade_id ou
--     comment_id non null). Un signalement reported_user_id seul (sans
--     post ciblé) n'entre pas dans ce calcul — ce n'est pas "un post".
--   - Compte TOUS les signalements référençant la même cible, tout statut
--     confondu (pending, under_review, resolved, dismissed). Si on ne
--     comptait que les 'pending', un signalement classé 'dismissed'
--     ferait repartir le compteur à zéro — contournement trivial du
--     seuil. Donc : compteur global sur tous les statuts.
--   - Si count >= 2 ET post pas encore masqué → UPDATE post :
--     moderation_hidden = true, moderation_flagged_at = now().
--   - Idempotent : si déjà masqué, pas d'UPDATE redondant.
--
-- LOGIQUE DE L'ALERTE COMPTE (seuil 4 en 24h) :
--   - À chaque passage à moderation_hidden=true, on recompte les posts
--     (trades + comments confondus) du même propriétaire avec
--     moderation_flagged_at >= now() - interval '24 hours'.
--   - Si >= 4 ET qu'aucune alerte n'a déjà été posée pour ce compte dans
--     les dernières 24h → INSERT INTO audit_logs (déduplication par
--     audit_logs récents : sans ça, un 5e post masqué plus tard
--     réinscrirait une alerte redondante pour la même situation).
--     action = 'moderation.account_flagged'
--     entity_type = 'user'
--     entity_id = user_id du propriétaire
--     metadata = {flagged_count, window, triggered_by_report}
--   - Pas de notification per-admin ciblée pour ce MVP (notification_type
--     = 'moderation' reste non câblé — pas d'UI admin, audit_logs sert
--     de journal consultable en SQL direct).
--
-- COUPLAGE NON-INTENTIONNEL avec log_sl_tp_changes (Phase 0/migration 003) :
--   L'UPDATE trades SET moderation_hidden=true, moderation_flagged_at=now()
--   déclenche tous les triggers BEFORE UPDATE sur trades, dont
--   log_sl_tp_changes qui rafraîchit last_activity_at = now() quand
--   status <> 'forgotten'. Un signalement n'est pas une activité du
--   trader — refresh last_activity_at ferait avancer son horloge OUBLIÉ
--   à l'instant du masquage, juste parce que quelqu'un l'a signalé.
--   Mêmes principes que prepare_user_deletion_cascade (flag de session
--   local à la transaction) : on pose `app.moderation_update = 'true'`
--   avant l'UPDATE et on remet à 'false' après (sinon le flag fuiterait
--   sur les UPDATE suivants de la même transaction). Côté log_sl_tp_changes,
--   on ignore le rafraîchissement quand ce flag est posé. CURRENT_SETTING
--   avec 2e arg `true` (missing_ok) renvoie NULL si le flag n'a jamais
--   été posé → NULL IS DISTINCT FROM 'true' = TRUE → comportement par
--   défaut (rafraîchir) intact pour tous les autres UPDATE.
--
-- SÉCURITÉ : SECURITY DEFINER + set search_path = public. Indispensable :
--   - Le rapporteur n'est presque jamais propriétaire du post signalé
--     → écrire moderation_hidden sur la ligne cible avec les seuls
--     droits de l'appelant échouerait sous la RLS UPDATE normale de
--     trades/trade_comments (auth.uid() = user_id).
--   - Idem pour écrire dans audit_logs, table inaccessible aux rôles
--     anon/authenticated (cf. migration initiale 0001, policy RLS :
--     aucune pour audit_logs, lecture/écriture service_role uniquement).
-- SECURITY DEFINER fait que la fonction s'exécute avec les droits du
-- propriétaire (postgres), pas du caller, ce qui permet les écritures
-- croisées. set search_path = public : évite les attaques par
-- modification du search_path (cf. migration 0001, set_updated_at
-- et forbid_trade_events_mutation pour le même réflexe).
-- =============================================================================

begin;


-- -----------------------------------------------------------------------------
-- Fonction auto_moderate_on_report
-- -----------------------------------------------------------------------------
create or replace function public.auto_moderate_on_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_owner       uuid;
  v_target_already     boolean;
  v_report_count       integer;
  v_flagged_posts_count integer;
begin
  -- 1. Détermine la cible du signalement.
  --    Un signalement doit cibler un post (trade ou comment) pour
  --    déclencher le masquage automatique. reported_user_id seul ne
  --    suffit pas — ce n'est pas "un post", c'est un signalement profil.
  if new.trade_id is not null then
    select user_id, moderation_hidden
      into v_target_owner, v_target_already
      from public.trades where id = new.trade_id;
  elsif new.comment_id is not null then
    select user_id, moderation_hidden
      into v_target_owner, v_target_already
      from public.trade_comments where id = new.comment_id;
  end if;

  -- Pas de cible post identifiable → on ne fait rien (rien à modérer).
  if v_target_owner is null then
    return new;
  end if;

  -- 2. Compte TOUS les signalements référençant la même cible, tout
  --    statut confondu. Pas seulement 'pending' — sinon dismissed
  --    ferait repartir le compteur à zéro (contournement trivial).
  if new.trade_id is not null then
    select count(*)
      into v_report_count
      from public.reports
      where trade_id = new.trade_id;
  else
    select count(*)
      into v_report_count
      from public.reports
      where comment_id = new.comment_id;
  end if;

  -- 3. Si seuil atteint ET pas déjà masqué → masquer.
  --    Idempotent : si déjà masqué, pas d'UPDATE redondant.
  if v_report_count >= 2 and not v_target_already then
    if new.trade_id is not null then
      -- Flag GUC local à la transaction : signale à log_sl_tp_changes
      -- (et à tout autre trigger BEFORE UPDATE) qu'on n'est PAS dans une
      -- activité du trader — il ne doit pas rafraîchir last_activity_at.
      -- Remis à 'false' immédiatement après l'UPDATE (sinon il fuiterait
      -- sur les UPDATE suivants de la même transaction — tout le fichier
      -- de tests tourne dans un seul begin/rollback).
      perform set_config('app.moderation_update', 'true', true);
      update public.trades
        set moderation_hidden = true,
            moderation_flagged_at = now()
        where id = new.trade_id;
      perform set_config('app.moderation_update', 'false', true);
    else
      -- Pas de flag GUC nécessaire pour trade_comments (la table n'a pas
      -- de colonne last_activity_at — cf. migration initiale 0001).
      update public.trade_comments
        set moderation_hidden = true,
            moderation_flagged_at = now()
        where id = new.comment_id;
    end if;

    -- 4. Alerte compte (Phase 7) : 4+ posts masqués du même owner en
    --    24h. Compte après le masquage qu'on vient de poser.
    --    L'UNION ALL (pas UNION) pour ne pas dédupliquer un même post
    --    qui serait dans les 2 tables — trades et comments sont
    --    disjoints par construction, donc UNION ALL est correct.
    select count(*)
      into v_flagged_posts_count
      from (
        select id from public.trades
          where user_id = v_target_owner
            and moderation_hidden = true
            and moderation_flagged_at >= now() - interval '24 hours'
        union all
        select id from public.trade_comments
          where user_id = v_target_owner
            and moderation_hidden = true
            and moderation_flagged_at >= now() - interval '24 hours'
      ) flagged;

    -- 4bis. Déduplication : on n'insère une alerte que si aucune autre
    --      alerte pour ce compte n'a été posée dans les dernières 24h.
    --      Sans ça, un 5e post masqué plus tard réinscrirait une alerte
    --      redondante pour exactement la même situation.
    if v_flagged_posts_count >= 4
       and not exists (
         select 1 from public.audit_logs
         where action = 'moderation.account_flagged'
           and entity_type = 'user'
           and entity_id = v_target_owner
           and created_at >= now() - interval '24 hours'
       ) then
      insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
      values (null, 'moderation.account_flagged', 'user', v_target_owner,
              jsonb_build_object('flagged_count', v_flagged_posts_count,
                                 'window', '24 hours',
                                 'triggered_by_report', new.id));
    end if;
  end if;

  return new;
end $$;


-- -----------------------------------------------------------------------------
-- Trigger
-- -----------------------------------------------------------------------------
-- AFTER INSERT (pas BEFORE) : on agit APRÈS que la ligne est créée dans
-- reports. Si le masquage plante, on ne veut pas annuler l'INSERT du
-- report (le signalement existe, c'est un fait). La fonction ne fait
-- que UPDATE/INSERT en aval, pas de propagation d'erreur qui rollback
-- l'INSERT du report.
create trigger reports_auto_moderate
  after insert on public.reports
  for each row execute function public.auto_moderate_on_report();

comment on trigger reports_auto_moderate on public.reports is
  'Phase 7 : déclenche le masquage automatique (≥ 2 signalements tout statut) + l''alerte compte (≥ 4 posts masqués en 24h, dédupliquée par audit_logs récents). SECURITY DEFINER pour pouvoir écrire moderation_hidden sur un post qui n''appartient pas au rapporteur, et pour écrire dans audit_logs (inaccessible aux rôles client).';


-- -----------------------------------------------------------------------------
-- Patch de log_sl_tp_changes : ignorer last_activity_at pendant un UPDATE
-- déclenché par la modération.
-- -----------------------------------------------------------------------------
-- create or replace : la fonction existe depuis la migration initiale
-- 0001, corrigée une fois en migration 003 pour la bascule OUBLIÉ. Phase
-- 7 ajoute un cas supplémentaire (UPDATE modération) où l'UPDATE n'est
-- PAS une activité du trader — log_sl_tp_changes doit donc ignorer le
-- rafraîchissement de last_activity_at dans ce cas précis.
--
-- IS DISTINCT FROM plutôt que `= 'true'` : current_setting(..., true)
-- (2e arg = missing_ok) renvoie NULL quand le flag n'a jamais été posé
-- (cas normal, 99% des UPDATE). NULL IS DISTINCT FROM 'true' = TRUE
-- → le comportement par défaut (rafraîchir last_activity_at) reste
-- intact partout ailleurs.
create or replace function public.log_sl_tp_changes()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.status <> 'draft' then
    if new.stop_loss is distinct from old.stop_loss then
      insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
      values (old.id, old.user_id, 'sl_modified',
              jsonb_build_object('stop_loss', old.stop_loss),
              jsonb_build_object('stop_loss', new.stop_loss));
    end if;
    if new.take_profit is distinct from old.take_profit then
      insert into public.trade_events (trade_id, user_id, event_type, old_values, new_values)
      values (old.id, old.user_id, 'tp_modified',
              jsonb_build_object('take_profit', old.take_profit),
              jsonb_build_object('take_profit', new.take_profit));
    end if;
  end if;
  -- Toute activité sur le trade repousse la bascule OUBLIÉ (5 jours),
  -- SAUF si l'UPDATE est déclenché par la modération (auto_moderate_on_report)
  -- dans ce cas, le trader n'a rien fait, son horloge OUBLIÉ ne doit pas
  -- repartir à zéro juste parce qu'on l'a signalé. Cf. migration 017
  -- pour la pose du flag `app.moderation_update`.
  if new.status <> 'forgotten'
     and current_setting('app.moderation_update', true) is distinct from 'true' then
    new.last_activity_at := now();
  end if;
  return new;
end $$;

commit;
