"use client";

import Fuse from "fuse.js";
import { ListFilter, LayoutGrid, Search, Tags } from "lucide-react";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";

import { ScriptCard } from "@/components/scripts/script-card";
import { CategoryIcon } from "@/components/ui/category-icon";
import { Input } from "@/components/ui/input";
import { flattenScripts } from "@/lib/scripts";
import type { Category, Script } from "@/lib/types";
import { cn } from "@/lib/utils";

type Filter = "all" | number;

export function ScriptsBrowser({
  categories,
  categoryParam,
}: {
  categories: Category[];
  categoryParam?: string | null;
}) {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const filter: Filter =
    categoryParam && /^\d+$/.test(categoryParam)
      ? Number(categoryParam)
      : ("all" as Filter);

  function setFilter(next: Filter) {
    const params = new URLSearchParams();
    if (next !== "all") params.set("category", String(next));
    const qs = params.toString();
    router.replace(qs ? `?${qs}` : "?");
  }

  const allScripts = useMemo(() => flattenScripts(categories), [categories]);

  const fuse = useMemo(
    () =>
      new Fuse(allScripts, {
        keys: ["name", "slug", "description"],
        threshold: 0.35,
      }),
    [allScripts],
  );

  const matchedSlugs = useMemo(() => {
    if (!query.trim()) return null;
    return new Set(fuse.search(query.trim()).map((result) => result.item.slug));
  }, [fuse, query]);

  const visibleCategories = useMemo(() => {
    let source = categories;
    if (filter !== "all") {
      source = categories.filter((category) => category.id === filter);
    }

    if (!matchedSlugs) return source;

    return source
      .map((category) => ({
        ...category,
        scripts: category.scripts.filter((script) => matchedSlugs.has(script.slug)),
      }))
      .filter((category) => category.scripts.length > 0);
  }, [categories, filter, matchedSlugs]);

  const totalVisible = useMemo(() => {
    const bySlug = new Map<string, Script>();
    for (const category of visibleCategories) {
      for (const script of category.scripts) {
        bySlug.set(script.slug, script);
      }
    }
    return bySlug.size;
  }, [visibleCategories]);

  const hasQuery = Boolean(query.trim());

  return (
    <div className="space-y-6">
      <div className="sticky top-16 z-40 -mx-4 border-b border-border/60 bg-background/90 px-4 py-4 backdrop-blur sm:-mx-6 sm:px-6">
        <div className="relative max-w-xl">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            id="quickfilter"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search scripts..."
            className="pl-9"
          />
        </div>

        <div className="mt-3 flex flex-wrap items-center gap-2">
          <CategoryChip
            active={filter === "all"}
            label="All scripts"
            count={allScripts.length}
            icon={<LayoutGrid className="h-3.5 w-3.5" />}
            onClick={() => setFilter("all")}
          />
          {categories.map((category) => (
            <CategoryChip
              key={category.id}
              active={filter === category.id}
              label={category.name}
              count={category.scripts.length}
              icon={<CategoryIcon icon={category.icon} className="h-3.5 w-3.5" />}
              onClick={() => setFilter(category.id)}
            />
          ))}
        </div>

        <p className="mt-3 flex items-center gap-1.5 text-xs text-muted-foreground">
          {hasQuery || filter !== "all" ? <ListFilter className="h-3.5 w-3.5" /> : <Tags className="h-3.5 w-3.5" />}
          Showing {totalVisible} of {allScripts.length} scripts
        </p>
      </div>

      {visibleCategories.length === 0 ? (
        <div className="rounded-xl border border-dashed border-border p-10 text-center">
          <div className="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-muted text-muted-foreground">
            <Search className="h-5 w-5" />
          </div>
          <p className="font-medium">No scripts match your search.</p>
          <p className="mt-1 text-sm text-muted-foreground">
            Try a different keyword or clear the current filters.
          </p>
          {(hasQuery || filter !== "all") && (
            <button
              type="button"
              onClick={() => {
                setQuery("");
                setFilter("all");
              }}
              className="focus-surface mt-4 inline-flex h-9 items-center justify-center rounded-md border border-border bg-background px-4 text-sm font-medium hover:bg-accent"
            >
              Clear filters
            </button>
          )}
        </div>
      ) : (
        visibleCategories.map((category) => (
          <section key={category.id} className="space-y-4">
            <div className="flex items-start gap-3">
              <div className="mt-0.5 inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
                <CategoryIcon icon={category.icon} className="h-4 w-4" />
              </div>
              <div className="space-y-1">
                <div className="flex flex-wrap items-baseline gap-2">
                  <h2 className="text-2xl font-semibold tracking-tight">{category.name}</h2>
                  <span className="text-sm text-muted-foreground">
                    {category.scripts.length} {category.scripts.length === 1 ? "script" : "scripts"}
                  </span>
                </div>
                {category.description ? (
                  <p className="max-w-3xl text-sm text-muted-foreground">{category.description}</p>
                ) : null}
              </div>
            </div>
            <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
              {category.scripts
                .slice()
                .sort((a, b) => a.name.localeCompare(b.name))
                .map((script) => (
                  <ScriptCard key={script.slug} script={script} />
                ))}
            </div>
          </section>
        ))
      )}
    </div>
  );
}

function CategoryChip({
  active,
  label,
  count,
  icon,
  onClick,
}: {
  active: boolean;
  label: string;
  count: number;
  icon: React.ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "focus-surface inline-flex h-8 items-center gap-1.5 rounded-full border px-3 text-sm font-medium transition-colors",
        active
          ? "border-primary/40 bg-primary/10 text-primary"
          : "border-border bg-background text-muted-foreground hover:bg-accent hover:text-foreground",
      )}
    >
      {icon}
      <span>{label}</span>
      <span
        className={cn(
          "ml-0.5 rounded-full px-1.5 py-0.5 text-[11px] font-semibold leading-none",
          active ? "bg-primary/15 text-primary" : "bg-muted text-muted-foreground",
        )}
      >
        {count}
      </span>
    </button>
  );
}
