-- /supabase/migrations/20260903000020_trade_events_policy_align_phase7.sql
-- =============================================================================
-- Migration 0020 — Phase 9 (audit sécurité composant Proof of Performance)
-- Alignement de la policy SELECT sur public.trade_events avec la policy
-- SELECT sur public.trades mise à jour en Phase 7 (migration 018).
--
-- Contexte de la découverte (Phase 9, audit composant PoP) :
--   La policy trade_events "lecture si le trade est lisible" (migration
--   initiale 0001) s'appuyait sur le predicate (t.is_public OR
--   t.user_id = auth.uid()). En Phase 7 (migration 018), la policy
--   trades a été durcie pour intégrer le masquage par modération
--   (moderation_hidden) ET l'état de modération du propriétaire
--   (account_status). MAIS la policy trade_events n'a PAS été mise à
--   jour en parallèle — c'est un oubli documenté.
--
-- Conséquence exploitable AVANT cette migration :
--   Un user authentifié pouvait SELECT les trade_events d'un trade
--   public même si :
--     (a) le trade avait été masqué par la modération (moderation_hidden
--         = true) → la policy trades Phase 7 l'aurait bloqué mais
--         trade_events laissait passer ;
--     (b) le propriétaire était shadowbanned / suspended / banned
--         (account_status != 'active') → idem, contournement de la
--         protection Phase 7.
--   Le contournement est exploitable via REST direct
--   (GET /rest/v1/trade_events?trade_id=eq.<uuid> avec le JWT de
--   n'importe quel user authentifié), pas besoin d'UI applicative :
--   c'est une fuite de confidentialité de modération, pas une fuite
--   PoP. La preuve publique du trade reste visible (event_type,
--   timestamps), mais le whitepaper §12 garantit que le contenu
--   masqué ne doit plus être lisible — y compris son historique
--   d'events.
--
-- Pourquoi une migration DÉDIÉE plutôt qu'une dette TODO :
--   Indépendamment de toute UI (PoP public, feed social, consultation
--   profil), un appel REST direct contourne toutes les protections
--   applicatives. La seule protection contre cette classe d'attaque
--   est la RLS — et elle était en retard sur la Phase 7. C'est un
--   fix de sécurité, pas un polish.
--
-- Ce que cette migration NE fait PAS :
--   - Ne touche PAS aux autres policies trade_events (insertion par le
--     propriétaire, pas de policy UPDATE/DELETE — l'immutabilité
--     trade_events reste gérée par forbid_trade_events_mutation +
--     app.allow_trade_events_mutation, migration 0001 + 019).
--   - Ne crée PAS de fonction de masquage côté SQL pour les CHAMPS
--     sensibles de old_values/new_values (quantity, fees, entry_price,
--     notes, etc.). C'est une dette séparée : même une fois les
--     policies alignées, si un user voit les events d'un trade public
--     d'un autre user, il verra le diff complet en clair. Cette
--     deuxième couche (masquage des clés sensibles selon users.is_public)
--     est documentée comme dette Phase 9 dans TODO_TECHNIQUE.md et
--     attendra la bascule d'une UI de consultation publique.
--
-- Pourquoi NOT NULL CONFIRMÉ :
--   moderation_hidden (trades/trade_comments) et account_status (users)
--   sont NOT NULL avec default explicite depuis les migrations 016 et
--   015 respectivement. Donc `not moderation_hidden` et
--   `account_status = 'active'` ne peuvent jamais retourner NULL
--   (logique 3 valeurs SQL neutralisée par les contraintes DB) — pas
--   besoin de COALESCE défensif dans la policy.
--
-- Convention de nommage fichier :
--   YYYYMMDDHHMMSS_description.sql, identique aux migrations Phase 7
--   (018_admin_rpcs_and_visibility) et Phase 8 (019_gdpr_export...).
--   Jamais de modification d'une migration déjà appliquée (cf. règle
--   projet, commentée en migration 018). Cette migration est un
--   suivi explicite de la 018.
-- =============================================================================

begin;


-- -----------------------------------------------------------------------------
-- 1. DROP de l'ancienne policy trade_events (Phase 0)
-- -----------------------------------------------------------------------------
-- if exists : la policy peut ne pas exister si on re-run la migration
-- en dev/staging. La 0001 la crée avec ce nom exact ; la 018 a utilisé
-- ce même pattern pour trades et trade_comments.
drop policy if exists "trade_events: lecture si le trade est lisible"
  on public.trade_events;


-- -----------------------------------------------------------------------------
-- 2. CREATE de la nouvelle policy alignée Phase 7
-- -----------------------------------------------------------------------------
-- Miroir STRICT de la policy trades Phase 7 (migration 018) :
--   - case (a) : propriétaire voit TOUJOURS ses events (peu importe
--     is_public / moderation_hidden / son propre account_status). Le
--     proprio doit pouvoir lire son propre historique, c'est
--     l'information dont il a besoin pour comprendre et réagir à une
--     modération le concernant.
--   - case (b) : non-propriétaire autorisé SEULEMENT si le trade
--     parent satisfait les 3 conditions alignées sur trades Phase 7
--       (i)  is_public = true
--       (ii) moderation_hidden = false
--       (iii) owner.account_status = 'active'
--     Les 3 conditions sont évaluées dans la même sous-requête EXISTS
--     avec JOIN users, exactement comme la policy trades Phase 7.
--
-- Pourquoi EXISTS plutôt qu'une jointure directe :
--   Cohérence avec la policy trades Phase 7 (utilise déjà EXISTS +
--   join users pour la même raison — account_status est sur users,
--   pas sur trades). Pas de divergence entre les deux policies : un
--   dev qui lit l'une peut prédire la structure de l'autre.
create policy "trade_events: lecture si le trade est lisible, non masqué"
  on public.trade_events for select
  using (
    -- (a) Propriétaire : accès total à ses propres events, sans condition.
    exists (
      select 1 from public.trades t
      where t.id = trade_events.trade_id
        and t.user_id = auth.uid()
    )
    -- (b) Non-propriétaire : 3 conditions alignées sur trades Phase 7.
    or (
      exists (
        select 1 from public.trades t
        join public.users u on u.id = t.user_id
        where t.id = trade_events.trade_id
          and t.is_public
          and not t.moderation_hidden
          and u.account_status = 'active'
      )
    )
  );


-- -----------------------------------------------------------------------------
-- 3. Commentaire sur la nouvelle policy
-- -----------------------------------------------------------------------------
comment on policy "trade_events: lecture si le trade est lisible, non masqué"
  on public.trade_events is
  'Phase 9 — alignement avec la policy trades Phase 7 (migration 018). Le propriétaire voit toujours ses propres events. Un non-propriétaire n''a accès aux events d''un trade que si celui-ci est public, non masqué par la modération, et que son propriétaire a account_status = ''active''. Pour le masquage des CHAMPS sensibles dans old_values/new_values (quantity, fees, notes, etc.), voir TODO_TECHNIQUE.md §Phase 9 — dette séparée, à traiter avant toute UI de consultation publique.';


commit;
