// /app/(dashboard)/trades/_components/trade-publish-button.tsx
// =============================================================================
// Bouton "Publier" pour un trade en `draft`.
// Client component utilisé sur la page /trades/[id] quand status = 'draft'.
//
// Action effectuée : UPDATE du trade pour passer en 'live' avec
//   - status = 'live'
//   - published_at = now() (posée par le client ; Supabase ne met pas de
//     default sur update, contrairement à insert)
//   - opened_at = now() (idem)
// Le tout dans le même UPDATE — un seul aller-retour, les triggers
// métier (enforce_capital_immutability notamment) évaluent l'état
// old.status = 'draft' et laissent passer l'augmentation de capital
// éventuelle au moment de la publication (cf. tests 02 #1).
//
// Pourquoi un client component + Supabase direct plutôt qu'une Server
// Action : cohérence avec le pattern TradeForm (Phase 2 Point B) —
// même gestion d'erreur, même `.select()` post-mutation pour détecter
// les blocages RLS silencieux, même UX optimiste. Le `.eq("user_id",
// user.id)` explicite reste la règle défense en profondeur.
//
// Après publication réussie, `router.refresh()` côté serveur : la page
// re-render avec le nouveau statut, le countdown démarre, le composant
// TradeLiveEdit prend le relais.
// =============================================================================
"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/Button";
import { createClient } from "@/lib/supabase/client";

export function TradePublishButton({ tradeId }: { tradeId: string }) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const handlePublish = () => {
    // Confirmation explicite : la publication est un point de non-retour
    // (les 60 secondes de fenêtre scalping démarrent immédiatement).
    // On ne veut pas qu'un clic maladroit publie un brouillon à moitié
    // rempli. Le confirm() natif suffit pour le Point C ; on pourra
    // remplacer par un Dialog plus tard si on veut plus de polish.
    if (
      !confirm(
        "Publier ce trade ?\n\nUne fois publié, l'entrée, le capital et la quantité seront verrouillés 60 secondes après la publication (fenêtre scalping, whitepaper §04).",
      )
    ) {
      return;
    }
    setError(null);
    startTransition(async () => {
      const supabase = createClient();
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();
      if (userError || !user) {
        setError("Session non chargée.");
        return;
      }

      // On pose les timestamps côté client. Décalage potentiel de
      // quelques ms vs now() côté DB (qui sert de référence pour le
      // trigger 60 s) — négligeable, et on évite un round-trip RPC
      // supplémentaire. Si on veut la rigueur ultime, on créera un RPC
      // `publish_trade(trade_id uuid)` qui pose les 3 valeurs en
      // SECURITY DEFINER, mais c'est du scope Point D+.
      const nowIso = new Date().toISOString();
      const { data: updated, error: updateError } = await supabase
        .from("trades")
        .update({
          status: "live",
          published_at: nowIso,
          opened_at: nowIso,
        })
        .eq("id", tradeId)
        .eq("user_id", user.id)
        .select();

      if (updateError) {
        // Message du trigger métier (devrait être rare ici car on passe
        // de draft à live, mais on remonte l'erreur telle quelle par
        // cohérence avec le pattern des autres formulaires).
        setError(updateError.message);
        return;
      }
      if (!updated || updated.length === 0) {
        // RLS a filtré, ou le trade n'existe plus / n'est plus draft.
        setError(
          "Publication refusée (RLS, trade introuvable, ou déjà publié).",
        );
        return;
      }
      // Refresh serveur : la page re-render, le composant détecte le
      // nouveau statut 'live', le countdown démarre. Pas de router.push
      // (on reste sur la même URL, on ne perd pas le contexte).
      router.refresh();
    });
  };

  return (
    <div className="flex flex-col items-end gap-2">
      <Button
        type="button"
        variant="primary"
        onClick={handlePublish}
        disabled={pending}
        aria-busy={pending}
      >
        {pending ? "Publication…" : "Publier le trade"}
      </Button>
      {error ? (
        <p role="alert" className="text-xs text-danger">
          {error}
        </p>
      ) : null}
    </div>
  );
}
