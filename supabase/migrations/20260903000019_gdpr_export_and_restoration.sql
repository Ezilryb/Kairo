-- /supabase/migrations/20260903000019_gdpr_export_and_restoration.sql
-- =============================================================================
-- Migration 0019 — Phase 8 RGPD & Export/Migration (whitepaper §10 + §11)
-- 1 RPC user-facing (export_user_data) + 1 RPC admin (flag_restoration_conflict)
-- + 1 colonne (restoration_hold_until).
--
-- Cadrage chef (Phase 8 brief) :
--   - L'export de données (portabilité RGPD, art. 20) doit couvrir TOUTES les
--     données détenues par l'utilisateur, y compris les commentaires soft-
--     deleted via moderation (deleted_at NOT NULL). Justification du
--     SECURITY DEFINER sur export_user_data : la policy SELECT de
--     trade_comments (migration 0001) filtre `deleted_at is null`, donc
--     l'auteur lui-même ne pourrait pas voir ses propres commentaires
--     supprimés dans son export via un client scopé session. Le check
--     explicite `p_user_id = auth.uid()` empêche tout accès aux données
--     d'un autre user malgré les droits élevés — toutes les requêtes internes
--     sont filtrées sur p_user_id.
--   - 'profile' exclut account_status (état de modération interne, pas une
--     donnée exportable au même titre que bio/pseudo/avatar). Le reste de
--     public.users est intégralement exporté.
--   - Aucune table auth.users touchée — l'identité SSO reste hors export
--     par construction (whitepaper §10).
--
--   - flag_restoration_conflict : gate admin (même pattern que Phase 7
--     admin_resolve_report / admin_set_account_status). Pose une colonne
--     restoration_hold_until = now() + interval '10 days' sur le user
--     existant pour bloquer la restauration pendant la fenêtre de
--     résolution de conflit. Pas de policy RLS sur la colonne cette phase
--     : le whitepaper ne précise pas ce que la "protection temporaire"
--     restreint concrètement, et sans flux d'import pour l'exercer,
--     spéculer sur l'enforcement serait prématuré (cf. TODO_TECHNIQUE).
--   - Hors scope : flux d'import réel. Le whitepaper décrit le
--     comportement en cas de conflit mais aucune UI d'upload d'export
--     n'existe. Poser la plomberie sans le déclencheur qui l'appellerait
--     reproduirait l'erreur évitée pour MAE/MFE avant MarketDataProvider.
--
-- Pourquoi 2 RPCs séparés plutôt qu'1 :
--   - export_user_data = user-facing (caller = soi-même, RLS via SECURITY
--     DEFINER + check explicite).
--   - flag_restoration_conflict = admin-only (caller = admin dans
--     public.admins, RLS via SECURITY DEFINER + check admins en premier,
--     pattern Phase 7).
--   - Fusionner créerait un RPC avec 2 chemins d'autorisation distincts,
--     plus dur à raisonner et à tester.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Colonne restoration_hold_until (scaffold, hors scope enforcement)
-- -----------------------------------------------------------------------------
-- Ajoutée conditionnellement (if not exists) pour qu'un re-run de la
-- migration ne lève pas — utile en dev / staging. Pas de default, NULL
-- explicite = pas de hold posé.
alter table public.users
  add column if not exists restoration_hold_until timestamptz;

comment on column public.users.restoration_hold_until is
  'Date jusqu''à laquelle toute tentative de restauration du compte est gelée (Phase 8 RGPD). Posée par flag_restoration_conflict() quand un admin détecte un conflit de restauration. Pas d''enforcement automatique cette phase — voir TODO_TECHNIQUE §Phase 8 pour la dette.';

-- -----------------------------------------------------------------------------
-- 2. RPC export_user_data — portabilité RGPD (art. 20)
-- -----------------------------------------------------------------------------
-- Retourne un JSONB contenant toutes les données user-facing de l'appelant.
-- SECURITY DEFINER + check explicite p_user_id = auth.uid() : l'utilisateur
-- ne peut exporter que SES données, jamais celles d'un autre user, malgré
-- les droits élevés du proprio de la fonction.
--
-- Toutes les sous-requêtes filtrent sur p_user_id (pas d'élévation de
-- privilège effective). Le SECURITY DEFINER sert uniquement à contourner
-- la policy SELECT de trade_comments (deleted_at IS NULL) pour permettre
-- l'export des commentaires soft-deleted — la portabilité RGPD couvre
-- l'intégralité des données détenues, pas seulement celles actuellement
-- visibles dans l'app.
--
-- Format de sortie :
--   {
--     "profile":      { id, pseudo, bio, avatar_url, is_public, created_at, updated_at },
--     "trades":       [ { ...tous les trades de l'user, ... } ],
--     "trade_events": [ { ...tous les events sur les trades de l'user } ],
--     "comments":     [ { ...y compris soft-deleted } ],
--     "likes_given":  [ { trade_id, created_at } ],
--     "following":    [ uuid, ... ],   -- followee_ids
--     "followers":    [ uuid, ... ],   -- follower_ids
--     "exported_at":  timestamptz
--   }
--
-- Note exported_at en timestamptz (clé top-level, pas dans profile) pour
-- horodater l'export indépendamment des dates des données — pratique si
-- l'utilisateur dépose l'export comme preuve auprès d'un régulateur.
create or replace function public.export_user_data(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Check 1er, avant toute lecture : un non-proprio ne doit RIEN voir.
  --
  -- CRITIQUE — utiliser IS DISTINCT FROM, PAS <>.
  -- L'opérateur <> suit la logique 3 valeurs SQL : `uuid <> NULL` = NULL,
  -- traité comme FALSE par un IF PL/pgSQL. SECURITY DEFINER tourne avec
  -- les droits du proprio (postgres, BYPASSRLS), donc aucune policy RLS
  -- ne filtre en filet de sécurité — le check interne cassé est la SEULE
  -- protection. Avec <>, un appel REST anonyme (auth.uid() = NULL) +
  -- p_user_id = UUID de la victime = export intégral contournant le
  -- masquage Phase 6. IS DISTINCT FROM traite NULL correctement :
  -- `uuid IS DISTINCT FROM NULL` = TRUE → raise.
  --
  -- Le format du raise exception est conçu pour être lisible côté client
  -- (route app/api/account/export) et côté tests pgTAP (pattern
  -- throws_ok avec prefix matching).
  if p_user_id is distinct from auth.uid() then
    raise exception 'export_user_data: p_user_id (%) ne correspond pas à auth.uid() (%)',
      p_user_id, auth.uid()
      using errcode = '42501';  -- insufficient_privilege
  end if;

  return jsonb_build_object(
    -- Exclusion de deux colonnes administratives : ni account_status ni
    -- restoration_hold_until ne sont des données fournies par /
    -- décrivant l'activité de trading de l'user. Ce sont des états
    -- imposés de l'extérieur (modération, RGPD) qui n'ont pas leur
    -- place dans un export user-facing (portabilité RGPD art. 20 =
    -- données du titulaire, pas données administratives sur lui).
    'profile',
      (select to_jsonb(u) - 'account_status' - 'restoration_hold_until'
         from public.users u
         where u.id = p_user_id),

    'trades',
      (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
         from public.trades t
         where t.user_id = p_user_id),

    'trade_events',
      (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb)
         from public.trade_events e
         where e.user_id = p_user_id),

    -- Inclut les commentaires soft-deleted (deleted_at IS NOT NULL) :
    -- c'est exactement le besoin qui justifie SECURITY DEFINER ici.
    'comments',
      (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb)
         from public.trade_comments c
         where c.user_id = p_user_id),

    'likes_given',
      (select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb)
         from public.likes l
         where l.user_id = p_user_id),

    'following',
      (select coalesce(jsonb_agg(followee_id), '[]'::jsonb)
         from public.followers
         where follower_id = p_user_id),

    'followers',
      (select coalesce(jsonb_agg(follower_id), '[]'::jsonb)
         from public.followers
         where followee_id = p_user_id),

    'exported_at',
      now()
  );
end $$;

comment on function public.export_user_data(uuid) is
  'Export RGPD art. 20 — retourne toutes les données user-facing de l''appelant sous forme JSONB. SECURITY DEFINER + check p_user_id = auth.uid() pour permettre l''inclusion des commentaires soft-deleted (policy SELECT deleted_at IS NULL contournée) tout en garantissant qu''aucun user ne peut exporter les données d''un autre.';

-- -----------------------------------------------------------------------------
-- 3. RPC flag_restoration_conflict — gate admin (Phase 8 §11)
-- -----------------------------------------------------------------------------
-- Posée quand un admin détecte un conflit de restauration (ex : nouvelle
-- tentative de rattachement à un pseudo déjà pris par un autre compte).
-- Bloque la restauration pendant 10 jours via la colonne
-- restoration_hold_until.
--
-- SECURITY DEFINER + check admins en premier (même pattern que Phase 7) :
--   - admins n'ont aucune policy UPDATE sur users via auth.uid() (table
--     users n'a qu'une policy "self-update" basique, migration 0001).
--   - Le check `exists (select 1 from public.admins where user_id = auth.uid())`
--     lève avant tout effet de bord.
--
-- Hors scope cette phase :
--   - Pas de policy RLS conditionnée sur restoration_hold_until (aucun
--     flux d'import ne consomme cette colonne pour l'instant).
--   - Pas de dépose automatique après 10 jours (la colonne persiste, un
--     admin peut la remettre à NULL explicitement via un futur
--     admin_clear_restoration_hold).
--   - Pas de notification au user concerné (hors scope notification Phase 8).
create or replace function public.flag_restoration_conflict(
  p_existing_user_id uuid,
  p_reason           text
)
returns public.users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users;
begin
  -- Check admins en PREMIÈRE instruction : aucun effet de bord si refusé.
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'flag_restoration_conflict: user (%) n''est pas admin', auth.uid()
      using errcode = '42501';
  end if;

  -- p_reason obligatoire : on trace un audit_log, un raison vide serait
  -- un angle mort en cas de dispute ("pourquoi ce user est gelé ?").
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'flag_restoration_conflict: p_reason obligatoire (texte non vide)';
  end if;

  update public.users
    set restoration_hold_until = now() + interval '10 days'
    where id = p_existing_user_id
    returning * into v_user;

  -- UPDATE 0 lignes → user inexistant. On raise plutôt que renvoyer NULL
  -- pour qu'un admin qui tape un mauvais UUID entende l'erreur (vs une
  -- fonction qui retourne "succès" sans rien faire).
  if v_user.id is null then
    raise exception 'flag_restoration_conflict: user (%) introuvable', p_existing_user_id;
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    null,  -- pas old.id : on est sur l'admin qui appelle, pas la cible
    'gdpr.restoration_conflict_flagged',
    'user',
    p_existing_user_id,
    jsonb_build_object(
      'reason',      p_reason,
      'hold_until',  v_user.restoration_hold_until,
      'flagged_by',  auth.uid()
    )
  );

  return v_user;
end $$;

comment on function public.flag_restoration_conflict(uuid, text) is
  'Gate admin (Phase 8) — pose un hold de 10 jours sur la restauration d''un user en cas de conflit. SECURITY DEFINER + check admins en premier (pattern Phase 7). Audit logué dans audit_logs avec action = gdpr.restoration_conflict_flagged.';

commit;
