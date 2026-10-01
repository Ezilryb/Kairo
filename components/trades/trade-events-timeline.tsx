// /components/trades/trade-events-timeline.tsx
// =============================================================================
// Phase 9 — Finitions UI/UX (Proof of Performance, whitepaper notes finales)
// Composant "Proof of Performance" — timeline immuable des trade_events.
//
// Cadrage chef (Phase 9 brief, point 1) :
//   "Rejoue trade_events triés par created_at croissant, avec pour chaque
//   ligne le type d'event, l'horodatage DB, et old_values/new_values en
//   résumé lisible (pas le JSON brut). Ajoute un indicateur d'intégrité
//   simple : si le trade n'a aucun entry_modified/sl_modified/tp_modified
//   hors de la fenêtre 60s, affiche 'Aucune modification hors fenêtre
//   autorisée'."
//
// Le point de vente narratif : chaque timestamp est généré par Postgres
// (`now()` côté DB), jamais par le navigateur — c'est ce qui rend la
// preuve crédible. On ne fait que SURFAÇER cette garantie déjà présente
// dans les triggers Phase 0 (log_sl_tp_changes, enforce_entry_price_immutability,
// enforce_sl_tp_immutability) — pas de nouvelle migration SQL, pas de
// nouvelle colonne, lecture pure de la table trade_events.
//
// Pourquoi un client component :
//   - Fetch dynamique côté navigateur pour éviter de charger tous les
//     events d'un trade dans le render server (séparation des concerns,
//     cohérent avec mae-mfe-button.tsx)
//   - Loading/empty/error states granulaires au niveau du composant
//   - Pas d'état partagé avec le parent
//
// Garantie d'impartialité :
//   trade_events est immuable par construction (trigger forbid_trade_events_mutation
//   de la migration 0001). Le composant ne peut pas afficher de données
//   modifiées — il SURFACE ce qui a été historisé par les triggers
//   d'origine (création, publication, modifs SL/TP, partial_exit,
//   transition). C'est exactement ce qu'on veut pour la preuve.
// =============================================================================
"use client";

import { useEffect, useState, useTransition } from "react";
import { Card } from "@/components/ui/Card";
import { Badge, type BadgeTone } from "@/components/ui/Badge";
import { createClient } from "@/lib/supabase/client";

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

// Les 11 valeurs de public.trade_event_type (cf. migration 0001, §02).
// Garder ce type en sync avec l'enum PostgreSQL — si on en ajoute un côté
// SQL, il faut l'ajouter ici + dans EVENT_LABELS. Le compilateur TS ne
// pourra pas attraper l'oubli côté SQL, mais l'audit visuel du composant
// rendu rattrapera le cas (label absent → "Type inconnu").
type TradeEventType =
  | "created"
  | "published"
  | "entry_modified"
  | "sl_modified"
  | "tp_modified"
  | "info_modified"
  | "partial_exit"
  | "marked_forgotten"
  | "reactivated"
  | "closed"
  | "archived";

interface TradeEventRow {
  id: string;
  trade_id: string;
  event_type: TradeEventType;
  old_values: Record<string, unknown> | null;
  new_values: Record<string, unknown> | null;
  created_at: string; // ISO 8601 depuis timestamptz Postgres
}

// trade_events est lié à un trade par trade_id. On charge juste la fenêtre
// publiée (published_at + 60s suffisent pour la vérif d'intégrité côté
// client ; la cohérence DB reste garantie par les triggers).
interface TradeRow {
  id: string;
  published_at: string | null;
}

// -----------------------------------------------------------------------------
// Libellés et tons
// -----------------------------------------------------------------------------

const EVENT_LABELS: Record<TradeEventType, string> = {
  created: "Trade créé",
  published: "Trade publié",
  entry_modified: "Prix d'entrée modifié",
  sl_modified: "Stop Loss modifié",
  tp_modified: "Take Profit modifié",
  info_modified: "Notes / psycho modifiés",
  partial_exit: "Sortie partielle",
  marked_forgotten: "Marqué oublié",
  reactivated: "Réactivé",
  closed: "Trade clôturé",
  archived: "Trade archivé",
};

// Couleur du dot timeline par type d'event. On n'utilise QUE les tokens
// sémantiques (pas de Tailwind utilities directes sur les dots), pour
// rester aligné sur le design system établi.
const EVENT_TONES: Record<TradeEventType, BadgeTone> = {
  created: "neutral",
  published: "info",
  entry_modified: "warning",
  sl_modified: "warning",
  tp_modified: "warning",
  info_modified: "neutral",
  partial_exit: "info",
  marked_forgotten: "warning",
  reactivated: "info",
  closed: "success",
  archived: "neutral",
};

// Couleur du dot sur la timeline verticale (cercle de 8px à gauche de
// chaque ligne). On garde un mapping séparé des badges pour pouvoir
// donner un signal visuel plus saturé sur le dot que sur le badge
// (le dot doit "peser" sur la timeline, le badge doit rester léger).
// Phase 9 round 4 : utilise les tokens `warning` au lieu des utilitaires
// Tailwind `amber-*` bruts, conformément à l'alignement design system.
const EVENT_DOT_CLASSES: Record<TradeEventType, string> = {
  created: "bg-neutral-400 ring-neutral-200",
  published: "bg-info ring-info-border",
  entry_modified: "bg-warning ring-warning-border",
  sl_modified: "bg-warning ring-warning-border",
  tp_modified: "bg-warning ring-warning-border",
  info_modified: "bg-neutral-400 ring-neutral-200",
  partial_exit: "bg-info ring-info-border",
  marked_forgotten: "bg-warning ring-warning-border",
  reactivated: "bg-info ring-info-border",
  closed: "bg-success ring-success-border",
  archived: "bg-neutral-400 ring-neutral-200",
};

// -----------------------------------------------------------------------------
// Helpers de rendu
// -----------------------------------------------------------------------------

/**
 * Formate un timestamp ISO 8601 en chaîne française lisible.
 * On utilise un format explicite plutôt que toLocaleString() pour que le
 * rendu soit stable d'un navigateur à l'autre (les locales "fr-FR" entre
 * Node, Chrome et Safari varient légèrement).
 *
 * Format : "15 sept. 2026 · 14:32:07"
 */
function formatTimestamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const months = [
    "janv.", "févr.", "mars", "avr.", "mai", "juin",
    "juil.", "août", "sept.", "oct.", "nov.", "déc.",
  ];
  const day = d.getDate();
  const month = months[d.getMonth()];
  const year = d.getFullYear();
  const pad = (n: number) => String(n).padStart(2, "0");
  const hh = pad(d.getHours());
  const mm = pad(d.getMinutes());
  const ss = pad(d.getSeconds());
  return `${day} ${month} ${year} · ${hh}:${mm}:${ss}`;
}

/**
 * Formate une valeur numérique pour l'affichage. Les valeurs viennent de
 * JSONB (donc déjà sérialisées en string par Supabase pour les numeric).
 * On tente un Number() pour les formater avec toLocaleString, fallback
 * sur la string brute pour les autres types (text, bool).
 */
function formatValue(v: unknown): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "number" && Number.isFinite(v)) {
    return v.toLocaleString("fr-FR", { maximumFractionDigits: 4 });
  }
  if (typeof v === "string") {
    const n = Number(v);
    if (Number.isFinite(n) && v.trim() !== "") {
      return n.toLocaleString("fr-FR", { maximumFractionDigits: 4 });
    }
    return v;
  }
  if (typeof v === "boolean") return v ? "oui" : "non";
  return JSON.stringify(v);
}

/**
 * Traduit un objet JSONB old_values/new_values en une chaîne lisible
 * "clé : ancien → nouveau". Si une seule des deux valeurs est présente,
 * affiche seulement l'existante.
 *
 * Exemples :
 *   { stop_loss: 42000 } → { stop_loss: 41500 }
 *     → "Stop Loss : 42 000 → 41 500"
 *   { entry_price: 100 } → null
 *     → "Prix d'entrée : 100 → —"
 */
function describeDiff(
  eventType: TradeEventType,
  oldValues: Record<string, unknown> | null,
  newValues: Record<string, unknown> | null,
): string | null {
  if (!oldValues && !newValues) return null;

  // Mapping type d'event → label de champ lisible. Pour les events qui
  // touchent plusieurs champs (info_modified), on laisse les clés JSONB
  // parler d'elles-mêmes avec un capitalize().
  const FIELD_LABELS: Record<string, string> = {
    entry_price: "Prix d'entrée",
    stop_loss: "Stop Loss",
    take_profit: "Take Profit",
    quantity: "Quantité",
    fees: "Frais",
    slippage: "Slippage",
    notes: "Notes",
    emotion: "Émotion",
    stress: "Stress",
    confidence: "Confiance",
    plan_followed: "Plan suivi",
    mistake_type: "Type d'erreur",
    status: "Statut",
  };

  const keys = new Set<string>([
    ...Object.keys(oldValues ?? {}),
    ...Object.keys(newValues ?? {}),
  ]);
  const lines: string[] = [];
  for (const key of Array.from(keys).sort()) {
    const oldV = oldValues?.[key];
    const newV = newValues?.[key];
    const label = FIELD_LABELS[key] ?? key.charAt(0).toUpperCase() + key.slice(1);
    const oldStr = formatValue(oldV ?? null);
    const newStr = formatValue(newV ?? null);
    if (oldV === undefined || oldV === null) {
      lines.push(`${label} : ${newStr}`);
    } else if (newV === undefined || newV === null) {
      lines.push(`${label} : ${oldStr} → —`);
    } else {
      lines.push(`${label} : ${oldStr} → ${newStr}`);
    }
  }
  return lines.length > 0 ? lines.join(" · ") : null;
}

// -----------------------------------------------------------------------------
// Composant principal
// -----------------------------------------------------------------------------

const WINDOW_MS = 60 * 1000; // 60 s — fenêtre scalping whitepaper §04

export interface TradeEventsTimelineProps {
  tradeId: string;
}

export function TradeEventsTimeline({ tradeId }: TradeEventsTimelineProps) {
  const [events, setEvents] = useState<TradeEventRow[] | null>(null);
  const [publishedAt, setPublishedAt] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  useEffect(() => {
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

      // published_at du trade — uniquement la colonne nécessaire pour
      // calculer la fenêtre 60 s côté client (vérif d'intégrité).
      // Pattern lecture séparée (pas de jointure) pour les mêmes raisons
      // que /trades/[id]/page.tsx (cf. TODO_TECHNIQUE leçon Phase 5).
      //
      // OWNER-ONLY CETTE PHASE (Phase 9 round 2, suite audit composant) :
      // on filtre explicitement par user_id = auth.uid() côté client.
      // Raison : la policy RLS trade_events a été alignée Phase 7 par
      // la migration 020, MAIS le composant peut être réutilisé dans
      // d'autres contextes (chart/replay, futur feed) où le fetch
      // direct client pourrait extraire des events d'un trade public
      // d'un autre user (fuite d'old_values/new_values : quantity,
      // fees, notes, etc.). Le filtrage explicite garantit que le
      // composant est owner-only quel que soit son contexte de montage.
      // Quand un PoP public sera cadré (dette Phase 9 TODO_TECHNIQUE),
      // ce filtre devra sauter ET être remplacé par un masquage SQL des
      // champs sensibles (cf. migration 020 commentaire).
      const { data: trade, error: tradeError } = await supabase
        .from("trades")
        .select("id, published_at, user_id")
        .eq("id", tradeId)
        .eq("user_id", user.id)
        .maybeSingle();
      if (tradeError) {
        setError(tradeError.message);
        return;
      }
      if (!trade) {
        // Pas le proprio, ou trade inexistant. On renvoie un message
        // générique plutôt que distinguer les deux cas (pas de leak
        // d'info business sur l'existence de trades d'autres users).
        setError("Trade introuvable ou non autorisé.");
        return;
      }
      setPublishedAt((trade as TradeRow).published_at ?? null);

      // trade_events : lecture de l'historique immutable.
      // MÊME FILTRE OWNER-ONLY que ci-dessus : double sécurité.
      // .order('created_at', { ascending: true }) = ordre chronologique,
      // exactement ce qu'on veut pour la timeline.
      const { data: eventsData, error: eventsError } = await supabase
        .from("trade_events")
        .select("id, trade_id, event_type, old_values, new_values, created_at")
        .eq("trade_id", tradeId)
        .eq("user_id", user.id)
        .order("created_at", { ascending: true });
      if (eventsError) {
        setError(eventsError.message);
        return;
      }
      setEvents((eventsData as TradeEventRow[]) ?? []);
    });
  }, [tradeId]);

  // ----- Loading ----------------------------------------------------------
  if (pending && events === null) {
    return (
      <Card>
        <div
          role="status"
          aria-live="polite"
          className="flex items-center gap-2 text-sm text-neutral-500"
        >
          <span
            aria-hidden
            className="inline-block h-2 w-2 animate-pulse rounded-full bg-neutral-300"
          />
          Chargement de l&apos;historique immuable…
        </div>
      </Card>
    );
  }

  // ----- Error ------------------------------------------------------------
  if (error) {
    return (
      <Card>
        <div
          role="alert"
          className="rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-sm text-danger"
        >
          {error}
        </div>
      </Card>
    );
  }

  // ----- Empty ------------------------------------------------------------
  // Un trade SANS event : ce cas ne devrait pas exister en pratique (le
  // trigger AFTER INSERT sur trades crée un event 'created' automatiquement,
  // migration 0001). Mais on reste robuste.
  if (events && events.length === 0) {
    return (
      <Card>
        <h2 className="text-sm font-semibold">Preuve de performance</h2>
        <p className="mt-2 text-xs text-neutral-500">
          Aucun événement enregistré pour ce trade. (Cas anormal — un trade
          devrait avoir au minimum un événement &laquo;&nbsp;créé&nbsp;&raquo;.)
        </p>
      </Card>
    );
  }

  // ----- Vérification d'intégrité ----------------------------------------
  // On cherche les modifications post-publication (entry/sl/tp_modified)
  // dont le timestamp serait > published_at + 60s. Si on en trouve, on
  // affiche une alerte. Sinon, on affiche la confirmation positive.
  //
  // IMPORTANT — cette vérif est pédagogique, pas un nouveau garde-fou :
  // les triggers enforce_entry_price_immutability et
  // enforce_sl_tp_immutability (migration 002) BLOQUENT déjà côté DB
  // toute modification hors fenêtre. Si la vérif client remontait un
  // problème, ça indiquerait soit un bug des triggers, soit une
  // manipulation directe de la base. C'est un détecteur, pas un
  // mécanisme de sécurité.
  const pmsEvents = ["entry_modified", "sl_modified", "tp_modified"] as const;
  const windowEnd =
    publishedAt ? new Date(publishedAt).getTime() + WINDOW_MS : null;
  const outOfWindow = (events ?? []).filter((e) => {
    if (!pmsEvents.includes(e.event_type as (typeof pmsEvents)[number])) return false;
    if (windowEnd === null) return false;
    return new Date(e.created_at).getTime() > windowEnd;
  });
  const integrityOk = outOfWindow.length === 0 && publishedAt !== null;

  // ----- Render -----------------------------------------------------------
  return (
    <Card>
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-sm font-semibold">Preuve de performance</h2>
          <p className="mt-1 text-xs text-neutral-500">
            Historique immuable des événements du trade. Chaque timestamp
            est généré par Postgres — aucun élément de cette timeline
            n&apos;a été posé par ton navigateur.
          </p>
        </div>
        {integrityOk ? (
          <Badge tone="success" size="sm">
            ✓ Intégrité vérifiée
          </Badge>
        ) : publishedAt === null ? (
          <Badge tone="neutral" size="sm">
            Brouillon non publié
          </Badge>
        ) : (
          <Badge tone="danger" size="sm">
            ⚠ Anomalie détectée
          </Badge>
        )}
      </div>

      {/* Indicateur d'intégrité détaillé */}
      {integrityOk ? (
        <p className="mt-3 text-xs text-neutral-600">
          Aucune modification hors de la fenêtre autorisée (60 s après
          publication).
        </p>
      ) : outOfWindow.length > 0 ? (
        <p
          role="alert"
          className="mt-3 rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-xs text-danger"
        >
          ⚠ {outOfWindow.length} modification(s) détectée(s) hors fenêtre
          autorisée. La cohérence de l&apos;historique peut être compromise.
          Contacte le support si ce cas se présente.
        </p>
      ) : (
        <p className="mt-3 text-xs text-neutral-500">
          Trade non encore publié — la fenêtre de 60 s n&apos;a pas
          commencé.
        </p>
      )}

      {/* Timeline */}
      <ol
        className="relative mt-6 space-y-4 border-l border-neutral-200 pl-6"
        aria-label="Historique immuable du trade"
      >
        {(events ?? []).map((event) => {
          const dotClass = EVENT_DOT_CLASSES[event.event_type];
          const tone = EVENT_TONES[event.event_type];
          const label =
            EVENT_LABELS[event.event_type] ?? `Type inconnu (${event.event_type})`;
          const diff = describeDiff(event.event_type, event.old_values, event.new_values);
          return (
            <li key={event.id} className="relative">
              {/* Dot de la timeline : ring coloré pour halo, bg pour le centre */}
              <span
                aria-hidden
                className={`absolute -left-[31px] top-1.5 inline-block h-3 w-3 rounded-full ring-4 ${dotClass}`}
              />
              <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                <Badge tone={tone} size="sm">
                  {label}
                </Badge>
                <time
                  dateTime={event.created_at}
                  className="font-mono text-xs tabular-nums text-neutral-500"
                  title={event.created_at}
                >
                  {formatTimestamp(event.created_at)}
                </time>
              </div>
              {diff ? (
                <p className="mt-1 text-sm text-neutral-700">{diff}</p>
              ) : null}
            </li>
          );
        })}
      </ol>
    </Card>
  );
}
