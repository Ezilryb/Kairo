# 📍 /docs/ROADMAP.md

# FEUILLE DE ROUTE — Trading Journal & Réseau Social
_Basée sur le Whitepaper v6.0 — Mise à jour : deadline repoussée à J+100_

---

## 🗓️ Cadrage

- **Durée totale : 100 jours calendaires**, échéance = J+100 à partir du
  13/08/2026, soit autour du **21/11/2026**.
- **Équipe plus large** (plusieurs développeurs/rôles en parallèle) → on
  organise le travail en **tracks parallèles** plutôt qu'en pure séquence,
  pour utiliser la capacité de l'équipe au lieu d'aligner tout en série.
- Le périmètre complet du whitepaper (v6.0) est couvert, y compris RGPD,
  modération et une partie des idées innovantes post-MVP.
- Chaque fichier de code que je produirai commencera par un commentaire
  indiquant son **emplacement exact** dans l'arborescence, comme demandé.

## 🧑‍🤝‍🧑 Organisation en tracks (équipe large)

| Track | Rôle(s) type | Contenu |
|---|---|---|
| **Track A — Core & Data** | Backend / DB | Auth, schéma DB, state machine des trades, calculs financiers, analytics engine |
| **Track B — Frontend & UX** | Frontend / Design | Design system, dashboard, écrans trade, charts, UI réseau social |
| **Track C — Social & Trust** | Backend / Product | Réseau social, modération, RGPD |
| **Track D — QA & DevOps** | QA / DevOps | Tests, CI/CD, déploiement, durcissement — **transverse, actif du J1 au J100** |

Les tracks A et B démarrent ensemble dès J1 (le back a besoin du schéma,
le front peut avancer sur le design system et les maquettes en parallèle).
Track C démarre dès que le socle de trades (fin Track A - Phase 2/3) est stable.
Track D tourne en continu, avec un pic en fin de projet (Phase 10).

---

## 🧱 Stack technique retenue (100 % gratuit)

| Besoin | Choix | Pourquoi |
|---|---|---|
| Frontend | **Next.js 14 (App Router) + TypeScript + TailwindCSS** | SSR/SSG, écosystème riche, gratuit |
| Hébergement frontend/API | **Vercel (plan Hobby, gratuit)** | Déploiement en 1 clic, cron jobs inclus |
| Backend | **Next.js API Routes / Server Actions** | Pas d'infra séparée à payer |
| Base de données | **Supabase (Postgres, plan Free)** | Relationnel, 500 Mo, Auth + Storage inclus |
| Authentification | **Supabase Auth (SSO Google, Facebook)** | Correspond à l'exigence "SSO uniquement" |
| Stockage fichiers (exports, screenshots) | **Supabase Storage (Free tier)** | Intégré à Supabase |
| Market Data | **Binance Public REST API** (gratuit, sans clé) + **CoinGecko Free API** | Couche `MarketDataProvider` |
| Graphiques trading | **TradingView Lightweight Charts** (open-source, gratuit) | Chandeliers, volume, zoom |
| Graphiques analytics | **Recharts** | Winrate, équity curve, cross-analytics |
| Icônes | **Tabler Icons / Heroicons / Lucide / Iconoir** | Comme demandé |
| Tâches planifiées (ex: passage en statut OUBLIÉ après 5j) | **Vercel Cron Jobs (Free)** ou **Supabase Edge Functions + pg_cron** | Gratuit dans les limites du plan |
| CI/CD | **GitHub Actions (Free pour repo public/perso)** | Tests + déploiement auto |

> Limite à surveiller : Supabase Free tier = projet mis en pause après 7 jours
> d'inactivité (redémarrage automatique au 1er accès) et 500 Mo de DB — largement
> suffisant pour un MVP et les premiers mois d'usage réel.

---

## 🗺️ Phasage du projet (100 jours / 11 phases)

| # | Phase | Track | Jours | Fenêtre (J) |
|---|---|---|---|---|
| 0 | Setup & Architecture | A + B | 5 | J1 – J5 |
| 1 | Authentification & Profils | A | 7 | J6 – J12 |
| 2 | Journaling & Machine à États des Trades | A | 12 | J13 – J24 |
| 3 | Calculs Financiers | A | 8 | J25 – J32 |
| 4 | Analytics Engine avancé | A | 15 | J33 – J47 |
| 5 | Market Data & Graphismes | B | 12 | J25 – J36 *(parallèle à 3-4)* |
| 6 | Réseau Social | C | 12 | J33 – J44 *(parallèle à 4-5)* |
| 7 | Modération & Sanctions | C | 8 | J45 – J52 |
| 8 | RGPD & Export/Migration | C | 7 | J53 – J59 |
| 9 | UI/UX Polish & Idées innovantes | B | 8 | J60 – J67 |
| 10 | QA globale, durcissement, déploiement final | D | 6 | J95 – J100 |

**Total séquentiel des efforts : 100 jours-track**, mais grâce au
chevauchement des tracks A/B/C, le calendrier réel tient dans les
**100 jours calendaires**, avec une marge de sécurité (~J68 à J94, ~27 jours)
allouée en **buffer** : retours QA continue, ajustements de scope, corrections
de bugs remontés en cours de route, montée en charge progressive.

### Détail des phases

**Phase 0 — Setup & Architecture** *(Track A+B, 5j)*
- Initialisation repo (structure `/app`, `/lib`, `/components`, `/docs`)
- Config Supabase (projet, variables d'env, schéma initial)
- Config Vercel (déploiement continu depuis GitHub) + CI/CD GitHub Actions
- Design system : palette, typographie, layout inspirés de **Google Finance**
  (cartes épurées, data-dense, mode clair, accents verts/rouges)
- Mise en place Tailwind + jeu d'icônes (Tabler/Heroicons/Lucide/Iconoir)

**Phase 1 — Authentification & Profils** *(Track A, 7j)*
- SSO Google + Facebook via Supabase Auth
- Table `Users`, gestion Pseudo vs identité SSO
- Profil Public vs Privé (règles de visibilité du tableau §09)
- Dashboard de profil (structure, alimentée en Phase 3)

**Phase 2 — Journaling & Machine à États des Trades** *(Track A, 12j)*
- Tables `Trades` + `TradeEvents` (historique immuable)
- CRUD trade complet : DRAFT → LIVE → (OUBLIÉ → RÉACTIVÉ) → CLÔTURÉ → ARCHIVÉ
- Règles de verrouillage (entry price figé, SL/TP figés, exception scalping 60s)
- Sorties partielles / interdiction d'ajout de capital
- Job planifié : bascule auto en OUBLIÉ après 5 jours d'inactivité

**Phase 3 — Calculs Financiers** *(Track A, 8j)*
- Moteur de calcul : PnL brut/net, Rendement %, Rendement en R
- Winrate, Profit Factor, Expectancy, Max Drawdown, MAE/MFE
- Profils de frais par plateforme (Binance, Kraken...) + correction manuelle

**Phase 4 — Analytics Engine avancé** *(Track A, 15j)*
- Croisements multidimensionnels (Asset × Session × Setup × Timeframe...)
- Champs psychologiques (FOMO, revenge trading, surconfiance...)
- Plan Adherence Score (/100)

**Phase 5 — Market Data & Graphismes** *(Track B, 12j, en parallèle de 3-4)*
- Intégration Binance / CoinGecko (symbol mapping, timezones, gaps)
- Charts Mode Standard vs Pro (indicateurs, annotations, événements)
- Trade Replay

**Phase 6 — Réseau Social** *(Track C, 12j, démarre une fois le socle trades stable)*
- Feed, Followers, Likes, Commentaires
- Masquage des montants selon confidentialité

**Phase 7 — Modération & Sanctions** *(Track C, 8j)*
- Signalements (Spam, Arnaque, Fausse info, Harcèlement, Usurpation)
- Workflow automatisé (flags → shadowban → blocage manuel)
- Tables `Reports`, `AuditLogs`

**Phase 8 — RGPD & Export/Migration** *(Track C, 7j)*
- Export complet des données, suppression de compte
- Procédure de restauration avec "protection temporaire" 10 jours
- Politique de conservation des données, gestion cookies opt-in

**Phase 9 — UI/UX Polish & Idées innovantes** *(Track B, 8j)*
- Finitions visuelles façon Google Finance sur l'ensemble des écrans
- Sélection d'idées post-MVP à intégrer si le temps le permet : Import CSV
  massif, Proof of Performance, Score de Maturité du Trader

**Phase 10 — QA globale & déploiement final** *(Track D, 6j)*
- Tests de bout en bout, charge, sécurité (RLS Supabase, permissions)
- Revue RGPD finale, checklist de conformité
- Déploiement production, monitoring, plan de rollback

---

## ✅ Prochaine étape immédiate

Je démarre la **Phase 0** : structure du repo, schéma de base de données
(Supabase/SQL), et premier écran (dashboard) avec une UI inspirée de
Google Finance — en parallèle, je pose les bases du design system pour
que le Track B (frontend) puisse enchaîner sans attendre.

Dis-moi si ce découpage te va, ou si tu veux que je réordonne certaines
phases (ex: sortir la modération plus tôt, ou avancer le réseau social).
