// /components/ui/Card.tsx
// =============================================================================
// Card — conteneur de base Google Finance (bordure fine, fond blanc, ombre
// légère, coins 12px). Data-dense : peu de padding, hiérarchie typographique
// assumée par les enfants.
//
// React 19 : `ref` est un prop normal (plus de forwardRef nécessaire).
// =============================================================================
import type { HTMLAttributes, Ref } from "react";

export interface CardProps extends HTMLAttributes<HTMLDivElement> {
  /** Padding interne. Défaut : "md" (p-4). "none" pour les usages très denses. */
  padding?: "none" | "sm" | "md" | "lg";
  /** Variante visuelle. "default" = carte standard, "subtle" = carte sans bordure. */
  variant?: "default" | "subtle";
  /** React 19 : ref passée comme un prop normal. */
  ref?: Ref<HTMLDivElement>;
}

const paddingClasses: Record<NonNullable<CardProps["padding"]>, string> = {
  none: "",
  sm: "p-3",
  md: "p-4",
  lg: "p-6",
};

export function Card({
  className = "",
  padding = "md",
  variant = "default",
  ref,
  ...rest
}: CardProps) {
  const base = "rounded-card bg-card";
  const variantClasses =
    variant === "default"
      ? "border border-neutral-200 shadow-card"
      : "border border-transparent";
  return (
    <div
      ref={ref}
      className={`${base} ${variantClasses} ${paddingClasses[padding]} ${className}`}
      {...rest}
    />
  );
}
