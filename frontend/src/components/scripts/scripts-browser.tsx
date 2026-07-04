"use client";

import Fuse from "fuse.js";
import { Search } from "lucide-react";
import { useMemo, useState } from "react";

import { ScriptCard } from "@/components/scripts/script-card";
import { Input } from "@/components/ui/input";
import { flattenScripts } from "@/lib/scripts";
import type { Category, Script } from "@/lib/types";

export function ScriptsBrowser({ categories }: { categories: Category[] }) {
  const [query, setQuery] = useState("");
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

  const filteredCategories = useMemo(() => {
    if (!matchedSlugs) return categories;

    return categories
      .map((category) => ({
        ...category,
        scripts: category.scripts.filter((script) => matchedSlugs.has(script.slug)),
      }))
      .filter((category) => category.scripts.length > 0);
  }, [categories, matchedSlugs]);

  const totalVisible = useMemo(() => {
    const bySlug = new Map<string, Script>();
    for (const category of filteredCategories) {
      for (const script of category.scripts) {
        bySlug.set(script.slug, script);
      }
    }
    return bySlug.size;
  }, [filteredCategories]);

  return (
    <div className="space-y-8">
      <div className="sticky top-16 z-40 -mx-4 border-b border-border/60 bg-background/90 px-4 py-4 backdrop-blur sm:-mx-6 sm:px-6">
        <label htmlFor="quickfilter" className="mb-2 block text-sm font-medium">
          Quickfilter
        </label>
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
        <p className="mt-2 text-xs text-muted-foreground">
          Showing {totalVisible} of {allScripts.length} scripts
        </p>
      </div>

      {filteredCategories.length === 0 ? (
        <div className="rounded-xl border border-dashed border-border p-10 text-center text-sm text-muted-foreground">
          No scripts match your search.
        </div>
      ) : (
        filteredCategories.map((category) => (
          <section key={category.id} className="space-y-4">
            <div className="space-y-1">
              <div className="flex flex-wrap items-baseline gap-2">
                <h2 className="text-2xl font-semibold tracking-tight">{category.name}</h2>
                <span className="text-sm text-muted-foreground">
                  {category.scripts.length}{" "}
                  {category.scripts.length === 1 ? "script" : "scripts"}
                </span>
              </div>
              {category.description ? (
                <p className="max-w-3xl text-sm text-muted-foreground">{category.description}</p>
              ) : null}
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
