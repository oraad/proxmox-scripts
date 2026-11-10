"use client";

import { useSearchParams } from "next/navigation";
import { useMemo } from "react";

import { ScriptsBrowser } from "@/components/scripts/scripts-browser";
import { getScriptBySlug } from "@/lib/scripts";
import type { Category } from "@/lib/types";

export function ScriptsPageClient({ categories }: { categories: Category[] }) {
  const searchParams = useSearchParams();
  const selectedSlug = searchParams.get("id");
  const categoryParam = searchParams.get("category");

  const selectedScript = useMemo(() => {
    if (!selectedSlug) return null;
    return getScriptBySlug(categories, selectedSlug);
  }, [categories, selectedSlug]);

  return (
    <ScriptsBrowser
      categories={categories}
      categoryParam={categoryParam}
      selectedSlug={selectedSlug}
      selectedScript={selectedScript}
    />
  );
}
