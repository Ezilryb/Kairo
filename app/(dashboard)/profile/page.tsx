// /app/(dashboard)/profile/page.tsx
// =============================================================================
// Page de profil — affichage du pseudo + toggle de visibilité (public/privé).
// Le toggle update is_public sur public.users via la policy RLS existante
// ("users: modification de son propre profil"), donc rien à toucher côté DB.
//
// Pourquoi un composant client séparé (profile-form.tsx) : le toggle a
// besoin d'état local interactif, ce qui impose "use client". Un server
// component async ne peut pas contenir de hooks. Le pattern server-fetch +
// client-interactive est le standard App Router ici.
// =============================================================================
import { Card } from "@/components/ui/Card";
import { createClient } from "@/lib/supabase/server";
import { ProfileForm } from "./profile-form";

export default async function ProfilePage() {
  const supabase = await createClient();

  // getUser() plutôt que getSession() : on valide le token côté Supabase.
  // Le layout de (dashboard) garantit déjà qu'on a un user ici (sinon
  // redirect /login) ; c'est juste un filet de robustesse.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  // Lecture initiale du profil applicatif. Si absent, le layout aurait
  // déjà redirigé vers /onboarding, mais on garde un fallback silencieux.
  const { data: profile } = await supabase
    .from("users")
    .select("pseudo, is_public, avatar_url")
    .eq("id", user.id)
    .maybeSingle();
  if (!profile) return null;

  return (
    <main className="min-h-screen bg-neutral-50">
      <div className="mx-auto max-w-3xl space-y-6 px-6 py-8">
        <header>
          <h1 className="text-2xl font-semibold tracking-tight">Profil</h1>
          <p className="mt-1 text-sm text-neutral-500">
            Gère ta visibilité et tes informations publiques.
          </p>
        </header>

        <Card>
          <div className="flex items-start gap-4">
            {profile.avatar_url ? (
              <img
                src={profile.avatar_url}
                alt=""
                className="h-12 w-12 flex-shrink-0 rounded-full object-cover"
              />
            ) : (
              <div
                aria-hidden
                className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-full bg-neutral-100 text-neutral-500"
              >
                <span className="text-lg font-semibold">
                  {profile.pseudo.charAt(0).toUpperCase()}
                </span>
              </div>
            )}
            <div className="min-w-0 flex-1">
              <h2 className="truncate text-lg font-semibold">
                {profile.pseudo}
              </h2>
              {/*
                Email vient de auth.getUser() (table auth.users), PAS de
                public.users — public.users n'a pas de colonne email. Si on
                lit profile.email par erreur, ce serait undefined (TypeScript
                le remonterait). Le commentaire ici est défensif.
              */}
              <p className="truncate text-sm text-neutral-500">
                {user.email}
              </p>
            </div>
          </div>
        </Card>

        <Card>
          <h2 className="text-sm font-semibold">Visibilité du profil</h2>
          <p className="mt-1 text-xs text-neutral-500">
            Public : ton profil et tes trades sont visibles par tous les
            utilisateurs de Kairo. Privé : seuls toi et tes followers voient
            tes trades détaillés.
          </p>
          <ProfileForm initialIsPublic={profile.is_public} />
        </Card>

        <footer className="pb-2 pt-4 text-center text-xs text-neutral-400">
          Kairo · Phase 1 · profil
        </footer>
      </div>
    </main>
  );
}
