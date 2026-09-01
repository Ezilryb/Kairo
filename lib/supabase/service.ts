// /lib/supabase/service.ts
// =============================================================================
// Client Supabase SERVICE_ROLE pour jobs système (Vercel Cron, scripts
// d'admin, migrations de données).
//
// ⚠ DANGER — NE JAMAIS importer ce fichier depuis un client component ou
// une route destinée à être servie au navigateur. ⚠
//
// La SUPABASE_SERVICE_ROLE_KEY bypasse TOUTES les policies RLS de la base :
// un import accidentel dans un composant React client et on a une faille
// de sécurité critique (lecture + écriture + suppression sur toutes les
// tables, tous les users). C'est l'équivalent d'un accès root PostgreSQL
// exposé publiquement.
//
// Utilisation légitime, server-only :
//   - Routes API dans app/api/.../route.ts (exécutées côté Vercel
//     functions, jamais servies au navigateur directement)
//   - Server Actions (mais préférer le client server.ts si une session
//     utilisateur est disponible, pour conserver le RLS)
//   - Scripts Node.js d'admin/migrations
//
// Vérifier TOUJOURS l'origine de l'appel avant d'invoquer ce client :
// header secret (cf. app/api/cron/mark-forgotten/route.ts), IP
// whitelist, etc. La service_role key ne dispense pas d'authentifier
// l'appelant — elle dispense juste la policy RLS de la base.
//
// Pourquoi pas de cookies : on est en contexte serveur sans session
// utilisateur (job système). Le client service-role n'en a pas besoin,
// il agit au nom du "rôle système" (service_role PostgreSQL).
//
// Pas de autoRefreshToken / persistSession : chaque appel est une
// transaction isolée, pas de session longue à maintenir côté serveur.
//
// Variable d'env : SUPABASE_SERVICE_ROLE_KEY. À configurer dans Vercel
// (Settings → Environment Variables, scope Production au minimum), JAMAIS
// committée — même règle que toutes les clés secrètes du projet.
// =============================================================================
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";

export function createServiceClient(): SupabaseClient {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceKey) {
    // Fail loud, pas de fallback silencieux qui ouvrirait une faille.
    // Côté Vercel, ce throw remonte en 500 dans la route API qui
    // catch et log — l'alerte Vercel Cron se déclenche.
    throw new Error(
      "Variables d'environnement Supabase manquantes (NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY). Vérifier la config Vercel.",
    );
  }

  return createSupabaseClient(url, serviceKey, {
    auth: {
      // Contexte server-only sans session utilisateur persistante.
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}
