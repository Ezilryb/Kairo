// /app/(dashboard)/profile/profile-form.tsx
// =============================================================================
// Toggle de visibilité du profil (public / privé).
// Client component isolé (cf. commentaire dans page.tsx).
//
// L'update passe par la policy RLS "users: modification de son propre profil"
// déjà en place — pas de trigger custom côté DB, le user met à jour sa
// propre ligne via le client Supabase authentifié.
// =============================================================================
"use client";

import { useState, useTransition } from "react";
import { createClient } from "@/lib/supabase/client";

export function ProfileForm({
  initialIsPublic,
}: {
  initialIsPublic: boolean;
}) {
  const [isPublic, setIsPublic] = useState(initialIsPublic);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const handleToggle = () => {
    const next = !isPublic;
    setError(null);

    // Update optimiste : on bascule l'UI immédiatement, et on rollback
    // en cas d'échec du write. Plus réactif qu'attendre le round-trip,
    // et l'erreur reste explicite en cas de problème.
    setIsPublic(next);

    startTransition(async () => {
      const supabase = createClient();
      const { data: { user }, error: userError } = await supabase.auth.getUser();
      if (userError || !user) {
        // Session absente avant même de tenter l'update — l'utilisateur a
        // été déconnecté entre le mount du composant et le clic.
        setError("Session non chargée.");
        setIsPublic(!next); // rollback optimiste
        return;
      }

      // .select() force le retour de la ligne affectée. Sans ça, Supabase
      // renvoie null par défaut (Prefer: return=minimal) même quand 0
      // lignes ont été modifiées — une policy UPDATE qui filtre silencieu-
      // sement via RLS ne lève pas d'erreur, l'utilisateur croirait son
      // toggle effectif alors qu'il ne l'est pas. Avec .select(), data est
      // [] (array vide) si RLS bloque, jamais null : on peut distinguer
      // succès de blocage silencieux.
      const { data, error: updateError } = await supabase
        .from("users")
        .update({ is_public: next })
        .eq("id", user.id)
        .select();

      if (updateError) {
        setError(updateError.message);
        setIsPublic(!next); // rollback optimiste
        return;
      }

      if (!data || data.length === 0) {
        // RLS a filtré, ou la ligne n'existe plus (compte supprimé en
        // parallèle). C'est exactement le cas que .select() nous permet
        // de détecter et que l'update seul masquerait.
        setError("Mise à jour refusée (RLS ou ligne absente).");
        setIsPublic(!next); // rollback optimiste
      }
    });
  };

  return (
    <div className="mt-4">
      <div className="flex items-center justify-between gap-4">
        <div>
          <p className="text-sm font-medium">
            {isPublic ? "Profil public" : "Profil privé"}
          </p>
          <p className="text-xs text-neutral-500">
            {isPublic
              ? "Visible par tous les utilisateurs de Kairo."
              : "Seuls toi et tes followers verront tes trades détaillés."}
          </p>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={isPublic}
          aria-label="Visibilité du profil"
          disabled={pending}
          onClick={handleToggle}
          className={[
            "relative inline-flex h-6 w-11 flex-shrink-0 items-center rounded-full",
            "transition-colors duration-200",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-info focus-visible:ring-offset-2",
            "disabled:cursor-not-allowed disabled:opacity-70",
            isPublic ? "bg-success" : "bg-neutral-300",
          ].join(" ")}
        >
          <span
            aria-hidden
            className={[
              "pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow",
              "transition-transform duration-200",
              isPublic ? "translate-x-6" : "translate-x-1",
            ].join(" ")}
          />
        </button>
      </div>
      {error ? (
        <p
          role="alert"
          className="mt-2 text-xs text-danger"
        >
          {error}
        </p>
      ) : null}
    </div>
  );
}
