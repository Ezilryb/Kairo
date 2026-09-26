// /components/cookie-consent-banner.tsx
// =============================================================================
// Bannière informative cookies — Phase 8 RGPD (whitepaper §10).
//
// Cadrage chef (Phase 8 brief) :
//   "Bannière informative minimale déclarant l'usage actuel (essentiels
//   uniquement) [...] Pas de nouvelle colonne DB pour tracker un
//   consentement cette phase — rien à consentir concrètement pour
//   l'instant."
//
// Scope MVP :
//   - Déclare honnêtement au visiteur ce que Kairo utilise aujourd'hui
//     (cookies essentiels uniquement, exemptés de consentement CNIL).
//   - Bouton "Compris" qui ferme la bannière (state local React, PAS de
//     persistance — rien à consentir).
//   - Catégorie 'analytics' listée avec une mention "non utilisée" pour
//     transparence (l'utilisateur voit qu'on a conscience qu'elle existe
//     et qu'on ne l'a pas activée), pas un toggle (un toggle qui ne
//     contrôle rien = dark pattern).
//   - Mention textuelle du nom du document de politique de conservation,
//     SANS lien href : /docs/ n'est pas sous /public (donc Next.js
//     sert un 404 sur /docs/RETENTION_POLICY.md). La politique sera
//     incluse dans les CGU au déploiement production (cf. fin du doc
//     RETENTION_POLICY.md lui-même). Mettre un <a> ici pointerait
//     dans le vide — bug identifié Phase 8 round 2.
//
// Design system : Card + Button + tokens sémantiques (text-neutral-500
// pour le disclaimer, danger pour le rappel RGPD). Pas d'animation
// lourde — fade in léger pour ne pas bloquer le rendu perçu.
//
// Position : fixed bottom-right, dismissible. Ne bloque pas la navigation
// (z-50 mais sous le contenu interactif). Conforme aux guidelines CNIL
// §3.4 (la bannière ne doit pas empêcher l'utilisateur de naviguer).
//
// Quand on branchera analytics (Plausible, etc.) :
//   1. Importer activeCategories() depuis lib/cookie-consent et adapter
//      l'affichage
//   2. Ajouter des toggles pour les nouvelles catégories
//   3. Persister le choix (localStorage ou cookie 'kairo_consent')
//   4. Lire ce choix dans hasConsent() côté consommateur
// =============================================================================
"use client";

import { useState } from "react";
import { Card } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";

export function CookieConsentBanner() {
  // State local pur : pas de persistance cette phase (cf. commentaire en
  // tête). Si l'utilisateur recharge la page, la bannière revient — c'est
  // intentionnel : on n'a rien à mémoriser puisqu'on n'utilise que des
  // cookies essentiels, et l'utilisateur n'a aucun choix à faire.
  const [dismissed, setDismissed] = useState(false);

  if (dismissed) return null;

  return (
    <div
      role="region"
      aria-label="Information sur les cookies"
      className="fixed bottom-4 right-4 z-50 max-w-md"
    >
      <Card padding="md" className="shadow-lg">
        <div className="space-y-3">
          <div>
            <h2 className="text-sm font-semibold text-neutral-900">
              Cookies utilisés par Kairo
            </h2>
            <p className="mt-1 text-xs text-neutral-500">
              Kairo utilise uniquement des cookies <strong>essentiels</strong>{" "}
              (session Supabase Auth), strictement nécessaires au service et
              exemptés de consentement.
            </p>
          </div>

          <ul className="space-y-1 text-xs text-neutral-700">
            <li className="flex items-start gap-2">
              <span
                aria-hidden
                className="mt-1 inline-block h-1.5 w-1.5 flex-shrink-0 rounded-full bg-success"
              />
              <span>
                <strong>Essentiels</strong> : session de connexion. Toujours
                actifs.
              </span>
            </li>
            <li className="flex items-start gap-2">
              <span
                aria-hidden
                className="mt-1 inline-block h-1.5 w-1.5 flex-shrink-0 rounded-full bg-neutral-300"
              />
              <span>
                <strong>Analytics</strong> : non utilisés à ce jour.
              </span>
            </li>
            <li className="flex items-start gap-2">
              <span
                aria-hidden
                className="mt-1 inline-block h-1.5 w-1.5 flex-shrink-0 rounded-full bg-neutral-300"
              />
              <span>
                <strong>Marketing</strong> : non utilisés à ce jour.
              </span>
            </li>
          </ul>

          <p className="text-[10px] text-neutral-400">
            Le détail des données conservées et leurs durées est décrit
            dans la politique de conservation, disponible dans les CGU
            au déploiement production.
          </p>

          <div className="flex justify-end">
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setDismissed(true)}
              aria-label="Fermer la bannière d'information cookies"
            >
              Compris
            </Button>
          </div>
        </div>
      </Card>
    </div>
  );
}
