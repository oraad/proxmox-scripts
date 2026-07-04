import fs from "node:fs/promises";
import path from "node:path";

import type { Category } from "@/lib/types";

export async function loadCategories(): Promise<Category[]> {
  const filePath = path.join(process.cwd(), "public/categories.json");
  const content = await fs.readFile(filePath, "utf8");
  return JSON.parse(content) as Category[];
}

export {
  flattenScripts,
  formatDate,
  getRelatedScripts,
  getScriptBySlug,
  hasAlpineMethod,
  typeLabel,
} from "@/lib/scripts";
