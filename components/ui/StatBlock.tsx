// /components/ui/StatBlock.tsx
// =============================================================================
// StatBlock — bloc de stat data-dense façon Google Finance : label petit en
// gris, gros chiffre en dessous (mono optionnel), delta optionnel coloré
// success/danger avec icône flèche. L'icône principale est optionnelle et
// rendue dans un petit carré tinted à gauche du chiffre.
//
// Pas de ref : composant d'affichage leaf, pas concerné par React 19
// ref-as-prop.
// =============================================================================
import type { ReactNode } from "react";
import { ArrowDown, ArrowUp, Minus } from "lucide-react";

export type StatTone = "neutral" | "success" | "danger";

export interface StatBlockProps {
  /** Petit label gris au-dessus de la valeur. */
  label: string;
  /** Valeur principale (texte brut, formatée par l'appelant). */
  value: string;
  /** Unité affichée à droite de la valeur, en plus petit et plus discret. */
  unit?: string;
  /** Icône Lucide optionnelle rendue à gauche de la valeur. */
  icon?: ReactNode;
  /**
   * Variation signée. undefined = pas de variation affichée. 0 = neutre
   * (flèche horizontale grise). Positif/négatif = flèche + couleur sémantique.
   */
  delta?: number;
  /** Format court du delta (ex: "+2.4%", "-1.1%"). Si fourni, surcharge l'icône+texte par défaut. */
  deltaLabel?: string;
  /** Couleur forcée de la valeur (par défaut, suit le signe du delta). */
  tone?: StatTone;
  /** Formate le chiffre avec une police monospace (alignement vertical des colonnes). */
  mono?: boolean;
}

function getTone(tone: StatTone | undefined, delta: number | undefined): StatTone {
  if (tone) return tone;
  if (delta === undefined) return "neutral";
  if (delta > 0) return "success";
  if (delta < 0) return "danger";
  return "neutral";
}

const toneText: Record<StatTone, string> = {
  neutral: "text-neutral-900",
  success: "text-success",
  danger: "text-danger",
};

export function StatBlock({
  label,
  value,
  unit,
  icon,
  delta,
  deltaLabel,
  tone,
  mono = false,
}: StatBlockProps) {
  const resolvedTone = getTone(tone, delta);
  const valueClass = toneText[resolvedTone];
  const fontClass = mono ? "font-mono tabular-nums" : "";

  return (
    <div className="flex flex-col gap-1">
      <div className="text-xs font-medium uppercase tracking-wide text-neutral-500">
        {label}
      </div>
      <div className={`flex items-baseline gap-2 ${valueClass} ${fontClass}`}>
        {icon ? (
          <span className="inline-flex h-5 w-5 items-center justify-center text-current opacity-80">
            {icon}
          </span>
        ) : null}
        <span className="text-2xl font-semibold leading-none">{value}</span>
        {unit ? (
          <span className="text-sm font-normal text-neutral-500">{unit}</span>
        ) : null}
      </div>
      {delta !== undefined ? (
        <DeltaLine delta={delta} label={deltaLabel} />
      ) : null}
    </div>
  );
}

function DeltaLine({ delta, label }: { delta: number; label?: string }) {
  const isUp = delta > 0;
  const isDown = delta < 0;
  const Icon = isUp ? ArrowUp : isDown ? ArrowDown : Minus;
  const color = isUp
    ? "text-success"
    : isDown
      ? "text-danger"
      : "text-neutral-500";
  return (
    <div className={`flex items-center gap-1 text-xs font-medium ${color}`}>
      <Icon className="h-3 w-3" aria-hidden />
      <span>{label ?? `${isUp ? "+" : ""}${delta.toFixed(2)}%`}</span>
    </div>
  );
}
