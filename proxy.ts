// /proxy.ts
// =============================================================================
// Proxy Next.js (ex-middleware avant Next 16) — rafraîchit la session Supabase
// à chaque requête et applique des redirects rapides pour les routes
// authentifiées.
//
// IMPORTANT — défense en profondeur (cf. CVE-2025-29927) :
// Le middleware n'est PAS la seule ligne de défense. Si une mise à jour de
// Next.js ou un bug de configuration faisait que le middleware ne s'exécute
// pas, l'accès aux routes protégées ne doit pas être compromis. C'est
// pourquoi la vérification de session est aussi faite dans le layout de
// (dashboard)/layout.tsx (point 4 de Phase 1) : un `redirect()` vers /login
// si pas de session, exécuté côté serveur, garantit l'autorisation même
// sans middleware. Le middleware ici est une optimisation UX (redirect
// instantané sans rendu de page), pas un mur de protection.
// =============================================================================
import { createServerClient } from "@supabase/ssr";
import { type NextRequest, NextResponse } from "next/server";

// Routes explicitement publiques. Tout le reste est considéré authentifié
// par défaut — c'est l'inverse de la logique intuitive "liste des protégées",
// mais c'est crucial ici : les route groups comme (dashboard) ne produisent
// pas de segment d'URL, donc matcher sur "/dashboard" ne protège pas les
// pages du route group. Une liste blanche des publiques garantit qu'un
// oubli de déclaration rend une page privée par erreur (gênant, vite
// repéré) plutôt que publique par erreur (silencieux, potentiellement grave).
const PUBLIC_PATHS = ["/login", "/auth/callback", "/preview"];

function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some(
    (p) => pathname === p || pathname.startsWith(p + "/"),
  );
}

export async function proxy(request: NextRequest) {
  // On crée une réponse mutable qu'on pourra renvoyer à la fin, avec
  // éventuellement les nouveaux cookies (refresh du JWT) posés dessus.
  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        // En middleware, on lit/écrit les cookies via l'objet Request/Response
        // directement (next/headers n'est PAS dispo ici).
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          for (const { name, value } of cookiesToSet) {
            request.cookies.set(name, value);
          }
          supabaseResponse = NextResponse.next({ request });
          for (const { name, value, options } of cookiesToSet) {
            supabaseResponse.cookies.set(name, value, options);
          }
        },
      },
    },
  );

  // IMPORTANT : getUser(), PAS getSession(). getSession() lit juste le JWT
  // local — non fiable pour l'autorisation. getUser() envoie une requête au
  // serveur Auth Supabase pour valider le token, ce qui rafraîchit aussi
  // la session si elle est expirée.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Redirect rapide : pas de session sur une route non publique → /login.
  // (Vraie protection : dans (dashboard)/layout.tsx — voir commentaire en tête.)
  if (!user && !isPublicPath(request.nextUrl.pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("redirectTo", request.nextUrl.pathname);
    return NextResponse.redirect(url);
  }

  // Si déjà connecté et qu'on visite /login, on évite d'afficher le
  // formulaire pour rien et on renvoie vers le dashboard.
  if (user && request.nextUrl.pathname === "/login") {
    const url = request.nextUrl.clone();
    url.pathname = "/";
    return NextResponse.redirect(url);
  }

  return supabaseResponse;
}

// Matcher : on applique le middleware à toutes les routes SAUF :
//   - /api/* : pas besoin de refresh session côté API (géré par le client
//              serveur directement dans les route handlers)
//   - /_next/*, /favicon.ico, fichiers avec extension : assets statiques
//   - /preview : la page de design system reste publique (revue visuelle
//                sans avoir à se connecter — c'est un outil de design
//                review, pas une page métier)
export const config = {
  matcher: [
    "/((?!api|_next/static|_next/image|favicon.ico|preview|.*\\..*).*)",
  ],
};
