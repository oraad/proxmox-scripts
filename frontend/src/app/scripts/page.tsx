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
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">All scripts</h1>
        <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
          Browse custom Proxmox LXC helper scripts and copy the install command for your shell.
        </p>
      </div>
      <Suspense fallback={<div className="text-sm text-muted-foreground">Loading scripts…</div>}>
        <ScriptsPageClient categories={categories} />
      </Suspense>
    </div>
  );
}
