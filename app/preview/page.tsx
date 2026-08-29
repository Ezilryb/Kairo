// /app/preview/page.tsx
// =============================================================================
// Page de preview des composants UI — utile pour la revue de direction
// visuelle (Phase 0 / Tâche 3). Sera retirée ou déplacée sous un flag
// "showcase" en Phase 9. Aucun lien de navigation n'y mène pour l'instant.
// =============================================================================
import { Activity, TrendingUp, Wallet } from "lucide-react";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { StatBlock } from "@/components/ui/StatBlock";

export const metadata = {
  title: "Kairo — Preview design system",
};

export default function PreviewPage() {
  return (
    <main className="min-h-screen bg-neutral-50 px-6 py-10">
      <div className="mx-auto max-w-5xl space-y-10">
        <header>
          <h1 className="text-2xl font-semibold tracking-tight">
            Design system — preview
          </h1>
          <p className="mt-1 text-sm text-neutral-500">
            Direction Google Finance : clair, data-dense, accents vert / rouge.
          </p>
        </header>

        {/* ----- Card ----- */}
        <Section title="Card">
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <Card>
              <div className="text-sm font-medium">Carte standard</div>
              <p className="mt-1 text-sm text-neutral-500">
                Bordure fine, fond blanc, ombre très légère.
              </p>
            </Card>
            <Card variant="subtle" padding="sm">
              <div className="text-sm font-medium">Subtle + sm</div>
              <p className="mt-1 text-xs text-neutral-500">
                Pour les zones très denses (rangées de tableau).
              </p>
            </Card>
            <Card padding="lg">
              <div className="text-base font-medium">Carte large</div>
              <p className="mt-1 text-sm text-neutral-500">
                Pour les blocs importants (résumé de trade).
              </p>
            </Card>
          </div>
        </Section>

        {/* ----- Button ----- */}
        <Section title="Button">
          <Card className="space-y-6">
            <div>
              <div className="mb-2 text-xs font-medium uppercase tracking-wide text-neutral-500">
                Variants
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button variant="primary">Publier le trade</Button>
                <Button variant="success">Valider</Button>
                <Button variant="danger">Fermer</Button>
                <Button variant="secondary">Annuler</Button>
                <Button variant="ghost">Plus tard</Button>
              </div>
            </div>
            <div>
              <div className="mb-2 text-xs font-medium uppercase tracking-wide text-neutral-500">
                Sizes
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button size="sm">Small</Button>
                <Button size="md">Medium</Button>
                <Button size="lg">Large</Button>
              </div>
            </div>
            <div>
              <div className="mb-2 text-xs font-medium uppercase tracking-wide text-neutral-500">
                States
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button loading>Chargement…</Button>
                <Button disabled>Désactivé</Button>
              </div>
            </div>
          </Card>
        </Section>

        {/* ----- Badge ----- */}
        <Section title="Badge">
          <Card className="space-y-6">
            <div>
              <div className="mb-2 text-xs font-medium uppercase tracking-wide text-neutral-500">
                Subtle (défaut)
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Badge tone="neutral">draft</Badge>
                <Badge tone="info">live</Badge>
                <Badge tone="warning">forgotten</Badge>
                <Badge tone="success">closed</Badge>
                <Badge tone="danger">archived</Badge>
              </div>
            </div>
            <div>
              <div className="mb-2 text-xs font-medium uppercase tracking-wide text-neutral-500">
                Solid
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Badge tone="neutral" intensity="solid">
                  draft
                </Badge>
                <Badge tone="info" intensity="solid">
                  live
                </Badge>
                <Badge tone="warning" intensity="solid">
                  forgotten
                </Badge>
                <Badge tone="success" intensity="solid">
                  closed
                </Badge>
                <Badge tone="danger" intensity="solid">
                  archived
                </Badge>
              </div>
            </div>
          </Card>
        </Section>

        {/* ----- StatBlock ----- */}
        <Section title="StatBlock">
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <Card>
              <StatBlock
                label="Winrate"
                value="62.4"
                unit="%"
                icon={<Activity className="h-4 w-4" />}
                delta={2.1}
                mono
              />
            </Card>
            <Card>
              <StatBlock
                label="PnL du jour"
                value="+342.18"
                unit="€"
                icon={<TrendingUp className="h-4 w-4" />}
                delta={4.6}
                deltaLabel="+4.6 %"
              />
            </Card>
            <Card>
              <StatBlock
                label="Drawdown max"
                value="-1 240"
                unit="€"
                icon={<Wallet className="h-4 w-4" />}
                delta={-3.2}
              />
            </Card>
            <Card>
              <StatBlock
                label="Trades ouverts"
                value="3"
                delta={0}
                mono
              />
            </Card>
          </div>
        </Section>
      </div>
    </main>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-neutral-500">
        {title}
      </h2>
      {children}
    </section>
  );
}
