import type { Metadata } from "next";
import { Suspense } from "react";

import { ScriptsPageClient } from "@/components/scripts-page-client";
import { siteName } from "@/config/site-config";
import { loadCategories } from "@/lib/data";

export const metadata: Metadata = {
  title: `Scripts | ${siteName}`,
};

export default async function ScriptsPage() {
  const categories = await loadCategories();

  return (
    <Suspense fallback={<div className="text-sm text-muted-foreground">Loading scripts…</div>}>
      <ScriptsPageClient categories={categories} />
    </Suspense>
  );
}
