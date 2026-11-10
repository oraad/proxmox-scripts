import { ArrowRight, Github } from "lucide-react";
import Link from "next/link";

import { ScriptCard } from "@/components/scripts/script-card";
import { CategoryIcon } from "@/components/ui/category-icon";
import { githubRepo, siteDescription } from "@/config/site-config";
import { flattenScripts, loadCategories } from "@/lib/data";

export default async function HomePage() {
  const categories = await loadCategories();
  const scripts = flattenScripts(categories).sort((a, b) => a.name.localeCompare(b.name));

  return (
    <div className="space-y-6">
      <section className="max-w-2xl space-y-4">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
          Custom scripts for Proxmox VE.
        </h1>
        <p className="text-sm leading-6 text-muted-foreground sm:text-base">{siteDescription}</p>
        <div className="flex flex-wrap gap-2">
          <Link
            href="/scripts"
            className="focus-surface inline-flex h-9 items-center justify-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            Browse scripts
            <ArrowRight className="h-4 w-4" />
          </Link>
          <a
            href={githubRepo}
            target="_blank"
            rel="noreferrer"
            className="focus-surface inline-flex h-9 items-center justify-center gap-2 rounded-md border border-border bg-background px-4 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          >
            <Github className="h-4 w-4" />
            GitHub
          </a>
        </div>
        <p className="text-xs text-muted-foreground">
          {scripts.length} scripts · {categories.length} categories · MIT
        </p>
      </section>

      <nav aria-label="Categories" className="flex gap-2 overflow-x-auto pb-1 sm:flex-wrap sm:overflow-visible">
        {categories.map((category) => (
          <Link
            key={category.id}
            href={`/scripts?category=${category.id}`}
            className="focus-surface inline-flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-border bg-card px-3 text-sm text-muted-foreground hover:bg-accent hover:text-foreground"
          >
            <CategoryIcon icon={category.icon} className="h-3.5 w-3.5" />
            <span>{category.name}</span>
            <span className="text-xs tabular-nums opacity-70">{category.scripts.length}</span>
          </Link>
        ))}
      </nav>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold tracking-tight">All scripts</h2>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {scripts.map((script) => (
            <ScriptCard key={script.slug} script={script} />
          ))}
        </div>
      </section>
    </div>
  );
}
