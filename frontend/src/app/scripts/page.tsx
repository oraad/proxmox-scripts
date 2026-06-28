import type { Metadata } from "next";
import fs from "node:fs/promises";
import path from "node:path";

import { ScriptsPageClient } from "@/components/scripts-page-client";
import type { Category } from "@/lib/types";
import { siteName } from "@/config/site-config";

export const metadata: Metadata = {
  title: `Scripts | ${siteName}`,
};

async function loadCategories(): Promise<Category[]> {
  const filePath = path.join(process.cwd(), "public/categories.json");
  const content = await fs.readFile(filePath, "utf8");
  return JSON.parse(content);
}

export default async function ScriptsPage() {
  const categories = await loadCategories();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">Scripts</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Browse custom Proxmox LXC helper scripts and copy the install command for your shell.
        </p>
      </div>
      <ScriptsPageClient categories={categories} />
    </div>
  );
}
