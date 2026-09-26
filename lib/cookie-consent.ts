// /lib/cookie-consent.ts
// =============================================================================
// Helper de consentement cookies — Phase 8 RGPD (whitepaper §10).
//
// Cadrage chef (Phase 8 brief) :
//   "Le stack actuel (SSO via Supabase Auth) n'utilise probablement que
//   des cookies essentiels (session). Construire un système de
//   consentement complet pour une catégorie de cookies qui n'existe pas
//   encore serait de la plomberie spéculative. Scope MVP : bannière
//   informative minimale [...] plus un helper lib/cookie-consent.ts
//   avec une fonction hasConsent(category) prête à être branchée le
//   jour où un cookie non-essentiel (analytics, etc.) apparaît
//   réellement."
//
// Ce fichier fournit donc l'API PRÊTE À L'EMPLOI mais pas le storage
// (qui n'aurait rien à stocker cette phase). Le jour où on ajoute un
// vrai cookie non-essentiel :
//   1. Brancher ici la lecture depuis localStorage / un cookie 'kairo_consent'
//   2. Ajouter le toggle correspondant dans la bannière
//   3. hasConsent('analytics') commence à varier selon le choix user
//
// Catégories reconnues (alignées nomenclature CNIL) :
//   - 'essential'  : nécessaires au service (session Supabase Auth). Toujours
//                    true, jamais désactivables.
//   - 'analytics'  : mesure d'usage. Pas utilisé cette phase. hasConsent
//                    retourne false tant qu'aucun cookie de cette catégorie
//                    n'est branché.
//   - 'marketing'  : ciblage publicitaire. Idem, pas utilisé cette phase.
//
// Pourquoi cet export existe dès maintenant :
//   Pour qu'un dev qui ajoute un script analytics (Plausible, Umami, etc.)
//   lise ce helper au lieu d'inline un document.cookie qui ignore tout
//   consentement. Le code qui consomme l'API sera trivial à écrire, et
//   le helper garantira que le consentement est centralisé.
// =============================================================================

/**
 * Catégories de cookies reconnues par l'application.
 * Ajouter une catégorie ici = engagement explicite à la supporter dans
 * la bannière le jour où elle devient réelle.
 */
export type CookieCategory = 'essential' | 'analytics' | 'marketing';

/**
 * Indique si l'utilisateur a consenti à une catégorie de cookies donnée.
 *
 * - 'essential' : toujours true (cookies strictement nécessaires au service,
 *   exemptés de consentement par la CNIL — guideline §3.2).
 * - 'analytics' / 'marketing' : false tant qu'aucun cookie réel n'est
 *   branché pour cette catégorie. Le jour où on ajoute Plausible ou
 *   un pixel Meta, brancher ici la lecture du choix user (localStorage
 *   ou cookie 'kairo_consent').
 *
 * Note d'implémentation : la fonction est pure (pas d'I/O, pas de
 * dépendance navigateur) — elle peut être appelée depuis un Server
 * Component sans risque. Quand on branchera la lecture localStorage,
 * elle deviendra forcément client-only et il faudra ajouter 'use client'
 * ou un guard typeof window !== 'undefined'.
 */
export function hasConsent(category: CookieCategory): boolean {
  switch (category) {
    case 'essential':
      return true;
    case 'analytics':
    case 'marketing':
      // Aucune catégorie non-essentielle n'est utilisée cette phase.
      // Quand on en branchera une, retourner ici le choix user stocké.
      return false;
  }
}

/**
 * Liste les catégories effectivement utilisées par l'application.
 * Utilisé par la bannière pour n'afficher que les toggles utiles
 * (pas de toggle "analytics" si aucun cookie analytics n'existe —
 * sinon on induit l'utilisateur en erreur en lui faisant croire qu'il
 * contrôle quelque chose qui n'existe pas).
 *
 * Cette phase : seule 'essential' est retournée. Quand on branche
 * Plausible/Umami, ajouter 'analytics' ici.
 */
export function activeCategories(): CookieCategory[] {
  return ['essential'];
}
