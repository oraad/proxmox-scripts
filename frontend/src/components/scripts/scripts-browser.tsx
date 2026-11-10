"use client";

import Fuse from "fuse.js";
import { LayoutGrid, Search } from "lucide-react";
import { usePathname, useRouter } from "next/navigation";
import { useMemo, useState } from "react";

import { ScriptCard } from "@/components/scripts/script-card";
import { ScriptDetail } from "@/components/scripts/script-detail";
import { CategoryIcon } from "@/components/ui/category-icon";
import { Input } from "@/components/ui/input";
import { flattenScripts } from "@/lib/scripts";
import type { Category, Script } from "@/lib/types";
import { cn } from "@/lib/utils";

type Filter = "all" | number;

export function ScriptsBrowser({
  categories,
  categoryParam,
  selectedScript,
  selectedSlug,
}: {
  categories: Category[];
  categoryParam?: string | null;
  selectedScript: Script | null;
  selectedSlug: string | null;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const [query, setQuery] = useState("");
  const [dismissedSlug, setDismissedSlug] = useState<string | null>(null);

  const filter: Filter =
    categoryParam && /^\d+$/.test(categoryParam) ? Number(categoryParam) : "all";

  const allScripts = useMemo(() => flattenScripts(categories), [categories]);

  const categoryScripts = useMemo(
    () =>
      filter === "all"
        ? allScripts
        : allScripts.filter((script) => script.categories.includes(filter)),
    [allScripts, filter],
  );

  const fuse = useMemo(
    () =>
      new Fuse(categoryScripts, {
        keys: ["name", "slug", "description"],
        threshold: 0.35,
      }),
    [categoryScripts],
  );

  const visibleScripts = useMemo(() => {
    const trimmed = query.trim();
    const scripts = trimmed
      ? fuse.search(trimmed).map((result) => result.item)
      : categoryScripts;
    return scripts.slice().sort((a, b) => a.name.localeCompare(b.name));
  }, [categoryScripts, fuse, query]);

  const activeCategoryName =
    filter === "all" ? "All scripts" : (categories.find((item) => item.id === filter)?.name ?? "All scripts");

  const hasFilters = Boolean(query.trim()) || filter !== "all";
  const backHref = filter === "all" ? "/scripts" : `/scripts?category=${filter}`;
  const detailScript =
    selectedScript && selectedScript.slug !== dismissedSlug ? selectedScript : null;

  function setFilter(next: Filter) {
    setDismissedSlug(null);
    const params = new URLSearchParams();
    if (next !== "all") params.set("category", String(next));
    const qs = params.toString();
    router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
  }

  function handleQueryChange(value: string) {
    setQuery(value);
    if (!selectedScript || selectedScript.slug === dismissedSlug) return;

    setDismissedSlug(selectedScript.slug);
    const params = new URLSearchParams();
    if (filter !== "all") params.set("category", String(filter));
    const qs = params.toString();
    window.history.replaceState(
      null,
      "",
      qs ? `${window.location.pathname}?${qs}` : window.location.pathname,
    );
  }

  function handleCardClick(slug: string) {
    if (dismissedSlug !== slug) return;
    setDismissedSlug(null);
    const params = new URLSearchParams({ id: slug });
    if (filter !== "all") params.set("category", String(filter));
    window.history.replaceState(null, "", `${window.location.pathname}?${params.toString()}`);
  }

  function clearFilters() {
    setQuery("");
    setFilter("all");
  }

  const mobileControls = (
    <div className="space-y-2 md:hidden">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          value={query}
          onChange={(event) => handleQueryChange(event.target.value)}
          placeholder="Search scripts..."
          aria-label="Search scripts"
          className="h-9 pl-8 text-sm"
        />
      </div>
      <div className="flex gap-2 overflow-x-auto pb-1">
        <CategoryChip
          active={filter === "all"}
          label="All"
          count={allScripts.length}
          onClick={() => setFilter("all")}
        />
        {categories.map((category) => (
          <CategoryChip
            key={category.id}
            active={filter === category.id}
            label={category.name}
            count={category.scripts.length}
            onClick={() => setFilter(category.id)}
          />
        ))}
      </div>
    </div>
  );

  return (
    <div className="md:grid md:grid-cols-[15rem_minmax(0,1fr)] md:gap-6 lg:grid-cols-[16rem_minmax(0,1fr)]">
      <aside className="hidden md:block">
        <div className="sticky top-20 space-y-3">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={query}
              onChange={(event) => handleQueryChange(event.target.value)}
              placeholder="Search scripts..."
              aria-label="Search scripts"
              className="h-9 pl-8 text-sm"
            />
          </div>
          <nav aria-label="Categories" className="space-y-0.5">
            <RailItem
              active={filter === "all"}
              label="All scripts"
              count={allScripts.length}
              icon={<LayoutGrid className="h-4 w-4" />}
              onClick={() => setFilter("all")}
            />
            {categories.map((category) => (
              <RailItem
                key={category.id}
                active={filter === category.id}
                label={category.name}
                count={category.scripts.length}
                icon={<CategoryIcon icon={category.icon} className="h-4 w-4" />}
                onClick={() => setFilter(category.id)}
              />
            ))}
          </nav>
        </div>
      </aside>

      <div className="min-w-0 space-y-4">
        {detailScript ? (
          <ScriptDetail
            key={detailScript.slug}
            script={detailScript}
            categories={categories}
            backHref={backHref}
            categoryParam={categoryParam}
          />
        ) : (
          <>
            {mobileControls}

            {selectedSlug && !selectedScript ? (
              <div className="rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
                Script <code className="rounded bg-muted px-1.5 py-0.5">{selectedSlug}</code> was
                not found.
              </div>
            ) : null}

            <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <h1 className="text-lg font-semibold tracking-tight">{activeCategoryName}</h1>
              <p className="text-xs text-muted-foreground">
                {visibleScripts.length} of {categoryScripts.length}
              </p>
            </div>

            {visibleScripts.length === 0 ? (
              <div className="rounded-lg border border-dashed border-border p-6 text-center text-sm text-muted-foreground">
                <p>No scripts match your search.</p>
                {hasFilters ? (
                  <button
                    type="button"
                    onClick={clearFilters}
                    className="focus-surface mt-3 inline-flex h-8 items-center justify-center rounded-md border border-border bg-background px-3 text-sm font-medium hover:bg-accent"
                  >
                    Clear filters
                  </button>
                ) : null}
              </div>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2">
                {visibleScripts.map((script) => (
                  <ScriptCard
                    key={script.slug}
                    script={script}
                    href={`/scripts?id=${encodeURIComponent(script.slug)}${
                      filter === "all" ? "" : `&category=${filter}`
                    }`}
                    onClick={() => handleCardClick(script.slug)}
                  />
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function RailItem({
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
        "focus-surface flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors",
        active
          ? "bg-primary/10 font-medium text-primary"
          : "text-muted-foreground hover:bg-accent hover:text-foreground",
      )}
    >
      <span className="shrink-0">{icon}</span>
      <span className="min-w-0 flex-1 truncate">{label}</span>
      <span className="shrink-0 text-xs tabular-nums text-muted-foreground">{count}</span>
    </button>
  );
}

function CategoryChip({
  active,
  label,
  count,
  onClick,
}: {
  active: boolean;
  label: string;
  count: number;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "focus-surface inline-flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border px-3 text-sm font-medium transition-colors",
        active
          ? "border-primary/40 bg-primary/10 text-primary"
          : "border-border bg-background text-muted-foreground hover:bg-accent hover:text-foreground",
      )}
    >
      <span>{label}</span>
      <span className="text-xs tabular-nums opacity-70">{count}</span>
    </button>
  );
}
