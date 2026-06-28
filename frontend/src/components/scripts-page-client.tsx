"use client";

import Fuse from "fuse.js";
import Image from "next/image";
import { useEffect, useMemo, useState } from "react";

import { ScriptDetail } from "@/components/script-detail";
import type { Category, Script } from "@/lib/types";
import { cn } from "@/lib/utils";

type ScriptsPageClientProps = {
  categories: Category[];
};

export function ScriptsPageClient({ categories }: ScriptsPageClientProps) {
  const [query, setQuery] = useState("");
  const [selectedCategoryId, setSelectedCategoryId] = useState<number | "all">("all");

  const uniqueScripts = useMemo(() => {
    const bySlug = new Map<string, Script>();
    for (const category of categories) {
      for (const script of category.scripts) {
        bySlug.set(script.slug, script);
      }
    }
    return [...bySlug.values()];
  }, [categories]);

  const [selectedSlug, setSelectedSlug] = useState<string | null>(
    uniqueScripts[0]?.slug ?? null,
  );

  const categoryScripts = useMemo(() => {
    if (selectedCategoryId === "all") return uniqueScripts;
    return categories.find((category) => category.id === selectedCategoryId)?.scripts ?? [];
  }, [categories, selectedCategoryId, uniqueScripts]);

  const filteredScripts = useMemo(() => {
    if (!query.trim()) return categoryScripts;

    const fuse = new Fuse(categoryScripts, {
      keys: ["name", "slug", "description"],
      threshold: 0.35,
    });
    return fuse.search(query.trim()).map((result) => result.item);
  }, [categoryScripts, query]);

  useEffect(() => {
    if (selectedSlug && filteredScripts.some((script) => script.slug === selectedSlug)) {
      return;
    }
    setSelectedSlug(filteredScripts[0]?.slug ?? null);
  }, [filteredScripts, selectedSlug]);

  const selectedScript =
    filteredScripts.find((script) => script.slug === selectedSlug) ??
    filteredScripts[0] ??
    null;

  const emptyMessage =
    query.trim().length > 0
      ? "No scripts match your search."
      : "No scripts in this category.";

  return (
    <div className="grid gap-6 lg:grid-cols-[260px_minmax(0,1fr)]">
      <aside className="space-y-4">
        <div>
          <label htmlFor="search" className="mb-2 block text-sm font-medium">
            Search
          </label>
          <input
            id="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search scripts..."
            className="w-full rounded-md border border-border bg-card px-3 py-2 text-sm outline-none ring-primary focus:ring-2"
          />
        </div>
        <div>
          <div className="mb-2 text-sm font-medium">Categories</div>
          <div className="space-y-1">
            <CategoryButton
              active={selectedCategoryId === "all"}
              onClick={() => setSelectedCategoryId("all")}
              label="All scripts"
              count={uniqueScripts.length}
            />
            {categories.map((category) => (
              <CategoryButton
                key={category.id}
                active={selectedCategoryId === category.id}
                onClick={() => setSelectedCategoryId(category.id)}
                label={category.name}
                count={category.scripts.length}
              />
            ))}
          </div>
        </div>
      </aside>

      <div className="grid gap-6 xl:grid-cols-[320px_minmax(0,1fr)]">
        <section className="space-y-2">
          {filteredScripts.map((script) => (
            <ScriptListItem
              key={script.slug}
              script={script}
              active={selectedScript?.slug === script.slug}
              onSelect={() => setSelectedSlug(script.slug)}
            />
          ))}
          {filteredScripts.length === 0 ? (
            <div className="rounded-xl border border-dashed border-border p-6 text-sm text-muted-foreground">
              {emptyMessage}
            </div>
          ) : null}
        </section>

        <section className="rounded-xl border border-border bg-card p-6">
          {selectedScript ? (
            <ScriptDetail script={selectedScript} />
          ) : (
            <p className="text-sm text-muted-foreground">Select a script to view details.</p>
          )}
        </section>
      </div>
    </div>
  );
}

function CategoryButton({
  active,
  onClick,
  label,
  count,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  count: number;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex w-full items-center justify-between rounded-md px-3 py-2 text-left text-sm",
        active ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-accent hover:text-foreground",
      )}
    >
      <span>{label}</span>
      <span className="text-xs opacity-80">{count}</span>
    </button>
  );
}

function ScriptListItem({
  script,
  active,
  onSelect,
}: {
  script: Script;
  active: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={cn(
        "flex w-full items-center gap-3 rounded-xl border px-3 py-3 text-left transition",
        active ? "border-primary bg-primary/10" : "border-border bg-card hover:border-primary/40",
      )}
    >
      {script.logo ? (
        <Image src={script.logo} alt="" width={32} height={32} className="rounded-md" unoptimized />
      ) : (
        <div className="flex h-8 w-8 items-center justify-center rounded-md bg-muted text-xs font-semibold">
          {script.name.slice(0, 2)}
        </div>
      )}
      <div className="min-w-0">
        <div className="truncate font-medium">{script.name}</div>
        <div className="truncate text-xs text-muted-foreground">{script.type.toUpperCase()}</div>
      </div>
    </button>
  );
}
