// /app/layout.tsx
// =============================================================================
// Layout racine Next.js (App Router). Charge Inter via next/font pour servir
// de base typographique au design system. Mode clair uniquement (Phase 0).
// =============================================================================
import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-inter",
});

export const metadata: Metadata = {
  title: "Kairo — Trading Journal & Réseau Social",
  description: "Réseau social européen de trading journaling.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="fr" className={inter.variable}>
      <body>{children}</body>
    </html>
  );
}
