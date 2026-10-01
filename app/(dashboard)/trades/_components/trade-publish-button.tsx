// /app/(dashboard)/trades/_components/trade-publish-button.tsx
// =============================================================================
// Bouton "Publier" pour un trade en `draft`.
// Client component utilisé sur la page /trades/[id] quand status = 'draft'.
//
// Action effectuée : appel du RPC `public.publish_trade(p_trade_id uuid)`
// (cf. migration 20260901000002_publish_trade_rpc.sql) qui pose côté
// base les 3 valeurs en un seul UPDATE :
//   - status = 'live'
//   - published_at = now()  ← côté DB, pas client
//   - opened_at = now()      ← idem
//
// Pourquoi un RPC plutôt qu'un `.update()` direct : si l'horloge du
// navigateur de l'utilisateur est mal réglée (VM, dérive NTP, mauvais
// fuseau), `new Date().toISOString()` peut être décalée de plusieurs
// minutes par rapport à `now()` côté DB. Et ce `published_at` est la
// référence de TOUTE la logique 60 s qu'on vient de construire sur
// deux migrations (enforce_entry_price_immutability,
// enforce_sl_tp_immutability). Si published_at est artificiellement
// daté dans le passé par rapport à l'horloge DB, la fenêtre peut être
// considérée comme expirée au moment même de la publication, et
// l'utilisateur ne voit jamais ses 60 secondes — bug qu'on ne verrait
// qu'en prod. Le RPC pose now() côté base, l'horloge du navigateur
// n'intervient plus.
//
// Le RPC est SECURITY INVOKER (pas SECURITY DEFINER) : pas besoin de
// contourner la RLS, juste que now() soit évalué dans la base. La
// policy RLS UPDATE ("auth.uid() = user_id") s'applique via les
// droits de l'appelant.
//
// Effet de bord utile : si le trade est déjà live (ou n'existe pas,
// ou n'appartient pas au user), le WHERE du RPC ne matche rien et
// lève une exception explicite. Ça bloque aussi la "republication"
// d'un trade déjà live pour reset la fenêtre 60 s.
//
// Phase 9 round 5 (bug fix) :
//   - `useTransition` retiré. Sa promesse est fire-and-forget par
//     construction : `handlePublish()` se résolvait avant que le RPC
//     ne finisse, donc `await onConfirm()` dans ConfirmDialog fermait
//     le dialog immédiatement. Le RPC est maintenant appelé directement
//     dans la fonction async.
//   - `throw` sur erreur (en plus de `setError`). Sans throw, le
//     mécanisme "le dialog reste ouvert si onConfirm throw" de
//     ConfirmDialog ne se déclenchait jamais — l'erreur n'apparaissait
//     qu'en petit texte sous le bouton après fermeture.
//   - Phase 9 round 4 (F1) : confirmation via ConfirmDialog (Card + saisie
//     explicite), remplace le `confirm()` natif.
// =============================================================================
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/Button";
import { ConfirmDialog } from "@/components/ui/ConfirmDialog";
import { createClient } from "@/lib/supabase/client";

export function TradePublishButton({ tradeId }: { tradeId: string }) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);

  const handlePublish = async () => {
    setError(null);
    const supabase = createClient();
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();
    if (userError || !user) {
      const msg = "Session non chargée.";
      setError(msg);
      throw new Error(msg);
    }

    // RPC SECURITY INVOKER : now() est évalué côté base, pas par le
    // client. Le user_id dans le WHERE du RPC utilise auth.uid(), donc
    // on n'a pas besoin de `.eq("user_id", user.id)` ici — c'est le
    // RPC qui filtre. Voir le commentaire en tête de la migration
    // 20260901000002_publish_trade_rpc.sql pour le détail.
    //
    // `rpc` sur une fonction qui retourne `public.trades` (un objet
    // unique) renvoie l'objet directement, pas un tableau. Donc on
    // vérifie `!updated` plutôt que `updated.length === 0`.
    const { data: updated, error: updateError } = await supabase.rpc(
      "publish_trade",
      { p_trade_id: tradeId },
    );

    if (updateError) {
      // Messages possibles (tous en français, déjà lisibles) :
      //   - "Trade introuvable, déjà publié, ou non autorisé" (RPC)
      //   - Exception d'un trigger métier (peu probable ici car on
      //     passe de draft à live, mais on remonte tel quel)
      setError(updateError.message);
      throw new Error(updateError.message);
    }
    if (!updated) {
      // Filet de sécurité : rpc n'a pas renvoyé d'erreur mais n'a
      // pas non plus retourné la ligne. Ne devrait pas arriver (le
      // RPC lève une exception dans ce cas), mais on reste explicite.
      const msg = "Publication refusée (réponse vide du serveur).";
      setError(msg);
      throw new Error(msg);
    }
    // Refresh serveur : la page re-render, le composant détecte le
    // nouveau statut 'live', le countdown démarre. Pas de router.push
    // (on reste sur la même URL, on ne perd pas le contexte).
    router.refresh();
  };

  return (
    <div className="flex flex-col items-end gap-2">
      <Button
        type="button"
        variant="primary"
        onClick={() => setConfirming(true)}
      >
        Publier le trade
      </Button>
      {error && !confirming ? (
        <p role="alert" className="text-xs text-danger">
          {error}
        </p>
      ) : null}
      <ConfirmDialog
        open={confirming}
        onOpenChange={(open) => {
          setConfirming(open);
          if (!open) setError(null);
        }}
        title="Publier ce trade ?"
        description="Une fois publié, l'entrée, le capital et la quantité seront verrouillés 60 secondes après la publication (fenêtre scalping, whitepaper §04)."
        confirmLabel="Publier"
        confirmVariant="primary"
        onConfirm={handlePublish}
        errorMessage={error}
      />
    </div>
  );
}
