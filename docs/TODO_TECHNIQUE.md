# TODO Technique — items reportés (à ne pas perdre entre phases)

Items accumulés pendant la Phase 0 / Tâche 2 (schéma DB initial). À traiter
aux phases indiquées, ne pas laisser dériver.

## Avant tout code d'auth sur le schéma (début Phase 1)
- [x] `supabase db reset` propre, sans erreur d'ordre ni de syntaxe
      *(fait — projet Supabase réel en place, migration appliquée, test 4 du
      Front 1 "PASSANT" via capture du directeur : cascade
      `prepare_user_deletion_cascade` validée)*
- [ ] Smoke test `entry_price` : 59s passe, 60s pile passe, 61s bloque
      ⚠ **Non bloquant pour Phase 1** (logique simple, table `trades` non
      touchée par l'auth). **Bloquant pour Phase 2** — à valider avant
      d'attaquer le CRUD trade.
- [ ] Smoke test immuabilité `trade_events` : UPDATE/DELETE direct en rôle
      `authenticated` doit échouer
      ⚠ **Non bloquant pour Phase 1** (idem, table `trade_events` non touchée
      par l'auth). **Bloquant pour Phase 2**.
- [x] `auth.admin.deleteUser()` sur compte test avec ≥1 trade publié —
      confirmer que la cascade passe (cf. trigger
      `prepare_user_deletion_cascade`)
      *(fait — capture du directeur, "No users in your project", la cascade
      passe, le contournement `supabase_auth_admin` est validé)*
- [~] Écrire un minimum de tests de schéma (aucun laissé par Kimi) — Track D/QA
      est censé être actif dès J1 selon la roadmap, ne pas laisser traîner
      jusqu'en Phase 10
      *(en cours — `supabase/tests/01_schema_test.sql` écrit, 19 tests pgTAP :
      contraintes, index partiels, triggers métier, RLS. Exécution déléguée
      au directeur via `supabase test db` — la connexion DB directe est
      bloquée depuis le sandbox agent. À boucler avant Phase 2.)*
- [ ] Déplacer le dashboard mocké de `app/page.tsx` vers
      `app/(dashboard)/page.tsx` une fois l'auth en place. Transformer
      `app/page.tsx` en vraie landing (presentation produit) avec redirect
      authentifié vers `(dashboard)`. Tant que l'auth n'existe pas, pas de
      distinction réelle entre "home" et "dashboard", donc on laisse le
      dashboard à la racine pour l'instant — mais à ne pas oublier en Phase 1.

## Phase 2 (Journaling & Machine à États)
- [ ] Ajouter un trigger d'immuabilité sur `capital` post-publication
      (whitepaper §04 : interdiction d'ajouter du capital à une position
      publiée), calqué sur `enforce_entry_price_immutability`, sans fenêtre
      60s — le capital est verrouillé dès la publication, pas de tolérance
      scalping dessus

## Phase 6 (Réseau Social)
- [ ] Migration : ajouter une contrainte DB sur le format de
      `public.users.pseudo` — `check (pseudo ~ '^[a-zA-Z0-9_-]+$')`.
      Le regex actuel vit uniquement dans le code client d'onboarding,
      mais l'insert passe par l'API Supabase directement avec la clé anon
      (publique par design) — n'importe qui peut bypasser la validation
      client. Le pseudo étant l'identité publique exposée à tous les
      utilisateurs (whitepaper §01, séparation pseudo/identité réelle),
      le format doit être garanti côté DB. À faire avant que les pages
      de profil public soient en ligne.

## Phase 7/8 (Modération / RGPD)
- [ ] Trancher `reports.reporter_id` : rester en `cascade` (choix de
      modélisation assumé, l'historique de signalements disparaît avec le
      compte) ou passer en `set null` comme `reported_user_id`/`resolved_by`
      — à décider selon les besoins réels de la file de modération

## Changements de stack (historique)

- **Passage Next 14 → 16, React 18 → 19** (J+10 de la Phase 0, août 2026).
  Raison : Next 14 est EOL depuis le 26/10/2025 (plus aucun correctif) et
  une RCE critique récente touchant le protocole React Server Components
  ne sera jamais patchée sur cette ligne morte. Toutes les versions sont
  épinglées sur le tag `latest` dans `package.json` pour bénéficier de
  la dernière patch sans nouvelle migration à chaque release. Versions
  effectives au moment du basculement : Next 16.3.2, React 19.2.8.

Points à garder en tête (non bloquants aujourd'hui, à traiter le moment venu) :

- **`fetch()` n'est plus caché par défaut depuis Next 15** (contrairement
  à Next 14). Pertinent dès le premier vrai data-fetching — Analytics
  Engine Phase 4, Market Data Phase 5. Prévoir `cache: 'no-store'` ou
  `revalidate` explicite selon le besoin ; ne pas se reposer sur le
  comportement par défaut.
- **React 19 renomme `useFormState` en `useActionState`**. Pertinent dès
  le premier formulaire réel (login en Phase 1, saisie de trade en
  Phase 2). Vérifier les imports et adapter la signature (`prevState`
  devient le 1er argument).
- **Tailwind fixé à v3.4 dans `package.json`** (pas `latest`). Tailwind
  v4 sortie en 2025 avec breaking changes (plugin PostCSS déplacé vers
  `@tailwindcss/postcss`, syntaxe CSS `@import "tailwindcss"`, config
  CSS-first optionnelle). On reste sur v3 pour la Phase 0 ; migration
  v3 → v4 à traiter comme une tâche dédiée si on le souhaite, hors
  scope de la bascule Next 16.
- **Next 16 a renommé `middleware.ts` en `proxy.ts`** (et l'export
  `middleware` doit s'appeler `proxy`). Le build le signale comme
  deprecation, avec un codemod auto disponible
  (`npx @next/codemod@canary middleware-to-proxy .`). Renommage
  effectué pour la Phase 1. La sémantique de la fonction reste
  identique, seul le nom change.
- **Avatars OAuth en `<img>` brut, pas `next/image`** (Phase 1, dans
  `app/(dashboard)/profile/page.tsx`). Choix volontaire : `next/image`
  demanderait de whitelister les domaines Google/Facebook dans
  `next.config.js` avant de fonctionner. Le warning ESLint
  `@next/next/no-img-element` (inclus dans `next/core-web-vitals`)
  remontera au premier run CI — c'est du bruit attendu, pas un bug.
  Si on veut passer à `next/image` plus tard (optimisation LCP par
  ex.) : ajouter `images.remotePatterns` dans `next.config.js`.

## Maintenance

- [ ] Mettre en place **Dependabot** (ou Renovate / équivalent) pour des
      PR de mise à jour automatiques des deps, plutôt que de compter sur
      quelqu'un qui repense à vérifier les versions à la main. Pas pour
      maintenant — juste pour ne pas le perdre. Verrouillage actuel
      toutes deps figées (caret sur devDependencies, versions exactes
      sur les 5 packages runtime critiques) pour stopper le drift
      immédiat, mais c'est une solution temporaire en attendant l'auto-PR.
