# TODO Technique — items reportés (à ne pas perdre entre phases)

Items accumulés pendant la Phase 0 / Tâche 2 (schéma DB initial). À traiter
aux phases indiquées, ne pas laisser dériver.

## Conventions UI (transversales, toutes phases)

Règles à respecter sur **tous** les écrans, présentes pour éviter qu'on
les perde entre deux commits. Listées en haut du doc exprès.

- **Badges de statut de trade = cycle de vie, jamais issue financière.**
  Les badges encodent l'état dans la machine à états (draft / live /
  closed / forgotten / archived), pas le résultat PnL. Un trade clôturé
  peut l'être à perte — le badge ne le dit pas, c'est le PnL affiché
  ailleurs sur l'écran (en couleur, dans la section résultat) qui le
  porte. Teinter `closed` en `success` (vert) fait croire qu'un trade
  clôturé est forcément gagnant, c'est faux. Teinter `archived` en
  `success`/`danger` n'a aucun sens. Teinter `forgotten` en `danger`
  suggérerait à tort un problème. Tous ces statuts sont neutres par
  défaut (`bg-neutral-100 text-neutral-700`). Seuls les indicateurs
  financiers (PnL, R-multiple, winrate agrégé) portent la couleur
  trading. Bug déjà corrigé deux fois dans ce projet (dashboard mocké
  Phase 0, page détail trade Phase 2 Point C/D) — d'où la règle
  documentée. **Ne JAMAIS re-teinter un badge de statut en success /
  danger sauf si on parle explicitement d'un résultat financier.**

- **Tokens sémantiques uniquement via `tailwind.config.ts`.** Pas de
  classes Tailwind neutres hardcodées pour signifier un état métier
  (ex: pas de `bg-green-100` pour dire "succès", on utilise
  `bg-success-subtle`). Le design system centralise la palette, c'est
  le seul point de vérité. (Règle déjà appliquée — rappel pour
  éviter le drift.)

- **Pas de `bg-card` qui ne vient pas de `tailwind.config.ts`.** Si
  `bg-card` ne génère rien dans Tailwind, c'est que la couleur n'est
  pas déclarée — pas un bug Tailwind, c'est qu'on a oublié de
  l'ajouter à `theme.extend.colors.card`. Corrigé une fois en
  Phase 0 / Tâche 3. (Rappel — la couleur `card: "#FFFFFF"` est
  dans la config, ne pas la redéclarer ailleurs.)

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

- [x] Ajouter un trigger d'immuabilité sur `capital` post-publication
      (whitepaper §04 : interdiction d'ajouter du capital à une position
      publiée), calqué sur `enforce_entry_price_immutability`, sans fenêtre
      60s — le capital est verrouillé dès la publication, pas de tolérance
      scalping dessus
      *(fait — migration `20260831000001_trades_lifecycle.sql` + tests
      `02_trades_lifecycle_test.sql`, 4 cas pgTAP. Fix `old.status` vs
      `new.status` : la transition `draft → live` avec augmentation de
      capital dans le même UPDATE doit passer. Trigger `log_partial_exits`
      jumeau de `log_sl_tp_changes` pour la traçabilité des sorties
      partielles. Seed d'instruments : BTCUSDT, ETHUSDT, AAPL, TSLA,
      EURUSD, GLD.)*
- [x] Seed d'instruments courants (6 symboles) pour la Tâche B
      *(fait dans la même migration `02`, `on conflict (symbol, exchange)
      do nothing` pour idempotence manuelle.)*
- [ ] **Point B — CRUD brouillon + sélection d'instrument** : page de
      création/édition d'un trade en `draft`, formulaire avec
      sélection d'instrument (dropdown sur le seed), `direction`,
      `entry_price`, `quantity`, `capital`, `instrument_id` obligatoires.
      Champs persos/psychologie vides à ce stade (optionnels dans le
      schéma, pas la peine de forcer).
- [ ] **Point C — Publication + fenêtre scalping** : transition
      `draft → live`, pose `published_at`, indicateur visuel du compte
      à rebours 60s, gestion propre du rejet du trigger `entry_price`
      post-fenêtre.
- [ ] **Point D — Transitions manuelles + job planifié** : clôture
      `live`/`forgotten` → `closed`, archivage `closed` → `archived`,
      réactivation `forgotten` → `live` (pas un statut, une transition —
      pas d'enum à ajouter). Job Vercel Cron `forgotten` (5 jours
      d'inactivité), `WHERE` doit matcher l'index `trades_last_activity_idx`
      (filtré sur `status = 'live'`).
- [ ] **5ème cas test pgTAP** (à ajouter à `02_trades_lifecycle_test.sql`
      à l'occasion) : `last_activity_at` doit être rafraîchi même sur
      la transition `draft → live` (mise à jour inconditionnelle dans
      `log_sl_tp_changes`). Figer par test pour ne pas dépendre d'une
      relecture attentive future.

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

## Leçons CI/CD

Issues réelles rencontrées pendant le debug du premier pipeline CI en
août 2026, qui ne sont pas toutes capturées dans l'historique des commits
et qu'on risque de redécouvrir si on n'a pas la trace.

- **Bug npm `npm/cli#7961`** : `npm install` avec un `node_modules`
  déjà présent **élague silencieusement** les entrées optionnelles
  cross-plateforme du lockfile. Sur Windows, les deps WASM de `sharp`
  (qui tirent `@emnapi/*`) ne sont pas activées → elles disparaissent
  du lockfile → la CI Linux n'a pas ce qu'il faut et échoue. Règle :
  toujours supprimer `node_modules` **avant** `package-lock.json`, jamais
  l'un sans l'autre, avant un `npm install` qui doit produire un lockfile
  fiable pour la CI cross-plateforme. L'ordre des suppressions compte.
- **`next lint` n'existe plus en Next 16** (supprimé, pas juste buggé).
  Le script `lint` dans `package.json` doit appeler `eslint .` directement.
  Config dans `eslint.config.mjs` (flat config, pas `.eslintrc.json`),
  qui importe **deux** presets `eslint-config-next` :
  `core-web-vitals` ET `typescript` (le second s'oublie facilement).
  Les deux configs doivent être assignées à une variable avant l'export
  par défaut, sinon ESLint 9 lève un warning `import/no-anonymous-default-export`.
- **Supabase Auth — URL Configuration** : dans le dashboard Supabase,
  `Authentication → URL Configuration`, le `Site URL` doit être le vrai
  domaine Vercel (`https://<app>.vercel.app` ou domaine custom), pas
  `localhost:3000` qui marche en dev. Les `Redirect URLs` doivent
  inclure ce même domaine en plus des URLs de dev. Sans ça, les
  redirections OAuth échouent silencieusement en prod (pas d'erreur
  explicite côté client, juste un retour sur la page de login).
