// /app/(dashboard)/layout.tsx
// =============================================================================
// Layout racine pour toutes les pages du route group (dashboard).
// C'est ici qu'on applique la défense en profondeur (cf. commentaire en
// tête de /proxy.ts) : vérification de session + vérification de profil,
// avec redirect côté serveur. Si le proxy est contourné ou bugué, ces
// vérifs garantissent que rien de privé n'est servi à un utilisateur
// non authentifié ou sans profil.
// =============================================================================
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createClient();

  // getUser(), pas getSession() : on valide le token côté Supabase Auth.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    // Pas de session → /login. Le param next permet au callback de
    // revenir ici après auth, mais en réalité on atterrit souvent via
    // /auth/callback → / qui re-passe par ce layout, donc next est
    // surtout utile pour les redirects manuels depuis des pages.
    redirect("/login?redirectTo=/");
  }

  // Session valide, on vérifie que l'utilisateur a un profil applicatif.
  // public.users.id est FK sur auth.users.id, donc s'il existe une ligne
  // pour cet id, c'est que l'onboarding a été complété.
  const { data: profile, error: profileError } = await supabase
    .from("users")
    .select("id")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError) {
    // Erreur RLS ou DB : on ne continue pas. Mieux vaut rediriger que de
    // servir une page incohérente.
    redirect("/login?error=profile_check_failed");
  }

  if (!profile) {
    // Session OK, mais pas de profil → onboarding. C'est ici qu'on applique
    // la règle métier "un compte auth.users sans ligne public.users doit
    // compléter l'onboarding avant d'accéder au dashboard".
    redirect("/onboarding");
  }

  return <>{children}</>;
}
