// /app/api/account/export/route.ts
// =============================================================================
// Phase 8 — RGPD & Export/Migration (whitepaper §10 + §11)
// Endpoint GET /api/account/export
// =============================================================================
// Flux complet :
//   1. Auth : getUser() via createClient() (lib/supabase/server, scopé session)
//   2. Récupère le pseudo de l'appelant pour le filename
//   3. Appelle le RPC export_user_data (migration 019, SECURITY DEFINER)
//      — le check p_user_id = auth.uid() interne garantit qu'aucun user
//      ne peut exporter les données d'un autre malgré les droits élevés
//   4. Retourne le JSON en téléchargement (Content-Disposition: attachment)
//      avec filename kairo-export-<pseudo>-<YYYY-MM-DD>.json
//
// IMPORTANT — pas de createServiceClient() ici :
//   Le RPC export_user_data est lui-même SECURITY DEFINER + check self,
//   donc on a pas besoin d'élever les droits côté TS. Utiliser un client
//   scopé session est ce qu'il y a de plus sûr : si le RPC était
//   accidentellement exposé à un user qui n'a pas le droit, c'est le
//   check interne qui lève (et pas une élévation implicite qui masquerait
//   le problème). Le pattern "client scopé session + RPC SECURITY DEFINER
//   qui fait son propre check" est exactement ce qu'on veut — défense en
//   profondeur explicite, pas d'élévation implicite.
//
// Codes de réponse typés :
//   200 application/json (attachment) : succès, body = JSONB de l'export
//   401 NON_AUTHENTICATED             : pas de session
//   500 RPC_ERROR                     : le RPC a planté (rare, on log)
//
// runtime = 'nodejs' : idem Phase 5 mae-mfe, cohérent avec /api/cron et
// autres routes du projet.
// =============================================================================

import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  // -------------------------------------------------------------------------
  // 1. Auth — client SCOPÉ à la session (cf. commentaire en tête)
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
  // 2. Pseudo pour le filename — chargé en parallèle-safe via maybeSingle
  //    (le user a forcément un profil public.users, garanti par le layout
  //    (dashboard)/layout.tsx qui redirige vers /onboarding sinon — donc
  //    on ne devrait jamais avoir profile = null ici en pratique, mais on
  //    reste robuste avec un fallback).
  // -------------------------------------------------------------------------
  const { data: profile } = await supabase
    .from('users')
    .select('pseudo')
    .eq('id', user.id)
    .maybeSingle();

  const pseudo = profile?.pseudo ?? 'user';
  const dateStr = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  const filename = `kairo-export-${pseudo}-${dateStr}.json`;

  // -------------------------------------------------------------------------
  // 3. Appel RPC export_user_data — client scopé session suffit
  // -------------------------------------------------------------------------
  // Le RPC est SECURITY DEFINER avec check p_user_id = auth.uid() en
  // première instruction : si un futur appelant oublie de passer son
  // propre id (ou passe celui d'un autre), le RPC raise immédiatement.
  // On propage l'erreur au client telle quelle — la première partie du
  // message ("export_user_data: p_user_id ...") est lisible et permet
  // au dev de comprendre ce qui s'est passé sans devoir aller voir les
  // logs serveur.
  const { data: exportData, error: rpcError } = await supabase.rpc(
    'export_user_data',
    { p_user_id: user.id }
  );

  if (rpcError) {
    console.error('[account/export] export_user_data error:', rpcError);
    return NextResponse.json(
      { error: rpcError.message, code: 'RPC_ERROR' },
      { status: 500 }
    );
  }

  // -------------------------------------------------------------------------
  // 4. Réponse en téléchargement (attachment) — JSON sérialisé
  // -------------------------------------------------------------------------
  // On sérialise le JSONB côté TS plutôt que de renvoyer l'objet brut
  // pour 2 raisons :
  //   - jsonb Supabase contient des types numériques (numeric → string)
  //     qu'on veut préserver tels quels pour que l'utilisateur puisse
  //     ré-importer sans perte de précision
  //   - JSON.stringify avec indentation 2 → fichier lisible par un humain
  //     qui ouvre son export dans un éditeur de texte, utile pour la
  //     transparence RGPD
  const body = JSON.stringify(exportData, null, 2);

  return new NextResponse(body, {
    status: 200,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Disposition': `attachment; filename="${filename}"`,
      // Pas de cache : l'export est personnel et peut changer à chaque
      // action de l'utilisateur (nouveau trade, etc.).
      'Cache-Control': 'no-store',
    },
  });
}
