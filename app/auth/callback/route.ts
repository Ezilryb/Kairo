// /app/auth/callback/route.ts
// =============================================================================
// Callback OAuth — point de retour après signInWithOAuth().
// Échange le `code` contre une session Supabase, puis redirige vers /.
// Le layout de (dashboard) fera ensuite le check du profil et redirigera
// vers /onboarding si nécessaire.
//
// Note : on est en runtime Node (Edge plus supporté pour proxy/middleware
// en Next 16, mais les route handlers restent en Node par défaut).
// =============================================================================
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  // redirectTo vient du query string — entièrement contrôlable par quiconque
  // forge un lien. On ne l'accepte que si c'est un chemin relatif
  // same-origin, jamais une URL absolue ni protocol-relative (//host/path).
  const next = safeRedirectPath(searchParams.get("redirectTo"));

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
    // Si l'échange a échoué, on tombe sur la redirection /login ci-dessous
    // avec le message d'erreur en query string pour affichage éventuel.
    const params = new URLSearchParams({ error: error.message });
    return NextResponse.redirect(`${origin}/login?${params.toString()}`);
  }

  // Pas de code : cas anormal (accès direct à /auth/callback). On renvoie
  // vers /login plutôt qu'afficher une page d'erreur.
  return NextResponse.redirect(`${origin}/login`);
}

/**
 * N'accepte qu'un chemin relatif same-origin. Rejette :
 *   - valeur absente
 *   - URL absolue (http://, https://, javascript:, data:, etc.)
 *   - chemin protocol-relative (//host/path) — serait interprétée comme
 *     une URL externe par le navigateur
 * Le défaut est "/" pour garantir qu'on ne redirige jamais hors du site.
 */
function safeRedirectPath(value: string | null): string {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return "/";
  return value;
}
