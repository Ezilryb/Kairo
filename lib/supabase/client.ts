// /lib/supabase/client.ts
// =============================================================================
// Client Supabase pour les composants client (browser).
// Utilisé dans tout composant marqué "use client" qui a besoin d'interagir
// avec Supabase (auth state, requêtes, mutations) depuis le navigateur.
//
// Pattern recommandé par Supabase pour Next.js App Router (avec @supabase/ssr).
// Ne JAMAIS instancier un client global au top-level du module : Next.js
// fait du rendu multiple en dev (HMR, RSC streaming) et un client partagé
// entre requêtes cause des fuites de session entre utilisateurs.
// =============================================================================
import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";

export function createClient(): SupabaseClient {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}
