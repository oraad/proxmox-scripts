import { ArrowRight, Container, Github } from "lucide-react";
import Link from "next/link";

import { ScriptCard } from "@/components/scripts/script-card";
import { Card, CardContent } from "@/components/ui/card";
import {
  communityScriptsUrl,
  githubRepo,
  siteDescription,
  siteName,
} from "@/config/site-config";
import { flattenScripts, loadCategories } from "@/lib/data";

export default async function HomePage() {
  const categories = await loadCategories();
  const scripts = flattenScripts(categories);
  const recentScripts = scripts
    .slice()
    .sort((a, b) => b.date_created.localeCompare(a.date_created))
    .slice(0, 4);

  return (
    <div className="space-y-16">
      <section className="relative overflow-hidden rounded-2xl border border-border bg-card px-6 py-12 sm:px-10 sm:py-16">
        <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_top_right,hsl(var(--primary)/0.12),transparent_50%)]" />
        <div className="relative max-w-3xl space-y-6">
          <p className="text-sm font-medium uppercase tracking-wide text-primary">
            Proxmox VE Helper Scripts
          </p>
          <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
            Your homelab,
            <span className="block text-primary">custom scripts included.</span>
          </h1>
          <p className="max-w-2xl text-base leading-7 text-muted-foreground">{siteDescription}</p>
          <div className="flex flex-wrap gap-3">
            <Link
              href="/scripts"
              className="inline-flex h-10 items-center justify-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90"
            >
              Browse scripts
              <ArrowRight className="h-4 w-4" />
            </Link>
            <a
              href={githubRepo}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-10 items-center justify-center gap-2 rounded-md border border-border bg-background px-4 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
            >
              <Github className="h-4 w-4" />
              View repository
            </a>
          </div>
          <p className="text-sm text-muted-foreground">
            Looking for the main collection? Visit{" "}
            <a
              href={communityScriptsUrl}
              target="_blank"
              rel="noreferrer"
              className="font-medium text-primary hover:underline"
            >
              community-scripts.org
            </a>
            .
          </p>
        </div>
      </section>

      <section className="grid gap-4 sm:grid-cols-3">
        <StatCard label="Scripts" value={String(scripts.length)} />
        <StatCard label="Categories" value={String(categories.length)} />
        <StatCard label="Install style" value="One command" />
      </section>

      <section className="grid gap-4 md:grid-cols-3">
        <FeatureCard
          icon={<Container className="h-5 w-5" />}
          title="Community-scripts compatible"
          description="Uses upstream build.func with the same var_* defaults, wizard flow, and update pattern."
        />
        <FeatureCard
          icon={<ArrowRight className="h-5 w-5" />}
          title="Copy-paste install"
          description="Each script page includes a ready-to-run one-liner for your Proxmox shell."
        />
        <FeatureCard
          icon={<Github className="h-5 w-5" />}
          title="Self-hosted catalog"
          description="JSON-driven script metadata powers this GitHub Pages site and stays in sync with the repo."
        />
      </section>

      {recentScripts.length > 0 ? (
        <section className="space-y-6">
          <div className="flex flex-wrap items-end justify-between gap-3">
            <div>
              <h2 className="text-2xl font-semibold tracking-tight">Recently added</h2>
              <p className="mt-1 text-sm text-muted-foreground">
                Newest scripts in the {siteName} catalog.
              </p>
            </div>
            <Link
              href="/scripts"
              className="inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
            >
              View all
              <ArrowRight className="h-4 w-4" />
            </Link>
          </div>
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            {recentScripts.map((script) => (
              <ScriptCard key={script.slug} script={script} />
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <Card>
      <CardContent className="p-6">
        <div className="text-3xl font-semibold tracking-tight">{value}</div>
        <div className="mt-1 text-sm text-muted-foreground">{label}</div>
      </CardContent>
    </Card>
  );
}

function FeatureCard({
  icon,
  title,
  description,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
}) {
  return (
    <Card>
      <CardContent className="p-5">
        <div className="mb-3 inline-flex rounded-md bg-primary/10 p-2 text-primary">{icon}</div>
        <h2 className="font-medium">{title}</h2>
        <p className="mt-2 text-sm leading-6 text-muted-foreground">{description}</p>
      </CardContent>
    </Card>
  );
}
