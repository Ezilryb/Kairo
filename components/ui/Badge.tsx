// /components/ui/Badge.tsx
// =============================================================================
// Badge — pastille compacte pour les statuts de trade (draft/live/forgotten/
// closed/archived) et les variations PnL (positif/négatif). Deux intensités :
// "subtle" (fond teinté + texte coloré) pour les usages denses, "solid"
// (fond plein) pour mettre en avant.
//
// Pas de ref : composant leaf, pas concerné par React 19 ref-as-prop.
// =============================================================================
import type { HTMLAttributes, ReactNode } from "react";

export type BadgeTone =
  | "neutral"
  | "success"
  | "danger"
  | "info"
  | "warning";
export type BadgeIntensity = "subtle" | "solid";
export type BadgeSize = "sm" | "md";

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: BadgeTone;
  intensity?: BadgeIntensity;
  size?: BadgeSize;
  children: ReactNode;
}

const toneSubtle: Record<BadgeTone, string> = {
  neutral: "bg-neutral-100 text-neutral-700 border border-neutral-200",
  success: "bg-success-subtle text-success border border-success-border",
  danger: "bg-danger-subtle text-danger border border-danger-border",
  info: "bg-info-subtle text-info border border-info-border",
  warning: "bg-amber-50 text-amber-700 border border-amber-200",
};

const toneSolid: Record<BadgeTone, string> = {
  neutral: "bg-neutral-700 text-white border border-neutral-700",
  success: "bg-success text-success-fg border border-success",
  danger: "bg-danger text-danger-fg border border-danger",
  info: "bg-info text-info-fg border border-info",
  warning: "bg-amber-500 text-white border border-amber-500",
};

const sizeClasses: Record<BadgeSize, string> = {
  sm: "px-1.5 py-0.5 text-xs",
  md: "px-2 py-0.5 text-xs",
};

export function Badge({
  className = "",
  tone = "neutral",
  intensity = "subtle",
  size = "md",
  children,
  ...rest
}: BadgeProps) {
  const colors = intensity === "solid" ? toneSolid[tone] : toneSubtle[tone];
  return (
    <span
      className={[
        "inline-flex items-center gap-1 rounded-md font-medium",
        "whitespace-nowrap",
        colors,
        sizeClasses[size],
        className,
      ]
        .filter(Boolean)
        .join(" ")}
      {...rest}
    >
      {children}
    </span>
  );
}
