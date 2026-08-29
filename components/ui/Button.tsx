// /components/ui/Button.tsx
// =============================================================================
// Button — variants alignés sur le design system (primary/secondary/ghost/
// success/danger). Tailles sm/md/lg. Utilisable comme <button> ; pour
// transformer en <a>, envelopper avec <Link asChild> (Radix) — à introduire
// en Phase 5/9 si besoin.
//
// React 19 : `ref` est un prop normal (plus de forwardRef nécessaire).
// =============================================================================
import type { ButtonHTMLAttributes, Ref } from "react";

export type ButtonVariant =
  | "primary"
  | "secondary"
  | "ghost"
  | "success"
  | "danger";
export type ButtonSize = "sm" | "md" | "lg";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Affiche un état de chargement (désactive le bouton + opacité réduite). */
  loading?: boolean;
  /** Prend toute la largeur disponible. */
  block?: boolean;
  /** React 19 : ref passée comme un prop normal. */
  ref?: Ref<HTMLButtonElement>;
}

const variantClasses: Record<ButtonVariant, string> = {
  primary:
    "bg-info text-info-fg hover:bg-blue-700 active:bg-blue-800 disabled:bg-blue-300",
  secondary:
    "bg-white text-neutral-900 border border-neutral-300 hover:bg-neutral-50 active:bg-neutral-100 disabled:bg-neutral-100 disabled:text-neutral-400",
  ghost:
    "bg-transparent text-neutral-700 hover:bg-neutral-100 active:bg-neutral-200 disabled:text-neutral-400",
  success:
    "bg-success text-success-fg hover:bg-green-700 active:bg-green-800 disabled:bg-green-300",
  danger:
    "bg-danger text-danger-fg hover:bg-red-700 active:bg-red-800 disabled:bg-red-300",
};

const sizeClasses: Record<ButtonSize, string> = {
  sm: "h-8 px-3 text-sm gap-1.5",
  md: "h-10 px-4 text-sm gap-2",
  lg: "h-12 px-5 text-base gap-2",
};

export function Button({
  className = "",
  variant = "primary",
  size = "md",
  loading = false,
  block = false,
  disabled,
  type = "button",
  ref,
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      ref={ref}
      type={type}
      disabled={disabled || loading}
      className={[
        "inline-flex items-center justify-center rounded-lg font-medium",
        "transition-colors duration-100",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-info focus-visible:ring-offset-2",
        "disabled:cursor-not-allowed",
        variantClasses[variant],
        sizeClasses[size],
        block ? "w-full" : "",
        loading ? "opacity-70" : "",
        className,
      ]
        .filter(Boolean)
        .join(" ")}
      {...rest}
    >
      {children}
    </button>
  );
}
