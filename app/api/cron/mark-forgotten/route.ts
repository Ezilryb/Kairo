// /app/api/cron/mark-forgotten/route.ts
// =============================================================================
// Route CRON : appel quotidien par Vercel Cron pour basculer les trades
// `live` inactifs depuis 5+ jours vers `forgotten` (whitepaper §04).
//
// VARIABLES D'ENVIRONNEMENT REQUISES (à configurer dans Vercel → Settings
// → Environment Variables, scope Production minimum) :
//
//   1. CRON_SECRET              : secret partagé entre Vercel Cron (qui
//                                 l'envoie en header `Authorization: Bearer
//                                 <CRON_SECRET>`) et cette route. Si absent
//                                 côté serveur → 503 immédiat (fail loud,
//                                 pas de fail-open silencieux).
//
//   2. SUPABASE_SERVICE_ROLE_KEY : clé service_role Supabase. Lue par
//                                 `createServiceClient()` (cf.
//                                 /lib/supabase/service.ts). Si absente
//                                 → 500 immédiat.
//
//   3. NEXT_PUBLIC_SUPABASE_URL : URL du projet Supabase. Lue par
//                                 `createServiceClient()`. Si absente
//                                 → 500 immédiat (en même temps que
//                                 SUPABASE_SERVICE_ROLE_KEY).
//
// La présence de CRON_SECRET, SUPABASE_SERVICE_ROLE_KEY et
// NEXT_PUBLIC_SUPABASE_URL côté Vercel doit être confirmée avant
// déploiement.
//
// SÉCURITÉ — 2 couches indépendantes :
//
//   1. Authentification HTTP par header `Authorization: Bearer <CRON_SECRET>`.
//      Vercel Cron envoie automatiquement ce header à chaque appel. Si
//      le header est absent ou ne matche pas → 401 immédiat, AVANT de
//      toucher à Supabase. La route reste privée même si l'URL est
//      découverte par un attaquant (un scan de chemins, un leak de log).
//
//   2. Le client service-role (lib/supabase/service) bypasse la RLS par
//      construction, ce qui est nécessaire pour appeler mark_forgotten_trades()
//      — on a retiré EXECUTE à PUBLIC/anon/authenticated et GRANT
//      uniquement à service_role dans la migration 20260903000024. Sans
//      ce client, l'appel RPC lèverait "permission denied for function
//      mark_forgotten_trades" — la couche 1 du GRANT fait son travail.
//
// Sans le 401, n'importe qui connaissant l'URL pourrait déclencher le job
// (impact réel limité, mais on ne veut pas l'ouvrir). Sans le service
// client + GRANT service_role, l'appel RPC serait rejeté par Postgres.
// Les 2 couches sont indépendantes et complémentaires.
//
// Une réponse non-2xx marque l'exécution du cron en échec.
//
// Idempotence : mark_forgotten_trades() ne touche que les trades live avec
// last_activity_at < now() - 5d. Si Vercel réessaie (retry automatique en
// cas de timeout), le 2e appel retourne 0 (les trades déjà forgotten ne
// matchent plus le WHERE). Pas de double-traitement.
//
// Method : GET (Vercel Cron envoie des GET par défaut).
// =============================================================================
import { NextResponse } from "next/server";
import { createServiceClient } from "@/lib/supabase/service";
import { createHash, timingSafeEqual } from "node:crypto";

// Pas de cache : c'est une action qui doit s'exécuter à chaque appel.
// runtime nodejs : la service_role key ne doit JAMAIS fuiter vers un
// runtime edge (contraintes différentes, surface d'attaque élargie).
// `nodejs` garantit un contexte Node.js classique, server-only strict.
export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// Comparaison du secret en temps constant : SHA-256 des deux entrées
// pour avoir deux Buffers de même taille, puis timingSafeEqual.
// Le hachage rend la longueur des entrées inobservable côté timing
// (les deux condensés font toujours 32 octets, que le secret fasse
// 8 ou 80 caractères), et préserve la résistance aux attaques par
// timing sur le contenu.
function safeStringEqual(a: string, b: string): boolean {
  const aHash = createHash("sha256").update(a, "utf8").digest();
  const bHash = createHash("sha256").update(b, "utf8").digest();
  return timingSafeEqual(aHash, bHash);
}

export async function GET(request: Request) {
  // ---------- 1. Authentification par header ----------
  const authHeader = request.headers.get("authorization");
  const expected = process.env.CRON_SECRET;

  if (!expected) {
    console.error(
      "[cron/mark-forgotten] CRON_SECRET non configuré côté serveur",
    );
    return NextResponse.json(
      { error: "Service indisponible : CRON_SECRET non configuré" },
      { status: 503 },
    );
  }

  // Format attendu : "Bearer <secret>". On extrait le token et on
  // compare en temps constant. La longueur du secret étant fixe
  // (cf. safeStringEqual), le court-circuit n'est pas un canal
  // d'attaque exploitable.
  const providedToken = authHeader?.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (!safeStringEqual(providedToken, expected)) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // ---------- 2. Exécution du job OUBLIÉ ----------
  try {
    const supabase = createServiceClient();
    const { data: count, error } = await supabase.rpc("mark_forgotten_trades");

    if (error) {
      console.error("[cron/mark-forgotten] RPC error:", error);
      return NextResponse.json(
        { error: "RPC failed", details: error.message },
        { status: 500 },
      );
    }

    // Garde-fou : le RPC est censé retourner un integer (nombre de
    // trades basculés). Si `count` n'est pas un nombre, c'est un
    // échec silencieux : le client Supabase n'a pas remonté
    // d'erreur, mais le job n'a pas fait ce qu'on attend. On
    // remonte en 5xx pour ne pas envoyer un 200 "tout va bien".
    if (typeof count !== "number") {
      console.error(
        "[cron/mark-forgotten] RPC a retourné un résultat invalide :",
        count,
      );
      return NextResponse.json(
        { error: "RPC returned invalid result", details: String(count) },
        { status: 500 },
      );
    }

    return NextResponse.json(
      {
        ok: true,
        marked_count: count,
        ran_at: new Date().toISOString(),
      },
      { status: 200 },
    );
  } catch (err) {
    console.error("[cron/mark-forgotten] Unexpected error:", err);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 },
    );
  }
}