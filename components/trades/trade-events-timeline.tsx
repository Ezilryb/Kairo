// /components/trades/trade-events-timeline.tsx
// =============================================================================
// Phase 9 — Finitions UI/UX (Proof of Performance, whitepaper notes finales)
// Composant "Proof of Performance" — timeline immuable des trade_events.
//
// Cadrage (Phase 9 brief, point 1) :
//   "Rejoue trade_events triés par created_at croissant, avec pour chaque
//   ligne le type d'event, l'horodatage DB, et old_values/new_values en
//   résumé lisible (pas le JSON brut). Ajoute un indicateur d'intégrité
//   simple : si le trade n'a aucun entry_modified/sl_modified/tp_modified
//   hors de la fenêtre 60s, affiche 'Aucune modification hors fenêtre
//   autorisée'."
//
// Pourquoi un client component :
//   - Fetch dynamique côté navigateur pour éviter de charger tous les
//     events d'un trade dans le render server.
//   - Loading/empty/error states granulaires au niveau du composant.
//   - Pas d'état partagé avec le parent.
//
// Garantie d'impartialité :
//   trade_events est immuable par construction (trigger forbid_trade_events_mutation
//   de la migration 0001). Le composant ne peut pas afficher de données
//   modifiées — il SURFACE ce qui a été historisé par les triggers.
//
// Phase 10 (migration 023) :
//   - Ajout colonne is_backfilled + metadata sur trade_events.
//   - Référence de la fenêtre 60s = timestamp de l'event 'published',
//     PAS trades.published_at (falsifiable par un UPDATE direct).
//   - Détection publication directe (metadata.direct_insert_live=true).
//   - Détection publication non tracée (status <> 'draft' mais aucun event
//     'published' présent — état anormal post-023). Couvre tous les
//     statuts non-draft (live, closed, forgotten, archived), pas
//     seulement 'live' : un trade clôturé sans event 'published' est
//     aussi un état anormal.
//   - Tri déterministe : created_at, puis event_type. PostgREST trie les
//     enums par ordre de DÉCLARATION (cf. migration 0001, 'created' est
//     déclaré avant 'published').
//   - Lecture parallèle events + status via Promise.all pour éviter le
//     clignotement du badge "Brouillon non publié" le temps de la
//     seconde requête (séquentiel avant).
//   - Erreur de lecture status séparée : un échec RLS / réseau sur la
//     lecture de status ne fait plus passer le composant en état
//     "Brouillon non publié" — il affiche "Statut indéterminé".
//
// Note audit : le trigger `enforce_sl_tp_immutability` n'existe PAS
// en prod. Le seul trigger SL/TP est `log_sl_tp_changes` qui
// HISTORISE sans verrouiller. La vérif 60s de ce composant porte donc
// uniquement sur entry_price (post-60s par enforce_entry_price_immutability).
// Pour les autres champs (SL/TP, quantity, capital, direction,
// instrument_id) : aucun verrou en base aujourd'hui (cf. plan 10.0).
// =============================================================================
"use client";

import { useEffect, useState, useTransition } from "react";
import { Card } from "@/components/ui/Card";
import { Badge, type BadgeTone } from "@/components/ui/Badge";
import { createClient } from "@/lib/supabase/client";

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

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
  is_backfilled: boolean;
  metadata: Record<string, unknown> | null;
  created_at: string;
}

type TradeStatusResult = "draft" | "live" | "closed" | "forgotten" | "archived" | null;

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

function describeDiff(
  eventType: TradeEventType,
  oldValues: Record<string, unknown> | null,
  newValues: Record<string, unknown> | null,
): string | null {
  if (!oldValues && !newValues) return null;

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

const WINDOW_MS = 60 * 1000;

export interface TradeEventsTimelineProps {
  tradeId: string;
}

export function TradeEventsTimeline({ tradeId }: TradeEventsTimelineProps) {
  const [events, setEvents] = useState<TradeEventRow[] | null>(null);
  const [tradeStatus, setTradeStatus] = useState<TradeStatusResult>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  useEffect(() => {
    setError(null);
    setStatusError(null);
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

      // Lecture parallèle : events + status. Avant c'était séquentiel et
      // le badge "Brouillon non publié" clignotait le temps que la
      // 2e requête revienne. Avec Promise.all, les 2 lectures sont en
      // vol simultanément, on calcule le bon état dès la résolution.
      const [eventsResult, statusResult] = await Promise.all([
        supabase
          .from("trade_events")
          .select("id, trade_id, event_type, old_values, new_values, is_backfilled, metadata, created_at")
          .eq("trade_id", tradeId)
          .eq("user_id", user.id)
          .order("created_at", { ascending: true })
          .order("event_type", { ascending: true }),
        supabase
          .from("trades")
          .select("status")
          .eq("id", tradeId)
          .eq("user_id", user.id)
          .maybeSingle(),
      ]);

      if (eventsResult.error) {
        setError(eventsResult.error.message);
        return;
      }
      setEvents((eventsResult.data as TradeEventRow[]) ?? []);

      // Status : on distingue 3 cas.
      //   - OK et trade trouvé : tradeStatus = le statut retourné.
      //   - OK et trade non trouvé : tradeStatus = null (trade inexistant
      //     ou RLS bloque). isStatusUnknown reste false — c'est juste
      //     un trade absent.
      //   - Erreur RLS / réseau : tradeStatus = null ET statusError
      //     non null → le composant affiche "Statut indéterminé"
      //     plutôt que de retomber silencieusement sur "Brouillon".
      if (statusResult.error) {
        setStatusError(statusResult.error.message);
      }
      setTradeStatus((statusResult.data?.status as TradeStatusResult) ?? null);
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

  // ----- Logique du badge -----------------------------------------------
  // Hiérarchie par ordre de priorité décroissante :
  //   1. Anomalie détectée (danger) — au moins une modif SL/TP/entry
  //      hors fenêtre 60s post-publication
  //   2. Publication directe (warning) — event 'published' avec
  //      metadata.direct_insert_live=true
  //   3. Historique reconstitué (warning) — au moins un event is_backfilled,
  //      pas d'anomalie, pas de publication directe
  //   4. Intégrité vérifiée (success) — pas d'anomalie, pas de
  //      publication directe, aucun event backfillé, event 'published' présent
  //   5. Publication non tracée (warning) — status <> 'draft' mais aucun
  //      event 'published' (anormal post-023). On couvre tous les statuts
  //      non-draft (live, closed, forgotten, archived), pas seulement
  //      'live' : un trade clôturé sans event 'published' est aussi
  //      un état anormal (migration 023 non appliquée / backfill raté).
  //   6. Statut indéterminé (warning) — la lecture de status a échoué
  //      (RLS, réseau, etc.). On n'invente pas "Brouillon".
  //   7. Brouillon non publié (neutral) — status = 'draft' (lu OK),
  //      pas encore d'event 'published'.

  const publishedEvent = (events ?? []).find((e) => e.event_type === "published");
  const publishedTimestamp = publishedEvent?.created_at ?? null;
  const windowEnd = publishedTimestamp
    ? new Date(publishedTimestamp).getTime() + WINDOW_MS
    : null;
  const pmsEvents = ["entry_modified", "sl_modified", "tp_modified"] as const;
  const outOfWindow = (events ?? []).filter((e) => {
    if (!pmsEvents.includes(e.event_type as (typeof pmsEvents)[number])) return false;
    if (windowEnd === null) return false;
    return new Date(e.created_at).getTime() > windowEnd;
  });

  const hasAnomaly = outOfWindow.length > 0;
  const hasBackfilled = (events ?? []).some((e) => e.is_backfilled);
  const isDirectInsertLive =
    publishedEvent?.metadata != null &&
    (publishedEvent.metadata as Record<string, unknown>).direct_insert_live === true;
  const isPublished = publishedTimestamp !== null;
  const isStatusNonDraft = tradeStatus !== null && tradeStatus !== "draft";
  const isPublicationUntracked = isStatusNonDraft && !isPublished;
  const isStatusUnknown = statusError !== null;

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
        {hasAnomaly ? (
          <Badge tone="danger" size="sm">
            ⚠ Anomalie détectée
          </Badge>
        ) : isDirectInsertLive ? (
          <Badge tone="warning" size="sm">
            ⓘ Publication directe
          </Badge>
        ) : hasBackfilled ? (
          <Badge tone="warning" size="sm">
            ⓘ Historique reconstitué
          </Badge>
        ) : isPublished ? (
          <Badge tone="success" size="sm">
            ✓ Intégrité vérifiée
          </Badge>
        ) : isPublicationUntracked ? (
          <Badge tone="warning" size="sm">
            ⓘ Publication non tracée
          </Badge>
        ) : isStatusUnknown ? (
          <Badge tone="warning" size="sm">
            ⓘ Statut indéterminé
          </Badge>
        ) : (
          <Badge tone="neutral" size="sm">
            Brouillon non publié
          </Badge>
        )}
      </div>

      {hasAnomaly ? (
        <p
          role="alert"
          className="mt-3 rounded-md border border-danger-border bg-danger-subtle px-3 py-2 text-xs text-danger"
        >
          ⚠ {outOfWindow.length} modification(s) détectée(s) hors fenêtre
          autorisée. La cohérence de l&apos;historique peut être compromise.
        </p>
      ) : isDirectInsertLive ? (
        <p className="mt-3 text-xs text-neutral-600">
          Ce trade a été inséré directement avec <code>status = &apos;live&apos;</code>
          (sans passer par <code>publish_trade</code>). L&apos;event
          <code> published</code> a été posé au moment de l&apos;INSERT, mais la
          fenêtre de 60 s ne s&apos;applique pas (pas de transition
          draft → live). Traité comme publication non contrôlée.
        </p>
      ) : hasBackfilled ? (
        <p className="mt-3 text-xs text-neutral-600">
          L&apos;historique a été reconstitué à partir de <code>trades.created_at</code> et
          <code> trades.published_at</code> (migration de rattrapage). Les events
          antérieurs à cette migration ne sont pas garantis exhaustifs.
        </p>
      ) : isPublished ? (
        <p className="mt-3 text-xs text-neutral-600">
          Aucune modification hors de la fenêtre autorisée (60 s après
          publication).
        </p>
      ) : isPublicationUntracked ? (
        <p className="mt-3 text-xs text-neutral-600">
          Le trade a un statut non-draft (status &lt;&gt; &apos;draft&apos;) en base, mais aucun
          événement <code>published</code> n&apos;a été historisé. État anormal
          post-migration 023 — à investiguer (trigger désactivé,
          manipulation directe, etc.).
        </p>
      ) : isStatusUnknown ? (
        <p className="mt-3 text-xs text-neutral-600">
          Lecture du statut du trade impossible : {statusError}
          {". "}L&apos;historique reste affiché mais on ne peut pas déterminer
          s&apos;il est normal.
        </p>
      ) : (
        <p className="mt-3 text-xs text-neutral-500">
          Trade non encore publié — la fenêtre de 60 s n&apos;a pas
          commencé.
        </p>
      )}

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
                {event.is_backfilled ? (
                  <span className="rounded-full bg-warning-subtle px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning">
                    reconstitué
                  </span>
                ) : null}
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