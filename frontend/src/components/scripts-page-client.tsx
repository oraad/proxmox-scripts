"use client";

import { useSearchParams } from "next/navigation";
import { useMemo } from "react";

import { ScriptDetail } from "@/components/scripts/script-detail";
import { ScriptsBrowser } from "@/components/scripts/scripts-browser";
import { getScriptBySlug } from "@/lib/scripts";
import type { Category } from "@/lib/types";

export function ScriptsPageClient({ categories }: { categories: Category[] }) {
  const searchParams = useSearchParams();
  const selectedSlug = searchParams.get("id");

  const selectedScript = useMemo(() => {
    if (!selectedSlug) return null;
    return getScriptBySlug(categories, selectedSlug);
  }, [categories, selectedSlug]);

  if (selectedSlug && selectedScript) {
    return (
      <ScriptDetail
        key={selectedScript.slug}
        script={selectedScript}
        categories={categories}
      />
    );
  }

  if (selectedSlug && !selectedScript) {
    return (
      <div className="space-y-4">
        <div className="rounded-xl border border-dashed border-border p-8 text-sm text-muted-foreground">
          Script <code className="rounded bg-muted px-1.5 py-0.5">{selectedSlug}</code> was not
          found.
        </div>
        <ScriptsBrowser categories={categories} />
      </div>
    );
  }

  return <ScriptsBrowser categories={categories} />;
}
