// /app/api/cron/mark-forgotten/route.ts
// =============================================================================
// Route CRON : appel quotidien par Vercel Cron pour basculer les trades
// `live` inactifs depuis 5+ jours vers `forgotten` (whitepaper §04).
//
// SÉCURITÉ — 2 couches indépendantes :
//
//   1. Authentification HTTP par header `Authorization: Bearer <CRON_SECRET>`.
//      Vercel Cron envoie automatiquement ce header à chaque appel, configuré
//      via la variable d'env CRON_SECRET côté infra (Settings → Environment
//      Variables). Si le header est absent ou ne matche pas → 401 immédiat,
//      AVANT de toucher à Supabase. La route reste privée même si l'URL est
//      découverte par un attaquant (un scan de chemins, un leak de log, etc.).
//
//   2. Le client service-role (lib/supabase/service) bypasse la RLS par
//      construction, ce qui est nécessaire pour appeler mark_forgotten_trades()
//      — on a retiré EXECUTE à PUBLIC et GRANT uniquement à service_role
//      dans la migration 20260901000003. Sans ce client, l'appel RPC lèverait
//      "permission denied for function mark_forgotten_trades" — la couche 1
//      du GRANT fait son travail.
//
// Sans le 401, n'importe qui connaissant l'URL pourrait déclencher le job
// (impact réel limité, mais on ne veut pas l'ouvrir — cf. cadrage Point D
// du chef). Sans le service client + GRANT service_role, l'appel RPC serait
// rejeté par Postgres. Les 2 couches sont indépendantes et complémentaires.
//
// Idempotence : mark_forgotten_trades() ne touche que les trades live avec
// last_activity_at < now() - 5d. Si Vercel réessaie (retry automatique en
// cas de timeout), le 2e appel retourne 0 (les trades déjà forgotten ne
// matchent plus le WHERE). Pas de double-traitement.
//
// Schedule : configuré dans vercel.json, à ajouter en dernier commit du
// Point D (le chef veut tester la route manuellement d'abord, curl avec
// et sans le bon header, avant de planifier le schedule).
//
// Method : GET (Vercel Cron envoie des GET par défaut).
// =============================================================================
import { NextResponse } from "next/server";
import { createServiceClient } from "@/lib/supabase/service";

// Pas de cache : c'est une action qui doit s'exécuter à chaque appel.
// runtime nodejs : la service_role key ne doit JAMAIS fuiter vers un
// runtime edge (contraintes différentes, surface d'attaque élargie).
// `nodejs` garantit un contexte Node.js classique, server-only strict.
export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: Request) {
  // ---------- 1. Authentification par header ----------
  const authHeader = request.headers.get("authorization");
  const expected = process.env.CRON_SECRET;

  if (!expected) {
    // CRON_SECRET non configuré côté serveur. On refuse TOUT plutôt
    // que de laisser passer sans secret (un crash ici sera visible
    // dans les logs Vercel, on ne fait pas de fail-open silencieux).
    console.error(
      "[cron/mark-forgotten] CRON_SECRET non configuré côté serveur",
    );
    return NextResponse.json(
      { error: "Service indisponible : CRON_SECRET non configuré" },
      { status: 503 },
    );
  }

  if (authHeader !== `Bearer ${expected}`) {
    // Header absent ou mismatch. 401 explicite, on ne distingue pas
    // "header manquant" de "header incorrect" (pas d'info utile pour
    // un éventuel attaquant).
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // ---------- 2. Exécution du job OUBLIÉ ----------
  try {
    const supabase = createServiceClient();
    const { data: count, error } = await supabase.rpc("mark_forgotten_trades");

    if (error) {
      // Erreur RPC. On remonte en 500, Vercel marquera le cron job
      // comme failed et enverra l'alerte mail configurée.
      console.error("[cron/mark-forgotten] RPC error:", error);
      return NextResponse.json(
        { error: "RPC failed", details: error.message },
        { status: 500 },
      );
    }

    return NextResponse.json(
      {
        ok: true,
        // `count` est l'integer retourné par le RPC (nombre de trades
        // basculés). 0 si rien à faire, c'est un run nominal.
        marked_count: count ?? 0,
        ran_at: new Date().toISOString(),
      },
      { status: 200 },
    );
  } catch (err) {
    // Erreur inattendue (variable d'env manquante, crash réseau, etc.).
    // On log côté serveur (visible dans Vercel logs) et on remonte
    // un 500 générique — pas de leak d'info sensible dans la réponse.
    console.error("[cron/mark-forgotten] Unexpected error:", err);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 },
    );
  }
}
