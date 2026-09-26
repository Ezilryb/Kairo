// /app/api/account/delete/route.ts
// =============================================================================
// Phase 8 — RGPD & Export/Migration (whitepaper §10 + §11)
// Endpoint POST /api/account/delete
// =============================================================================
// Flux complet :
//   1. Auth : getUser() via createClient() (lib/supabase/server, scopé session)
//   2. AUCUN paramètre de cible accepté — on supprime TOUJOURS l'appelant
//      lui-même (rien à usurper structurellement : pas de body {user_id})
//   3. createServiceClient() pour obtenir un client avec la service_role key
//   4. auth.admin.deleteUser(user.id) — déclenche le trigger BEFORE DELETE
//      sur auth.users (migration 0001) prepare_user_deletion_cascade qui :
//        - INSERT dans audit_logs (action = 'user.gdpr_deleted')
//        - set_config 'app.allow_trade_events_mutation' = 'true' LOCAL
//          → lève la garde forbid_trade_events_mutation pendant la cascade
//          (trade_events est immuable en fonctionnement normal, sauf
//          pendant ce DELETE — pattern documenté migration 0001)
//   5. Le DELETE cascade naturellement : auth.users → public.users →
//      trades → trade_events / trade_comments / likes / followers / reports
//   6. Retourne 204 No Content
//
// IMPORTANT — pourquoi createServiceClient() et pas createClient() :
//   auth.admin.deleteUser() n'est PAS accessible avec le JWT utilisateur
//   (anon key + session cookie). C'est une opération serveur-only qui
//   nécessite la service_role key. C'est exactement le cas légitime
//   documenté en tête de /lib/supabase/service.ts : route API dans
//   app/api/.../route.ts, exécutée côté Vercel functions, jamais servie
//   au navigateur directement.
//
// IMPORTANT — pourquoi pas de paramètre user cible :
//   Le brief chef Phase 8 le formule explicitement : "Plus simple qu'un
//   check d'ownership explicite (Phase 5, mae-mfe) : ici il n'y a
//   structurellement rien à usurper." Un user ne peut supprimer que
//   son propre compte — pas de body {user_id} dans la requête, pas de
//   path param à valider. Le seul check est que l'appelant est
//   authentifié (étape 1). Si on ajoutait {user_id}, ce serait un risque
//   (un user A pourrait DELETE le compte d'un user B) ; on s'en passe.
//
// IMPORTANT — confirmation UX :
//   Le composant client qui appelle cette route DOIT demander à
//   l'utilisateur de saisir son pseudo (mécanique confirmée dans le
//   brief chef Phase 8). Cette route ne le fait pas côté serveur — la
//   friction est purement UX et doit rester au niveau de la UI pour
//   qu'un bot qui scannerait l'endpoint directement ne puisse pas
//   supprimer un compte aussi facilement qu'un user réel.
//
// Codes de réponse typés :
//   204 No Content                          : suppression réussie
//   401 NON_AUTHENTICATED                   : pas de session
//   500 DELETE_ERROR                        : auth.admin.deleteUser a planté
//   500 ENV_MISSING                         : SUPABASE_SERVICE_ROLE_KEY absente
//
// runtime = 'nodejs' : auth.admin.deleteUser() n'est pas disponible en
// edge runtime (utilise GoTrue côté serveur Node).
// =============================================================================

import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { createServiceClient } from '@/lib/supabase/service';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST() {
  // -------------------------------------------------------------------------
  // 1. Auth — client SCOPÉ à la session
  // -------------------------------------------------------------------------
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.json(
      { error: 'Non authentifié', code: 'NON_AUTHENTICATED' },
      { status: 401 }
    );
  }

  // -------------------------------------------------------------------------
  // 2. (Aucun paramètre de cible — voir commentaire en tête)
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // 3. Client service_role — try/catch sur createServiceClient() car il
  //    throw si SUPABASE_SERVICE_ROLE_KEY est absente (fail loud plutôt
  //    que fallback silencieux, cf. /lib/supabase/service.ts).
  // -------------------------------------------------------------------------
  let adminClient;
  try {
    adminClient = createServiceClient();
  } catch (err) {
    console.error('[account/delete] createServiceClient error:', err);
    return NextResponse.json(
      {
        error: 'Configuration serveur incomplète (service role key manquante).',
        code: 'ENV_MISSING',
      },
      { status: 500 }
    );
  }

  // -------------------------------------------------------------------------
  // 4. auth.admin.deleteUser — déclenche la cascade
  // -------------------------------------------------------------------------
  // Le trigger BEFORE DELETE sur auth.users (prepare_user_deletion_cascade,
  // migration 0001) se charge de :
  //   - écrire l'audit_log 'user.gdpr_deleted'
  //   - poser le flag GUC 'app.allow_trade_events_mutation' = 'true' LOCAL
  //     pour que la cascade sur trade_events passe la garde
  //     forbid_trade_events_mutation
  // On n'a rien d'autre à faire côté TS — la cascade auth.users →
  // public.users → trades → ... est gérée par les FK ON DELETE CASCADE
  // déclarées en migration 0001 / migrations ultérieures.
  const { error: deleteError } = await adminClient.auth.admin.deleteUser(
    user.id
  );

  if (deleteError) {
    console.error('[account/delete] auth.admin.deleteUser error:', deleteError);
    return NextResponse.json(
      { error: deleteError.message, code: 'DELETE_ERROR' },
      { status: 500 }
    );
  }

  // -------------------------------------------------------------------------
  // 5. Réponse 204 — on ne renvoie pas de body (rien à dire côté UI ; la
  //    redirection vers /login sera faite par le composant appelant).
  // -------------------------------------------------------------------------
  return new NextResponse(null, { status: 204 });
}
