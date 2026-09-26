# Politique de conservation des données — Kairo

> **Phase 8 — RGPD & Export/Migration** (whitepaper v6.0 §10 + §11).
>
> Document de référence opposable : durée de conservation par catégorie de
> donnée, base légale RGPD, sort à l'expiration. À publier dans les CGU
> et à rendre accessible depuis la bannière cookies.

## Principes directeurs

1. **Minimisation** : on ne conserve que ce qui est nécessaire au service
   ou à une obligation légale. Pas de "big data" spéculatif.
2. **Preuve de performance** : les `trade_events` sont la mémoire
   immuable du journal de trading — la donnée EST le produit, pas un
   sous-produit. Conservation indéfinie.
3. **Droits user** : suppression de compte (art. 17), export (art. 20),
   portabilité (art. 20) sont implémentés en Phase 8 (route
   `/api/account/delete`, RPC `export_user_data`).
4. **Hors scope cette phase** : aucune tâche de purge automatisée n'est
   déployée. Les durées ci-dessous sont des **engagements** documentés,
   pas des jobs actifs. La mise en place des jobs de purge est cadrée
   séparément (Phase 8+ ou dédié) — construire une tâche de purge sans
   besoin mesuré serait prématuré et risqué (un bug pourrait toucher
   `trade_events`, qui doit rester immuable).

## Tableau de conservation

| Catégorie | Table(s) | Durée | Base légale RGPD | Sort à l'expiration |
|-----------|----------|-------|------------------|---------------------|
| Trades et événements | `public.trades`, `public.trade_events` | **Indéfinie** | Exécution du contrat (art. 6.1.b) — la donnée EST le service | Suppression à la demande user uniquement (route `/api/account/delete`) |
| Profil public | `public.users` (bio, pseudo, avatar, is_public) | Tant que le compte existe | Exécution du contrat (art. 6.1.b) | Cascade via `auth.users` DELETE → `prepare_user_deletion_cascade` (Phase 0 migration 0001) |
| Audit logs modération | `public.audit_logs` (action INCL. `moderation.*`, `gdpr.*`) | **5 ans** | Obligation légale (art. 6.1.c) — preuve en cas de litige, conformité aux recommandations ANSSI/CNIL sur la traçabilité des décisions automatisées et humaines de modération | Job de purge (à implémenter Phase 8+) : DELETE WHERE created_at < now() - interval '5 years' |
| Audit logs fonctionnels | `public.audit_logs` (autres actions : `trade.*`, `user.gdpr_deleted`, etc.) | **3 ans** | Intérêt légitime (art. 6.1.f) — debug post-mortem, conformité incident | Job de purge : DELETE WHERE created_at < now() - interval '3 years' AND action NOT LIKE 'moderation.%' AND action NOT LIKE 'gdpr.%' |
| Signalements (métier) | `public.reports` | **5 ans** | Obligation légale (art. 6.1.c) — preuve en cas de litige | Job de purge aligné audit_logs modération |
| Notifications | `public.notifications` | **12 mois** | Intérêt légitime (art. 6.1.f) — feed d'activité de l'utilisateur, durée de pertinence UX | Job de purge : DELETE WHERE created_at < now() - interval '12 months' |
| Identité SSO | gérée par Supabase Auth (`auth.users`) | Tant que le compte existe | Exécution du contrat (art. 6.1.b) | Cascade Phase 0 sur DELETE auth.users |
| Sessions actives | cookies Supabase (httpOnly, secure, sameSite=lax) | **~1h** (refresh JWT) | Exemption CNIL §3.2 — strictement nécessaires au service | Renouvellement automatique côté Supabase SSR |
| Logs d'accès serveur | Vercel / Supabase (hors base applicative) | **30 jours** (rétention Vercel par défaut) | Intérêt légitime (art. 6.1.f) — sécurité, debug | Rétention configurée côté Vercel, hors périmètre Kairo |
| Exports RGPD générés | aucun serveur (le user reçoit un JSON en téléchargement, on ne stocke pas) | **0 jour côté serveur** | n/a — l'export n'est jamais persisté par Kairo | Téléchargement unique via `/api/account/export` |

## Cas particulier : `trade_events`

`trade_events` est immuable par construction (trigger
`forbid_trade_events_mutation`, migration 0001). Aucune purge ne doit
toucher cette table, **même après suppression de compte**. Justification :

- L'historique d'événements est ce qui prouve la *performance* (Proof of
  Performance, whitepaper §05) — sans lui, un trade "live" ne peut pas
  être audité a posteriori (SL déplacé ?, TP atteint ?, modification
  dans la fenêtre scalping ?).
- En cas de suppression de compte, le `ON DELETE CASCADE` sur
  `trade_events.user_id` supprime les events liés à l'user. Cette
  cascade est levée par le flag GUC `app.allow_trade_events_mutation`
  posé par `prepare_user_deletion_cascade` (cf. migration 0001). C'est
  l'unique chemin qui peut supprimer des `trade_events`.

## Cas particulier : commentaires soft-deleted

Un commentaire supprimé (modération, `deleted_at IS NOT NULL`) reste
dans la table. Conservation **indéfinie** tant que le compte existe :

- L'audit de modération (`audit_logs` action = `moderation.*`) garde la
  trace de la décision et de son motif.
- L'export RGPD de l'utilisateur inclut ses commentaires supprimés (cf.
  RPC `export_user_data`, migration 019) — la portabilité couvre toutes
  les données détenues, pas seulement celles actuellement visibles dans
  l'UI.

## Cas particulier : suppression de compte et audit

À la suppression de compte, le trigger `prepare_user_deletion_cascade`
insère une ligne dans `audit_logs` avec `action = 'user.gdpr_deleted'`
**avant** que la ligne `public.users` ne disparaisse. Le `user_id` est
volontairement `NULL` sur cette ligne (commentaire Phase 0 : la cible
du DELETE ne peut pas être référencée). `entity_id` porte l'UUID du
user supprimé.

Cette ligne d'audit **persiste 5 ans** (cf. tableau ci-dessus), même
après suppression du compte, pour la traçabilité RGPD : un régulateur
qui demande "qui a supprimé quel compte et quand" doit pouvoir obtenir
une réponse. `pseudo` est dupliqué dans le champ `metadata` au moment
de la suppression pour permettre une lecture humaine de l'audit sans
jointure vers un user désormais inexistant.

## Notification aux utilisateurs en cas de changement

Toute modification de cette politique (ajout d'une catégorie, raccourcissement
d'une durée) sera notifiée par email et via une bannière in-app au moins
**30 jours** avant prise d'effet, conformément aux exigences CNIL sur
la transparence des changements de politique de conservation.

## Références réglementaires

- **RGPD** (UE 2016/679) : art. 5.1.c (minimisation), art. 5.1.e
  (limitation de la durée), art. 6 (bases légales), art. 17 (droit à
  l'effacement), art. 20 (portabilité).
- **Code de commerce** (FR) : art. L123-22 (10 ans pour documents
  comptables — non applicable Kairo hors scope activité marchande).
- **CNIL** : guideline §3.2 (cookies exemptés), §3.4 (bannière non
  bloquante), recommandations sur les durées de conservation
  (https://www.cnil.fr).
- **ANSSI** : recommandations sur la journalisation (référentiel
  général de sécurité).

## Implémentation actuelle (Phase 8)

- **Suppression** : `app/api/account/delete/route.ts` + trigger
  `prepare_user_deletion_cascade` (migration 0001).
- **Export** : `app/api/account/export/route.ts` + RPC
  `public.export_user_data` (migration 019).
- **Cookies** : bannière informative (pas de système de consentement
  complet, aucune catégorie non-essentielle active), helper
  `lib/cookie-consent.ts` prêt à être branché.
- **Politique** : ce document + lien depuis la bannière cookies + à
  inclure dans les CGU au déploiement production.

## Dette technique identifiée

Voir `docs/TODO_TECHNIQUE.md` §Phase 8 — section à enrichir après
validation chef.
