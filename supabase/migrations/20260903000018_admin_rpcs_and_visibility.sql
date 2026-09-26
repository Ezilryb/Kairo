-- /supabase/migrations/20260903000018_admin_rpcs_and_visibility.sql
-- =============================================================================
-- Phase 7 — Modération & Sanctions (whitepaper §12)
-- 2 RPCs admin + UPDATE des policies SELECT de trades et trade_comments
-- pour intégrer le masquage (moderation_hidden) et l'état de compte
-- (account_status).
--
-- RPCS ADMIN — SECURITY DEFINER + check admins en premier :
--   - admin_resolve_report : pose status/resolved_at/resolved_by sur un
--     signalement. NE réhabilite PAS un post masqué si le signalement
--     est 'dismissed' (pas de recalcul de compteur — un admin qui veut
--     démasquer le fait via une action explicite séparée, hors scope).
--   - admin_set_account_status : met à jour users.account_status et log
--     dans audit_logs.
--   - Les deux SECURITY DEFINER pour contourner la RLS normale (un admin
--     n'a pas de policy UPDATE sur trades / trade_comments via son
--     auth.uid() — il agit via service_role, ce que SECURITY DEFINER
--     simule au niveau fonction).
--   - Check `exists (select 1 from public.admins where user_id = auth.uid())`
--     en toute première instruction du corps : si l'appelant n'est pas
--     admin, raise avant tout effet de bord. Même réflexe "défense en
--     profondeur explicite" que partout ailleurs dans le projet (publish_trade,
--     transition_trade, etc. — voir migration 003).
--
-- UPDATE POLICIES SELECT — masquage (migration 018) :
--   - trades : le propriétaire voit TOUJOURS son propre contenu (peu
--     importe is_public, moderation_hidden, ou son propre account_status
--     — "le compte reste actif", il doit voir ce qui lui arrive). Un
--     non-proprio voit si ET SEULEMENT SI :
--       is_public AND not moderation_hidden AND owner.account_status = 'active'
--   - trade_comments : hérite de la visibilité du trade parent pour
--     l'aspect "trade visible/non-masqué", PLUS un gate local sur le
--     commentaire lui-même : un commentaire masqué par la modération
--     (comment_moderation_hidden=true, cf. migration 016) n'est visible
--     qu'à son auteur (analogie directe avec trades : le proprio voit
--     toujours son contenu masqué). Sans ce gate, la colonne
--     trade_comments.moderation_hidden serait posée (par le trigger
--     017) puis jamais consultée — toute la fonctionnalité serait
--     inerte.
--   - DROP POLICY + CREATE POLICY : convention "jamais de modification
--     d'une migration déjà appliquée". Les anciennes policies SELECT
--     (migration initiale 0001) ne sont plus valides post-Phase 7.
--
-- ATTENTION — ce que cette migration NE fait PAS :
--   - Ne bloque pas la connexion d'un user banned. C'est un sujet
--     Supabase Auth Admin API (auth.admin.updateUserById avec
--     ban_duration) → TypeScript / service_role, pas SQL. Cadré
--     séparément (Phase 8 ou round dédié admin).
--   - Pas de réhabitation automatique de post masqué quand un report
--     est 'dismissed'. Un admin peut le faire via action explicite.
--   - Pas de notification per-admin (notification_type='moderation'
--     reste non câblé, cf. migration 015).
-- =============================================================================

begin;


-- -----------------------------------------------------------------------------
-- 1. RPC admin_resolve_report
-- -----------------------------------------------------------------------------
create or replace function public.admin_resolve_report(
  p_report_id  uuid,
  p_new_status public.report_status,
  p_notes      text default null
)
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report public.reports;
begin
  -- Garde-fou : seul un admin peut résoudre un report.
  -- Check en premier, avant tout SELECT/UPDATE, pour ne rien faire si
  -- l'appelant n'est pas autorisé (pas de fuite d'info par effet de bord).
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception
      'admin_resolve_report: user (%) n''est pas admin',
      auth.uid();
  end if;

  update public.reports
    set status      = p_new_status,
        resolved_at = case
          when p_new_status in ('resolved', 'dismissed') then now()
          else resolved_at
        end,
        resolved_by = case
          when p_new_status in ('resolved', 'dismissed') then auth.uid()
          else resolved_by
        end
    where id = p_report_id
    returning * into v_report;

  if v_report.id is null then
    raise exception
      'admin_resolve_report: report (%) introuvable', p_report_id;
  end if;

  -- Journalise dans audit_logs (cohérence avec admin_set_account_status
  — les deux RPCs admin doivent tracer leurs actions). p_notes est en
  -- métadonnée même si NULL (présence explicite pour le pattern futur
  — un dashboard admin peut afficher "(pas de note)" quand le champ est
  -- absent). Sans ce INSERT, p_notes disparaîtrait silencieusement et
  — l'admin n'aurait aucune trace de sa décision.
  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (null, 'moderation.report_resolved', 'report', p_report_id,
          jsonb_build_object('new_status', p_new_status,
                             'notes', p_notes,
                             'resolved_by', auth.uid()));

  return v_report;
end $$;

comment on function public.admin_resolve_report(uuid, public.report_status, text) is
  'Phase 7 Modération : résout un signalement (status + resolved_at + resolved_by) et journalise dans audit_logs. SECURITY DEFINER + check admins en premier. Ne réhabilite PAS un post masqué si status=dismissed — un admin peut le faire via action explicite (hors scope).';


-- -----------------------------------------------------------------------------
-- 2. RPC admin_set_account_status
-- -----------------------------------------------------------------------------
create or replace function public.admin_set_account_status(
  p_user_id uuid,
  p_status  public.account_status,
  p_reason  text
)
returns public.users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users;
begin
  -- Garde-fou : seul un admin peut changer l'état d'un compte.
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception
      'admin_set_account_status: user (%) n''est pas admin',
      auth.uid();
  end if;

  update public.users
    set account_status = p_status
    where id = p_user_id
    returning * into v_user;

  if v_user.id is null then
    raise exception
      'admin_set_account_status: user (%) introuvable', p_user_id;
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (null, 'moderation.account_status_changed', 'user', p_user_id,
          jsonb_build_object('new_status', p_status,
                             'reason', p_reason,
                             'changed_by', auth.uid()));

  return v_user;
end $$;

comment on function public.admin_set_account_status(uuid, public.account_status, text) is
  'Phase 7 Modération : change l''état de modération d''un compte et log dans audit_logs. SECURITY DEFINER + check admins en premier. p_reason obligatoire (traçabilité).';


-- -----------------------------------------------------------------------------
-- 3. UPDATE policy SELECT trades : masquage via moderation_hidden + account_status
-- -----------------------------------------------------------------------------
drop policy if exists "trades: lecture (publics ou propriétaire)" on public.trades;

create policy "trades: lecture (publics ou propriétaire, non masqué)"
  on public.trades for select
  using (
    -- Le propriétaire voit TOUJOURS son propre contenu (peu importe
    -- is_public / moderation_hidden / son propre account_status — il
    -- doit voir ce qui lui arrive même si son contenu est masqué aux
    -- autres, c'est l'information dont il a besoin pour comprendre et
    -- réagir à une modération).
    auth.uid() = user_id
    -- Non-proprio : visible si ET SEULEMENT SI public, non masqué par
    -- la modération, et propriétaire avec account_status='active'.
    -- EXISTS sur users (pas de jointure forcée — account_status est sur
    -- users, pas sur trades).
    or (
      is_public
      and not moderation_hidden
      and exists (
        select 1 from public.users u
        where u.id = trades.user_id and u.account_status = 'active'
      )
    )
  );


-- -----------------------------------------------------------------------------
-- 4. UPDATE policy SELECT trade_comments : hérite de la visibilité du trade
-- -----------------------------------------------------------------------------
drop policy if exists "trade_comments: lecture si le trade est lisible" on public.trade_comments;

create policy "trade_comments: lecture si le trade est lisible, non masqué"
  on public.trade_comments for select
  using (
    deleted_at is null
    -- (a) Visibilité du trade parent : le trade parent doit être lisible
    --     au caller (ses propres règles, cf. policy trades ci-dessus).
    and exists (
      select 1 from public.trades t
      join public.users u on u.id = t.user_id
      where t.id = trade_comments.trade_id
        and (
          t.user_id = auth.uid()
          or (
            t.is_public
            and not t.moderation_hidden
            and u.account_status = 'active'
          )
        )
    )
    -- (b) Gate local sur le commentaire : un commentaire masqué n'est
    --     visible qu'à son auteur (analogie avec trades — le proprio
    --     voit toujours son propre contenu, masqué ou non).
    and (
      trade_comments.user_id = auth.uid()
      or not trade_comments.moderation_hidden
    )
  );

commit;
