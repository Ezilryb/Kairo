// /lib/supabase/server.ts
// =============================================================================
// Client Supabase pour le code serveur (RSC, route handlers, server actions).
// Lit et écrit les cookies de session via next/headers.
//
// Note Next 16 : `cookies()` est async depuis Next 15 — on doit l'attendre.
// Le try/catch dans setAll gère le cas où la fonction est appelée depuis
// un Server Component (où set() lève) : dans ce cas, c'est le middleware
// qui rafraîchit la session à la prochaine requête, pas grave.
// =============================================================================
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { SupabaseClient } from "@supabase/supabase-js";

export async function createClient(): Promise<SupabaseClient> {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Appel depuis un Server Component : set() n'est pas autorisé
            // hors d'une Server Action ou d'un Route Handler. Le middleware
            // rafraîchira la session à la prochaine requête — ignorer.
          }
        },
      },
    },
  );
}
