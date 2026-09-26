# Phase 8 — Protocole de test manuel (RGPD & Export/Migration)

> **Pourquoi un test manuel et pas pgTAP ?** Comme la Phase 5, la Phase 8
> est majoritairement TypeScript/frontend : deux routes API Next.js, une
> bannière cookies, un helper de consentement. pgTAP couvre la partie
> SQL (RPCs `export_user_data`, `flag_restoration_conflict`, colonne
> `restoration_hold_until`) dans `supabase/tests/08_gdpr_test.sql`
> (8 assertions). Le reste doit être validé visuellement et via
> l'observateur réseau du navigateur, comme on le ferait pour n'importe
> quelle app Next.js.

> **Différence avec Phase 5** : la Phase 5 n'avait qu'un endpoint
> authentifié (mae-mfe). La Phase 8 ajoute une route **avec service_role**
> (delete account), qui ne peut pas être testée en curl sans la clé. Le
> test navigateur est la seule option.

---

## Pré-requis

1. Build OK : `npm run build` (Phase 8 n'ajoute aucune dépendance
   npm — uniquement du code applicatif).
2. Migration SQL appliquée :
   **`supabase/migrations/20260903000019_gdpr_export_and_restoration.sql`**
   (toutes les migrations précédentes jusqu'à 018 doivent déjà être
   appliquées).
3. pgTAP test passé : `supabase/tests/08_gdpr_test.sql` (8 assertions,
   doit retourner vert). Couvre :
   - export_user_data self → JSON avec toutes les clés
   - export_user_data d'un autre user → throws
   - export inclut commentaires soft-deleted
   - profile exclut account_status
   - flag_restoration_conflict admin → hold posé + audit_log
   - flag_restoration_conflict non-admin → throws
   - flag_restoration_conflict reason vide → throws
   - flag_restoration_conflict user inexistant → throws
4. Variable d'env **SUPABASE_SERVICE_ROLE_KEY** configurée dans Vercel
   (Production minimum). Sans elle, `/api/account/delete` retourne
   immédiatement 500 `ENV_MISSING` — c'est volontaire (fail loud,
   cf. `lib/supabase/service.ts`).
5. Au moins 1 compte de test avec :
   - 2-3 trades (mix live + closed)
   - 1-2 commentaires (dont 1 soft-deleted via modération ou manuellement)
   - 1-2 likes donnés
   - 1 relation follower/followee

---

## Test 1 — Export RGPD (portabilité art. 20)

**Objectif** : vérifier que l'endpoint `/api/account/export` retourne
un JSON complet et conforme.

### Étapes navigateur

1. Connecte-toi à Kairo avec le compte de test (cookie de session valide).
2. Ouvre les DevTools → onglet **Network** (filter : `export`).
3. Navigue vers `/api/account/export` directement (GET).
4. Observe :
   - Status **200 OK**.
   - Header `Content-Type: application/json; charset=utf-8`.
   - Header `Content-Disposition: attachment; filename="kairo-export-<pseudo>-YYYY-MM-DD.json"`.
   - Body JSON bien formé avec les clés top-level :
     `profile`, `trades`, `trade_events`, `comments`, `likes_given`,
     `following`, `followers`, `exported_at`.
5. Vérifie les **exclusions critiques** :
   - `profile` ne contient **PAS** la clé `account_status`.
     → Si présente, c'est un bug Phase 8 (regression sur `to_jsonb(u) - 'account_status'`).
   - `profile` ne contient **PAS** de référence à `auth.users` (pas de
     colonnes identité SSO).
6. Vérifie que les commentaires soft-deleted apparaissent dans
   `comments` (avec `deleted_at` non-null). C'est le test pgTAP 3
   qui le couvre côté DB ; ici on confirme que la chaîne complète
   route → RPC → DB → UI renvoie bien ces données.
7. Télécharge le fichier et ouvre-le dans un éditeur de texte : il
   doit être lisible (JSON.stringify avec indentation 2, pas minifié).

### Vérification DB complémentaire

```sql
-- Audit log attendu côté DB : aucun (export ne loggue pas côté audit_logs
-- par conception, c'est un acte user légitime non sensible — voir
-- RETENTION_POLICY.md).
SELECT count(*) FROM public.audit_logs
  WHERE action = 'account.exported';
-- attendu : 0
```

---

## Test 2 — Export d'un autre user (impossible via UI, test côté console)

**Objectif** : vérifier qu'aucun user ne peut exporter les données
d'un autre user, même en manipulant la requête.

### Étapes navigateur

1. Connecte-toi avec user A.
2. Ouvre la **Console DevTools**.
3. Tente :
   ```js
   const r = await fetch('/api/account/export');
   const j = await r.json();
   ```
   → Body doit être l'export de A (filenames contient le pseudo de A,
   profil pointe vers A).
4. Pour tester le check self du RPC directement (le check est côté SQL,
   pas côté route — la route passe `user.id` extrait du JWT), ouvre
   **SQL Editor Supabase** en étant connecté au rôle `postgres` :
   ```sql
   -- A essaie d'exporter B (A et B sont deux UUIDs distincts).
   -- Note : on simule le JWT de A via set_config, puis on appelle
   -- le RPC avec p_user_id = B. Le check p_user_id = auth.uid() doit lever.
   perform set_config('request.jwt.claim.sub', '<UUID_A>', true);
   select public.export_user_data('<UUID_B>');
   ```
   → Erreur attendue :
   ```
   export_user_data: p_user_id (<UUID_B>) ne correspond pas à auth.uid() (<UUID_A>)
   ```
   C'est exactement le test pgTAP 2 côté DB.

---

## Test 3 — Suppression de compte (route + trigger cascade)

**Objectif** : vérifier que la suppression via `/api/account/delete`
déclenche bien la cascade complète (auth.users → public.users → trades
→ trade_events / comments / likes / followers) et écrit l'audit log.

### Étapes navigateur

> **⚠ DANGER — TEST DESTRUCTIF ⚠**
> Ce test supprime DÉFINITIVEMENT le compte de test. Crée un compte
> dédié (e.g. `gdpr-test-delete@kairo.local`) avec quelques trades
> et commentaires avant de commencer.

1. Connecte-toi avec le compte de test DÉDIÉ.
2. Vérifie la présence des données en base avant suppression :
   ```sql
   SELECT count(*) AS trades_count FROM public.trades
     WHERE user_id = '<UUID_COMPTE_TEST>';
   SELECT count(*) AS events_count FROM public.trade_events
     WHERE user_id = '<UUID_COMPTE_TEST>';
   SELECT count(*) AS comments_count FROM public.trade_comments
     WHERE user_id = '<UUID_COMPTE_TEST>';
   ```
   → Note les compteurs (ex : 3 trades, 5 events, 2 comments).
3. Ouvre les DevTools → onglet **Network** (filter : `delete`).
4. Navigue vers `/api/account/delete` via la console :
   ```js
   const r = await fetch('/api/account/delete', { method: 'POST' });
   console.log(r.status);
   ```
   → Status attendu : **204 No Content**.
5. Après la requête, tente de naviguer vers `/` :
   → Redirection vers `/login?redirectTo=/` (le layout dashboard
   applique la défense en profondeur : `getUser()` échoue car le user
   n'existe plus côté auth).
6. Vérifie la cascade en DB :
   ```sql
   -- L'utilisateur auth.users doit être supprimé.
   SELECT id FROM auth.users WHERE id = '<UUID_COMPTE_TEST>';
   -- attendu : 0 ligne
   SELECT id FROM public.users WHERE id = '<UUID_COMPTE_TEST>';
   -- attendu : 0 ligne
   SELECT count(*) FROM public.trades WHERE user_id = '<UUID_COMPTE_TEST>';
   -- attendu : 0 (cascade OK)
   SELECT count(*) FROM public.trade_events WHERE user_id = '<UUID_COMPTE_TEST>';
   -- attendu : 0 (cascade OK + flag GUC a permis à forbid_trade_events_mutation de passer)
   ```
7. Vérifie l'audit log :
   ```sql
   SELECT action, entity_type, entity_id, metadata
     FROM public.audit_logs
     WHERE action = 'user.gdpr_deleted'
       AND entity_id = '<UUID_COMPTE_TEST>';
   -- attendu : 1 ligne, metadata.pseudo contient le pseudo du compte supprimé
   ```
   Cette ligne persiste 5 ans (cf. `RETENTION_POLICY.md`), même si le
   compte n'existe plus.

---

## Test 4 — Suppression non authentifiée → 401

**Objectif** : vérifier que la route refuse un appel sans session.

### Étapes navigateur

1. Ouvre une fenêtre **navigation privée** (pas de cookie de session).
2. Console DevTools :
   ```js
   const r = await fetch('/api/account/delete', { method: 'POST' });
   console.log(r.status, await r.json());
   ```
   → Status attendu : **401**, body `{ error: "Non authentifié", code: "NON_AUTHENTICATED" }`.

---

## Test 5 — Bannière cookies (UI)

**Objectif** : vérifier que la bannière s'affiche avec le contenu
attendu et se ferme au clic.

### Étapes navigateur

1. Ouvre une fenêtre **navigation privée** (pour partir d'un état
   propre sans aucune mémoire côté UI).
2. Navigue vers `https://<kairo-staging>/login`.
3. Observe en bas à droite : la bannière `Cookies utilisés par Kairo`
   doit être visible avec :
   - Titre "Cookies utilisés par Kairo"
   - Mention "uniquement des cookies essentiels (session Supabase Auth)"
   - Liste à 3 entrées : Essentiels (vert, actif), Analytics (gris,
     "non utilisés"), Marketing (gris, "non utilisés")
   - Lien vers `/docs/RETENTION_POLICY.md`
   - Bouton **Compris**
4. Clique sur **Compris** → la bannière disparaît.
5. Recharge la page (F5) → la bannière réapparaît (state local React,
   pas de persistance — intentionnel cette phase, cf. commentaire
   en tête du composant).
6. Ouvre la console DevTools → vérifie qu'aucun cookie non-essentiel
   n'a été posé (uniquement les cookies Supabase Auth standard :
   `sb-<project>-auth-token`, etc.).

---

## Test 6 — Helper `hasConsent` (smoke test unitaire)

**Objectif** : vérifier le contrat du helper côté code (pas
d'observable réseau).

### Étapes

```ts
// Dans un REPL Node ou un composant de dev :
import { hasConsent, activeCategories } from '@/lib/cookie-consent';

hasConsent('essential');  // true (toujours)
hasConsent('analytics');  // false (pas de cookie analytics cette phase)
hasConsent('marketing');  // false (idem)
activeCategories();        // ['essential'] uniquement
```

---

## Test 7 — pgTAP global (sanity régression)

**Objectif** : s'assurer que la migration 019 ne casse aucun test des
phases précédentes.

### Étapes

1. Dashboard Supabase → SQL Editor.
2. Exécute dans l'ordre :
   - `supabase/tests/01_schema_test.sql` (21 assertions)
   - `supabase/tests/02_trades_lifecycle_test.sql` (14 assertions)
   - `supabase/tests/03_financial_calcs_test.sql` (22 assertions)
   - `supabase/tests/04_analytics_test.sql` (30 assertions)
   - `supabase/tests/05_market_data_test.sql` (5 assertions)
   - `supabase/tests/06_social_test.sql` (20 assertions)
   - `supabase/tests/07_moderation_test.sql` (14 assertions)
   - `supabase/tests/08_gdpr_test.sql` (8 assertions)
3. Total attendu : **134 assertions, 0 échec**.

---

## Critères de validation Phase 8

- [ ] `npm run build` exit 0
- [ ] Migration 019 appliquée sans erreur
- [ ] pgTAP `08_gdpr_test.sql` : 8/8 vert
- [ ] pgTAP régression 01-07 : 126/126 vert (aucune régression)
- [ ] Test 1 export : JSON conforme, exclusions respectées
- [ ] Test 2 export other user : erreur SQL attendue (via console ou SQL Editor)
- [ ] Test 3 delete cascade : 204 + 0 ligne en base + 1 audit_log
- [ ] Test 4 delete sans session : 401
- [ ] Test 5 bannière cookies : affichage + fermeture OK
- [ ] Test 6 helper : valeurs attendues
