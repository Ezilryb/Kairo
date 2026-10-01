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

- **Tooling CLI / Docker côté directeur — ne jamais supposer** : les
  commandes de type `supabase db reset`, `supabase test db`,
  `supabase db push`, etc. supposent soit une stack locale Docker
  (que le sandbox agent n'a pas, et que la machine du directeur
  n'a pas confirmée), soit un `supabase link` préalable vers un
  projet distant (jamais vérifié). Réflexe : ne jamais recommander
  une commande CLI dans les instructions de test/déploiement sans
  l'avoir vu exécutée au moins une fois dans une sortie de terminal
  du directeur. Voie par défaut fiable et confirmée : dashboard
  Supabase → SQL Editor → coller le SQL (cf. ce qui a été fait pour
  la toute première migration en Phase 0, avec succès). Si le
  directeur confirme un jour avoir le CLI lié au projet, les
  commandes `supabase db push` + `supabase test db` deviennent
  utilisables, mais c'est à vérifier avant de les présenter comme
  la voie standard, pas après.

## Dette technique — Erreurs lint préexistantes (hors scope retransmission)

Erreurs ESLint détectées au `npm run lint` de la Phase 5, **non
introduites par la phase** (les fichiers Phase 5 sont à 0 erreur
après corrections) mais non corrigées dans la session pour ne pas
mélanger les scopes. À traiter dans un round dédié après la clôture
de la Phase 5 — l'idée est de ne pas les perdre de vue juste parce
qu'elles sont "préexistantes" :

- **`app/(dashboard)/trades/[id]/page.tsx:94`** — `react-hooks/purity`
  : `Date.now()` est une fonction impure appelée pendant le render d'un
  composant serveur. La nouvelle règle (React 19 / eslint-plugin-react-
  hooks ≥ 5) la bloque. Le code en question calcule `nowMs` pour
  déterminer si on est dans la fenêtre SL/TP de 60s post-publication.
  Fix : passer en composant client et utiliser `useState` + `useEffect`
  pour `nowMs`, ou bien pré-calculer côté serveur dans le loader.
- **`app/(dashboard)/trades/_components/trade-form.tsx:163, 164, 277`**
  — `react/no-unescaped-entities` : 3 apostrophes `'` non échappées
  dans du JSX texte. Fix cosmétique : remplacer par `&apos;` ou
  utiliser des guillemets courbes typographiques `’`.
- **`app/(dashboard)/profile/page.tsx:49`** — `@next/next/no-img-element`
  (warning) : `<img>` brut pour l'avatar OAuth. **Tolérance déjà
  documentée** plus haut dans ce fichier (cf. section "Points à garder
  en tête"), pas un bug — à traiter uniquement si on switch vers
  `next/image` (whitelist des domaines Google/Facebook dans
  `next.config.js`).

Réflexe à garder pour les futures sessions : quand on fait un
`npm run lint` complet en fin de phase, lister **séparément** les
erreurs de mon fait vs les préexistantes dans le récap, plutôt que
de dire "0 erreur sur mes fichiers" sans dire combien il en reste
ailleurs. Le chef veut le delta complet, pas un booléen.

## Leçons pgTAP / Postgres

Pièges réels rencontrés pendant le debug des tests Phase 5 / Phase 6,
qui ne sont pas tous capturés dans la mémoire collective et qu'on
risque de redécouvrir si on n'a pas la trace.

- **Un bloc DO est void et ne peut PAS faire `RETURN <valeur>`**
  (Phase 6, test 06, 12 tests). Documentation PostgreSQL section DO :
  un bloc `do $$ ... $$` est une fonction sans paramètres qui retourne
  void. `RETURN <expression>;` lève `RETURN cannot have a parameter in
  function returning void`. Pour tester setup + assertion sur une
  valeur dans un même test, le pattern est `lives_ok` avec l'assertion
  faite en interne via `IF <condition_inverse> THEN RAISE EXCEPTION
  '...'; END IF;` — PAS `is()`/`ok()` sur un retour qui n'existe pas.
  Référence : `03_financial_calcs_test.sql` / `04_analytics_test.sql`
  l'utilisent déjà. `is()` et `ok()` restent valables pour comparer une
  valeur produite par un SELECT direct sans setup préalable.

- **RLS WITH CHECK vs USING — deux mécanismes opposés** (Phase 6, test
  7 — première cible DELETE bloqué par RLS pure sans trigger). Distinction
  capturée pour la première fois par un test du projet :
  - **INSERT/UPDATE avec WITH CHECK** : si la nouvelle ligne ne satisfait
    pas la condition, Postgres lève explicitement `new row violates row-
    level security policy`. C'est une exception attrapable par
    `throws_ok`.
  - **SELECT/UPDATE/DELETE avec USING** : la clause USING filtre
    silencieusement les lignes visibles (comme un WHERE implicite). Une
    ligne qui ne passe pas USING n'est simplement pas sélectionnée →
    0 ligne affectée, **AUCUNE exception levée**. Le DELETE ressemble
    à un no-op, exactement comme si l'id demandé n'existait pas. Pour
    tester, il faut `lives_ok` qui vérifie l'**absence d'effet** (la
    ligne est toujours là), pas `throws_ok` qui attend une exception.
  - Référence qui peut confondre : `01_schema_test.sql` tests 3.7/3.8
    lèvent bien sur UPDATE/DELETE via `forbid_trade_events_mutation`,
    mais c'est un **trigger explicite** qui fait `RAISE EXCEPTION`, pas
    la RLS elle-même. La RLS pure reste silencieuse.
  - Ce piège reviendra probablement si followers/unfollow ou d'autres
    suppressions RLS-only sont testées plus tard (et c'est exactement
    le pattern de `likes` : INSERT → WITH CHECK, SELECT → USING,
    DELETE → USING).

- **Cleanup obligatoire pour les agrégats non scopés** (Phase 7, test
  5 — bug raté deux fois avant d'être vu). Distinction piégeuse entre
  deux formes d'assertion dans un test pgTAP :
  - **Vérification scopée** : `SELECT ... WHERE id = v_trade_id` — un
    id précis, créé dans le test, donc isolé des résidus des tests
    précédents. Pas de cleanup nécessaire.
  - **Agrégat non scopé** : `SELECT count(*) FROM public.trades WHERE
    user_id = X AND <état>` — l'agrégat ramasse tout l'historique de X,
    y compris les résidus des tests précédents qui partagent le même
    user. Sans cleanup explicite en tête de bloc, l'assertion compare
    un état "ce test + héritage" à un état "ce test seul", ce qui
    déclenche un faux positif.
  - Le commentaire "le test est autosuffisant : X n'a créé aucun
    trade dans ce test" est trompeur : un count(*) WHERE user_id=X
    n'est pas scopé sur les creations du test. Il faut cleanup en tête
    du bloc, pas juste self-discipline de création.
  - Pattern de cleanup (réutilisé Phase 7 tests 5 et 7) :
    ```sql
    delete from public.reports
      where trade_id in (select id from public.trades where user_id = v_user_b)
         or comment_id in (select id from public.trade_comments where user_id = v_user_b);
    delete from public.trades where user_id = v_user_b;
    ```
    Ordre critique : reports d'abord, sinon ON DELETE SET NULL sur
    `reports.trade_id`/`reports.comment_id` est implémenté comme UPDATE
    interne, soumis au CHECK `(trade_id is not null or comment_id is
    not null or reported_user_id is not null)` → exception. Lesson
    précédente (CHECK sur ON DELETE SET NULL) vue en Phase 6, mais ici
    elle se rappelle à nous dans un nouveau contexte (cleanup de tests
    et non pas migration).
  - Vérifier la couverture du WHERE avant d'appliquer : compter les
    reports via `trade_id` ET `comment_id` pointant sur les posts du
    user ciblé, sur tous les tests précédents — pas juste ceux du test
    courant.

- **SECURITY DEFINER + IF NULL = pas de filet RLS — utiliser IS DISTINCT
  FROM, jamais `<>` (Phase 8, test 9 critique).** Distinction piégeuse
  qui combine 3 mécanismes PostgreSQL/Supabase :
  - **`<>` suit la logique 3 valeurs SQL** : `uuid <> NULL` = NULL
    (pas FALSE, pas TRUE). Un `IF NULL THEN raise` en PL/pgSQL ne lève
    pas (IF exige TRUE, NULL ≡ FALSE).
  - **`auth.uid()` retourne NULL sans JWT** : c'est un wrapper
    `nullif(current_setting('request.jwt.claim.sub', true), '')::uuid`.
    Sans header Authorization (rôle anon) → current_setting → NULL →
    nullif → NULL → ::uuid → NULL.
  - **SECURITY DEFINER bypasse TOUTES les policies RLS** : la fonction
    tourne avec les droits du proprio (postgres, BYPASSRLS = 1). Aucun
    filet de sécurité sur les tables accédées. Le check cassé est la
    SEULE protection.
  - Combinaison : `IF p_user_id <> auth.uid() THEN raise END IF;` dans
    une fonction SECURITY DEFINER sans REVOKE EXECUTE FROM PUBLIC = un
    appel REST anon + p_user_id = uuid de victime = export intégral
    contournant le masquage. L'UUID n'est pas secret (réseau social,
    visible dans le feed).
  - **Fix : `IF p_user_id IS DISTINCT FROM auth.uid() THEN raise`**.
    `uuid IS DISTINCT FROM NULL` = TRUE → raise correct.
  - **Couverture test obligatoire** : un test avec auth.uid() = NULL
    (via `perform set_config('request.jwt.claim.sub', '', true);`)
    pour transformer une fuite silencieuse en exception observable par
    `throws_ok`. Le test traditionnel "deux UUIDs non-null" marche
    identiquement avec `<>` et `IS DISTINCT FROM` → n'attrape jamais
    le bug.
  - **Défense en profondeur complémentaire** : `REVOKE EXECUTE ON
    FUNCTION public.export_user_data(uuid) FROM PUBLIC; GRANT EXECUTE
    ON FUNCTION public.export_user_data(uuid) TO authenticated;`
    (cohérent avec `mark_forgotten_trades` Phase 2). Pas strictement
    requis une fois `IS DISTINCT FROM` en place, mais bloque l'appel
    anon au niveau GRANT avant même qu'il atteigne le check SQL.
    À intégrer dans une migration dédiée (pas lié au calendrier
    Phase 8 — le bug critique Phase 8 est clos côté revue depuis
    plusieurs tours).

- **Paramètre composite en `language sql` — accès par point vs par
  parenthèses** (Phase 9 round 4, leçons du rattrapage migrations
  rattrapées). Piège générique PostgreSQL qui revient à chaque fois
  qu'on écrit une fonction SECURITY INVOKER ou SECURITY DEFINER
  prenant un paramètre de type composite (typiquement `public.trades`)
  en `language sql`. Le pattern fautif :
  ```sql
  create function foo(p_trade public.trades) returns ... as $$
    select p_trade.entry_price;  -- ❌ SYNTAXE AMBIGUË
  $$ language sql;
  ```
  PostgreSQL parse `p_trade.entry_price` comme `table.column` et
  cherche une table nommée `p_trade` dans le FROM. Résultat : erreur
  `relation "p_trade" does not exist` à l'exécution, ou pire : si une
  table nommée `p_trade` existe dans le search_path, lecture d'une
  colonne au lieu du paramètre (résultat silencieux faux). Fix :
  **toujours parenthéser l'accès à un paramètre composite** :
  ```sql
  select (p_trade).entry_price;  -- ✓ accès au paramètre
  ```
  Les parenthèses désambiguïsent : `p_trade.entry_price` = table.colonne
  (cherche `p_trade` dans le FROM), `(p_trade).entry_price` = accès au
  paramètre composite puis projection d'un champ. Sans les parenthèses,
  la plupart des fonctions de `003_financial_calcs.sql`
  (`pnl_gross`, `pnl_net`, `rendement_pct`, `r_multiple`),
  `004_realized_pnl.sql`, `008_plan_adherence_score.sql`, et les 3
  fonctions de `013_privacy_masking.sql` (`trade_visible_capital`,
  `trade_visible_quantity`, `trade_visible_pnl_absolute`) levaient
  une erreur à l'exécution réelle — le parser `plpgsql` était
  probablement plus tolérant que `sql` sur ce cas lors des tests
  antérieurs, ou les tests n'exerçaient pas le path fautif. **Règle** :
  à chaque fonction `language sql` qui prend un paramètre composite,
  recompter les `(param).champ` dans tout le corps et vérifier que
  chaque accès est parenthésé.

- **CTE renvoyant `record` anonyme — pas `public.trades`** (Phase 9
  round 4, même contexte de rattrapage). Quand une fonction SQL passe
  le résultat d'une CTE à une autre fonction qui attend un type
  composite précis (ex : `pnl_net(public.trades)`, `trade_visible_capital(public.trades)`),
  la CTE doit fournir le type attendu. Le pattern fautif :
  ```sql
  with filtered as (select t.* from public.trades t where ...)
  select pnl_net(t.*)  -- ❌ t de la CTE = record anonyme
    from filtered t;
  ```
  Quand `t` vient d'une CTE, son type est `record` (générique), pas
  `public.trades`. La fonction appelée attend un composite typé et le
  cast échoue silencieusement (ou lève, selon la version PG). Fix :
  **ne pas utiliser de CTE intermédiaire** — interroger la table
  directement avec les filtres dans le WHERE final :
  ```sql
  select pnl_net(t.*)
    from public.trades t
    where <conditions>;
  -- ou avec des paramètres : where t.user_id = p_user_id and ...
  ```
  Alternative qui marche : caster explicitement la CTE :
  ```sql
  with filtered as (select t.* from public.trades t where ... order by t.id)
  select pnl_net(filtered.*) from filtered;  -- qualified name, pas alias t
  ```
  Mais la première forme (table directe + WHERE) est plus lisible et
  évite le risque de confusion d'alias. Touchait `009_analytics_crosstab.sql`
  (filtrage puis passage à pnl_net / trade_visible_capital / etc.) et
  `014_feed.sql` (get_feed avec filtrage followers). `010_crosstab_extra_dimensions.sql`
  utilisait déjà la bonne structure (table directe). **Règle** : à chaque
  fonction qui passe `t.*` à une autre fonction typée, vérifier que
  `t` est bien un alias direct vers une table nommée (pas un alias
  depuis une CTE).

- **Loading state React : `useRef` n'est PAS un state** (Phase 9 round 5,
  bug dans `ConfirmDialog` à la première rédaction). Piège : muter un
  ref ne déclenche pas de re-render. Pattern fautif observé :
  ```tsx
  const internalLoadingRef = useRef(false);
  // ...
  const isLoading = externalLoading ?? internalLoadingRef.current;
  // ...
  internalLoadingRef.current = true;  // mutation, pas de re-render
  ```
  Tant qu'un caller passe `loading` (externalLoading), le bug est masqué
  parce que la valeur utilisée vient de la prop. Le premier futur caller
  qui ne passe pas `loading` verra un bouton qui ne passe jamais en
  état "chargement" pendant son propre appel. Fix : `useState`. Le
  contrat de `useRef` = "valeur persistante entre renders, pas de
  re-render déclenché" ≠ "state local du composant". Pour ce dernier,
  c'est `useState`. **Règle** : pour toute valeur qui doit (a) persister
  entre renders ET (b) déclencher un re-render quand elle change, c'est
  `useState`. Si l'un des deux manque, `useRef` peut convenir.

- **`startTransition` ne retourne aucune promesse liée au callback**
  (Phase 9 round 5, bug dans `TradePublishButton` et `TradeTransitionButton`).
  Piège : `startTransition(async () => { ... })` est fire-and-forget
  par construction. La fonction externe `handleX` se résout
  quasi-instantanément après avoir appelé `startTransition`, **avant**
  que la Promesse du callback ne finisse. Pattern fautif observé :
  ```tsx
  const handlePublish = async () => {
    startTransition(async () => {       // ← fire-and-forget
      await supabase.rpc(...);
      // ...
    });
  };
  <ConfirmDialog onConfirm={handlePublish} />
  ```
  Conséquence : `await onConfirm()` dans ConfirmDialog résout
  immédiatement, le dialog se ferme, et l'utilisateur ne voit pas
  l'erreur si le RPC plante. Le caller doit soit :
  ```tsx
  const handlePublish = async () => {
    // Pas de startTransition — RPC direct ici.
    const { data, error } = await supabase.rpc(...);
    if (error) {
      setError(error.message);
      throw new Error(error.message);  // ← throw obligatoire aussi
    }
    // ...
  };
  ```
  `throw` est essentiel : sans throw, le mécanisme "le dialog reste
  ouvert si onConfirm throw" de ConfirmDialog ne se déclenche jamais
  — l'erreur n'apparaît qu'en petit texte sous le bouton après
  fermeture. **Règle** : si on a besoin d'attendre la fin d'une action
  async pour fermer un dialog (ou afficher une erreur dans ce dialog),
  appeler directement la Promesse (sans `startTransition`), et
  `throw` (pas juste `setError(...)`) en cas d'échec. `startTransition`
  est utile uniquement pour les updates NON-bloquants sur la UI
  (markers de saisie, navigation, etc.), pas pour les actions critiques
  qui doivent séquencer un dialog.

- **Policies RLS oubliées lors d'un update d'une policy sœur** (Phase 9,
  discovery pendant l'audit composant PoP). Quand on durcit une policy
  SELECT sur une table (ex : trades en Phase 7 — migration 018, ajout
  de `not moderation_hidden` et `owner.account_status = 'active'`),
  il faut **systématiquement vérifier** les policies des tables liées
  qui dépendent du même predicate via EXISTS. Le trou : la policy
  `trade_events` SELECT (migration 0001) faisait `t.is_public OR
  t.user_id = auth.uid()` via EXISTS sur trades. Phase 7 a durci
  trades mais n'a pas touché trade_events → un user authentifié pouvait
  lire les events d'un trade public masqué par modération ou dont le
  propriétaire était shadowbanned, contournant la garantie Phase 7
  via un simple `GET /rest/v1/trade_events?trade_id=eq.<uuid>`. Le fix
  a été appliqué en migration 020 (`20260903000020_trade_events_policy_align_phase7.sql`) :
  mirror strict de la policy trades Phase 7, mêmes 3 conditions. Tests
  pgTAP : `supabase/tests/09_trade_events_policy_test.sql` (6 assertions,
  5 cas de la table de vérité + 1 régression policy INSERTION).
  - **Leçon à généraliser** : à chaque `CREATE OR REPLACE` / `DROP POLICY
    + CREATE POLICY` sur une table, grep toutes les autres tables qui
    ont une policy référençant cette table via EXISTS, et mettre à jour
    en parallèle. Évite les trous d'évolution policy-sœurs.

- **Couverture asymétrique des branches policy** (Phase 9 round 3, dette
  comblée). Leçon : quand une policy a plusieurs conditions dans un AND,
  il faut **un test par branche** pour détecter un refactor qui retire
  l'une d'elles. Le test 6 du fichier `09_trade_events_policy_test.sql`
  vérifiait qu'un non-propriétaire (A) ne peut pas insérer un event
  sur le trade d'un autre (B) **en posant user_id = A** — branche 2 de
  la policy INSERT KO. Mais branche 1 (`auth.uid() = user_id`)
  n'était jamais exercée : un proprio (B) qui aurait inséré un event
  avec user_id = quelqu'un d'autre sur SON propre trade aurait
  corrompu l'attribution de l'historique immuable (le Proof of
  Performance vend cet historique comme preuve d'intégrité). Sans test
  dédié à cette branche, retirer `auth.uid() = user_id` de la policy
  passait inaperçu. Fix : ajout d'un test 7 dans le même fichier
  (B insère sur trade de B avec user_id = A → throws). Leçon
  généralisable : pour toute policy multi-condition, ajouter un test
  par condition indépendante, pas seulement un test du comportement
  global.

- **Dette Phase 9 — masquage des champs sensibles dans le PoP public**
  (à traiter avant toute UI permettant à un non-propriétaire d'atteindre
  `TradeEventsTimeline` ou d'appeler `trade_events` en lecture publique).
  Constat : même après alignement Phase 7 de la policy `trade_events`
  (migration 020), le composant `TradeEventsTimeline` affiche dans ses
  diffs les clés JSONB suivantes, qui sont des données sensibles au sens
  whitepaper §09 (Taille des Positions, Capital Réel Investi, données
  psycho) :
    - `quantity`, `fees`, `slippage` (montants)
    - `entry_price`, `stop_loss`, `take_profit` (stratégie)
    - `notes`, `emotion`, `stress`, `confidence`, `plan_followed`,
      `mistake_type` (données psycho)
  Le composant PoP est aujourd'hui **owner-only** (`.eq("user_id", user.id)`
  sur les 2 fetches, Phase 9 round 2) — ce qui neutralise le risque
  tant qu'aucune UI de consultation publique n'existe. Mais le jour où
  un PoP public est cadré (lien depuis feed, profil public, etc.), il
  faudra :
    - Soit **créer une fonction SQL `trade_visible_event_values`**
      analogue aux `trade_visible_capital/quantity/pnl_absolute` de
      la migration 013 (privacy_masking Phase 6), qui retourne un JSONB
      redacté selon `users.is_public` + `account_status` + (évent.)
      `followers`. Le trigger `log_sl_tp_changes` (migration 0001) et
      `log_entry_price_changes` (migration 006) INSERT en JSONB brut
      → il faudrait soit modifier ces triggers pour passer par la
      fonction, soit post-process dans une RPC de lecture.
    - Soit **redact côté composant** (filtre post-fetch des clés
      sensibles). Plus simple à court terme, mais la donnée transite
      quand même par le navigateur du viewer — pas une vraie sécurité,
      juste de la rétention visuelle (pattern explicitement rejeté par
      le chef Phase 9, ce qui rend cette option non viable pour le
      PoP public).
  Déclencheur explicite : **avant toute UI permettant à un non-propriétaire
  d'atteindre `TradeEventsTimeline` ou d'appeler `trade_events` en lecture
  publique**. D'ici là, ne PAS retirer le filtre owner-only du composant.
  - Cette convention `IS DISTINCT FROM` au lieu de `<>` est répétée
    dans l'en-tête de chaque fichier de tests depuis la Phase 6. Elle
    n'avait jamais été appliquée au code de production lui-même,
    seulement aux assertions. Leçon à étendre : appliquer aussi
    systématiquement aux checks SQL de production.
