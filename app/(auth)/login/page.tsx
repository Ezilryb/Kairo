// /app/(auth)/login/page.tsx
// =============================================================================
// Page de login — deux boutons OAuth (Google, Facebook).
// Le redirect après auth est géré par app/auth/callback/route.ts, qui appelle
// exchangeCodeForSession et renvoie vers le dashboard. Le layout de
// (dashboard) y fera ensuite le check du profil public.users et redirigera
// vers /onboarding si l'utilisateur n'a pas encore de pseudo.
//
// Cette page est dans le route group (auth) : pas d'impact sur l'URL, c'est
// juste pour l'organisation.
// =============================================================================
"use client";

import { useState, useTransition } from "react";
import { createClient } from "@/lib/supabase/client";

type Provider = "google" | "facebook";

export default function LoginPage() {
  const [pendingProvider, setPendingProvider] = useState<Provider | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [, startTransition] = useTransition();

  const handleSignIn = (provider: Provider) => {
    setError(null);
    setPendingProvider(provider);
    startTransition(async () => {
      const supabase = createClient();
      const { error: oauthError } = await supabase.auth.signInWithOAuth({
        provider,
        options: {
          // Retour OAuth atterrit ici, on échange le code, on redirige.
          redirectTo: `${window.location.origin}/auth/callback`,
        },
      });
      if (oauthError) {
        setError(oauthError.message);
        setPendingProvider(null);
      }
      // Pas de reset sur succès : on est en pleine redirection OAuth.
    });
  };

  return (
    <main className="flex min-h-screen items-center justify-center bg-neutral-50 px-4">
      <div className="w-full max-w-sm rounded-card border border-neutral-200 bg-card p-8 shadow-card">
        <h1 className="text-2xl font-semibold tracking-tight">Kairo</h1>
        <p className="mt-1 text-sm text-neutral-500">
          Connecte-toi pour accéder à ton journal de trading.
        </p>

        <div className="mt-6 space-y-3">
          <OAuthButton
            provider="google"
            label="Continuer avec Google"
            pending={pendingProvider === "google"}
            disabled={pendingProvider !== null}
            onClick={() => handleSignIn("google")}
          />
          <OAuthButton
            provider="facebook"
            label="Continuer avec Facebook"
            pending={pendingProvider === "facebook"}
            disabled={pendingProvider !== null}
            onClick={() => handleSignIn("facebook")}
          />
        </div>

        {error ? (
          <p
            role="alert"
            className="mt-4 rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-sm text-danger"
          >
            {error}
          </p>
        ) : null}
      </div>
    </main>
  );
}

function OAuthButton({
  provider,
  label,
  pending,
  disabled,
  onClick,
}: {
  provider: Provider;
  label: string;
  pending: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-busy={pending}
      className={[
        "flex w-full items-center justify-center gap-2 rounded-lg border border-neutral-300 bg-white px-4 py-2.5 text-sm font-medium text-neutral-900",
        "transition-colors duration-100",
        "hover:bg-neutral-50 active:bg-neutral-100",
        "disabled:cursor-not-allowed disabled:opacity-70",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-info focus-visible:ring-offset-2",
      ].join(" ")}
    >
      <ProviderIcon provider={provider} />
      <span>{pending ? "Redirection…" : label}</span>
    </button>
  );
}

// SVG inline plutôt que react-icons : évite une dep supplémentaire, et les
// logos Google/Facebook sont des marques qu'on doit rendre fidèlement (pas
// d'icône générique qui prête à confusion). Les SVGs sont les versions
// monochromes officielles, inline pour ne pas charger d'asset externe.
function ProviderIcon({ provider }: { provider: Provider }) {
  if (provider === "google") {
    return (
      <svg
        aria-hidden
        viewBox="0 0 24 24"
        className="h-4 w-4"
      >
        <path
          fill="#4285F4"
          d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
        />
        <path
          fill="#34A853"
          d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.99.66-2.25 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
        />
        <path
          fill="#FBBC05"
          d="M5.84 14.1c-.22-.66-.35-1.36-.35-2.1s.13-1.44.35-2.1V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.83z"
        />
        <path
          fill="#EA4335"
          d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.83C6.71 7.31 9.14 5.38 12 5.38z"
        />
      </svg>
    );
  }
  // Facebook
  return (
    <svg
      aria-hidden
      viewBox="0 0 24 24"
      className="h-4 w-4"
      fill="#1877F2"
    >
      <path d="M24 12.073C24 5.405 18.627 0 12 0S0 5.405 0 12.073C0 18.1 4.388 23.094 10.125 24v-8.437H7.078v-3.49h3.047V9.413c0-3.027 1.792-4.7 4.532-4.7 1.312 0 2.686.235 2.686.235v2.97h-1.514c-1.491 0-1.955.93-1.955 1.886v2.265h3.328l-.532 3.49h-2.796V24C19.612 23.094 24 18.1 24 12.073z" />
    </svg>
  );
}
