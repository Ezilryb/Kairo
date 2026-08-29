// /app/onboarding/page.tsx
// =============================================================================
// Onboarding applicatif — premier écran post-OAuth pour configurer le pseudo.
// Pas de trigger auto sur auth.users : on laisse l'utilisateur choisir son
// pseudo (3-30 chars, alphanum + tirets + underscores) pour respecter la
// séparation pseudo / identité réelle du whitepaper §01.
//
// Le layout de (dashboard) redirige ici quand un utilisateur authentifié
// n'a pas encore de profil public.users.
//
// Validation : client (regex) + serveur (contraintes DB). Si la validation
// client passe mais l'insert échoue (contrainte unique sur pseudo, par
// ex.), on récupère le code Postgres 23505 et on affiche un message
// explicite.
// =============================================================================
"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

const PSEUDO_MIN = 3;
const PSEUDO_MAX = 30;
const PSEUDO_RE = /^[a-zA-Z0-9_-]+$/;

export default function OnboardingPage() {
  const router = useRouter();
  const [pseudo, setPseudo] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [userId, setUserId] = useState<string | null>(null);
  const [isPending, startTransition] = useTransition();

  // On a besoin de l'id utilisateur pour l'insert. Le proxy garantit qu'on
  // est authentifié à ce stade, mais l'auth.getUser() côté client confirme
  // et donne l'id. Si pas d'utilisateur (cas anormal), on redirige vers /login.
  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getUser().then(({ data }) => {
      if (data.user) {
        setUserId(data.user.id);
      } else {
        router.replace("/login");
      }
    });
  }, [router]);

  const validationError = validatePseudo(pseudo);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (validationError) {
      setError(validationError);
      return;
    }
    if (!userId) {
      setError("Session non chargée, réessaie dans un instant.");
      return;
    }
    setError(null);
    startTransition(async () => {
      const supabase = createClient();
      const { error: insertError } = await supabase
        .from("users")
        .insert({ id: userId, pseudo });
      if (insertError) {
        // Code Postgres 23505 = unique_violation. Notre contrainte
        // users_pseudo_key est ce qui se déclenche si quelqu'un a déjà
        // pris ce pseudo.
        if (insertError.code === "23505") {
          setError("Ce pseudo est déjà pris. Choisis-en un autre.");
        } else {
          setError(insertError.message);
        }
        return;
      }
      // Profil créé → dashboard. refresh() force le re-render des layouts
      // server-side, qui re-vérifieront l'existence du profil.
      router.replace("/");
      router.refresh();
    });
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-neutral-50 px-4">
      <div className="w-full max-w-md rounded-card border border-neutral-200 bg-card p-8 shadow-card">
        <h1 className="text-2xl font-semibold tracking-tight">
          Choisis ton pseudo
        </h1>
        <p className="mt-1 text-sm text-neutral-500">
          Visible par les autres utilisateurs sur Kairo. Tu pourras le changer
          plus tard dans les paramètres de profil.
        </p>

        <form onSubmit={handleSubmit} className="mt-6 space-y-4">
          <div>
            <label
              htmlFor="pseudo"
              className="block text-sm font-medium text-neutral-700"
            >
              Pseudo
            </label>
            <input
              id="pseudo"
              type="text"
              required
              autoFocus
              autoComplete="off"
              spellCheck={false}
              minLength={PSEUDO_MIN}
              maxLength={PSEUDO_MAX}
              value={pseudo}
              onChange={(e) => setPseudo(e.target.value)}
              disabled={isPending}
              aria-invalid={validationError !== null}
              aria-describedby={error ? "pseudo-error" : "pseudo-help"}
              className={[
                "mt-1 block w-full rounded-lg border bg-white px-3 py-2 text-sm text-neutral-900",
                "transition-colors duration-100",
                "focus:outline-none focus:ring-2 focus:ring-offset-1",
                validationError
                  ? "border-danger-border focus:border-danger focus:ring-danger"
                  : "border-neutral-300 focus:border-info focus:ring-info",
                "disabled:cursor-not-allowed disabled:opacity-70",
              ].join(" ")}
            />
            {error ? (
              <p
                id="pseudo-error"
                role="alert"
                className="mt-2 text-sm text-danger"
              >
                {error}
              </p>
            ) : (
              <p id="pseudo-help" className="mt-2 text-xs text-neutral-500">
                {PSEUDO_MIN} à {PSEUDO_MAX} caractères. Lettres, chiffres,
                tirets et underscores uniquement.
              </p>
            )}
          </div>

          <button
            type="submit"
            disabled={isPending || validationError !== null || !userId}
            aria-busy={isPending}
            className={[
              "w-full rounded-lg bg-info px-4 py-2 text-sm font-medium text-info-fg",
              "transition-colors duration-100",
              "hover:bg-blue-700 active:bg-blue-800",
              "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-info focus-visible:ring-offset-2",
              "disabled:cursor-not-allowed disabled:opacity-70",
            ].join(" ")}
          >
            {isPending ? "Création…" : "Valider"}
          </button>
        </form>
      </div>
    </main>
  );
}

function validatePseudo(pseudo: string): string | null {
  if (pseudo.length === 0) return null; // pas d'erreur tant que vide
  if (pseudo.length < PSEUDO_MIN) {
    return `Le pseudo doit faire au moins ${PSEUDO_MIN} caractères.`;
  }
  if (pseudo.length > PSEUDO_MAX) {
    return `Le pseudo doit faire au plus ${PSEUDO_MAX} caractères.`;
  }
  if (!PSEUDO_RE.test(pseudo)) {
    return "Lettres, chiffres, tirets et underscores uniquement.";
  }
  return null;
}
