// /tailwind.config.ts
// =============================================================================
// Tailwind config — Direction Google Finance (Phase 0 / Tâche 3)
// Cartes épurées, data-dense, mode clair uniquement, accents vert/rouge.
// =============================================================================
import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
  ],
  darkMode: "class", // désactivé en Phase 0 — mode clair uniquement
  theme: {
    extend: {
      fontFamily: {
        // Inter chargé via next/font/google dans app/layout.tsx,
        // exposé via la variable CSS --font-inter
        sans: ["var(--font-inter)", "system-ui", "sans-serif"],
      },
      // Couleurs sémantiques trading : on NE redéfinit pas toute la palette
      // Tailwind (neutres conservés). success/danger alignés sur green-600 /
      // red-600 pour un contraste AA sur fond blanc.
      colors: {
        // Couleur structurelle des cartes — doit contraster avec le fond de
        // page (neutral-50). Sans cette entrée, `bg-card` n'est pas généré
        // par Tailwind et les cartes apparaissent transparentes.
        card: "#FFFFFF",
        success: {
          DEFAULT: "#16A34A", // green-600
          fg: "#FFFFFF",
          subtle: "#DCFCE7", // green-100
          border: "#86EFAC", // green-300
        },
        danger: {
          DEFAULT: "#DC2626", // red-600
          fg: "#FFFFFF",
          subtle: "#FEE2E2", // red-100
          border: "#FCA5A5", // red-300
        },
        info: {
          DEFAULT: "#2563EB", // blue-600
          fg: "#FFFFFF",
          subtle: "#DBEAFE", // blue-100
          border: "#93C5FD", // blue-300
        },
      },
      // Cartes data-dense Google Finance : on garde l'ombre très légère,
      // on privilégie la séparation par bordure fine.
      boxShadow: {
        card: "0 1px 2px 0 rgb(0 0 0 / 0.04)",
      },
      borderRadius: {
        card: "12px",
      },
    },
  },
  plugins: [],
};

export default config;
