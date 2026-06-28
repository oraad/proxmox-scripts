import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, Container, Github } from "lucide-react";

import { githubRepo, siteDescription, siteName } from "@/config/site-config";

export const metadata: Metadata = {
  title: siteName,
  description: siteDescription,
};

export default function HomePage() {
  return (
    <div className="space-y-12">
      <section className="rounded-2xl border border-border bg-card px-6 py-10 sm:px-10">
        <p className="text-sm font-medium uppercase tracking-wide text-primary">Proxmox VE Helper Scripts</p>
        <h1 className="mt-3 max-w-3xl text-4xl font-semibold tracking-tight sm:text-5xl">
          Custom LXC scripts for apps not in community-scripts
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-7 text-muted-foreground">{siteDescription}</p>
        <div className="mt-8 flex flex-wrap gap-3">
          <Link
            href="/scripts"
            className="inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground"
          >
            Browse scripts
            <ArrowRight className="h-4 w-4" />
          </Link>
          <a
            href={githubRepo}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-md border border-border bg-background px-4 py-2 text-sm"
          >
            <Github className="h-4 w-4" />
            View repository
          </a>
        </div>
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
    </div>
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
    <div className="rounded-xl border border-border bg-card p-5">
      <div className="mb-3 inline-flex rounded-md bg-primary/10 p-2 text-primary">{icon}</div>
      <h2 className="font-medium">{title}</h2>
      <p className="mt-2 text-sm leading-6 text-muted-foreground">{description}</p>
    </div>
  );
}
