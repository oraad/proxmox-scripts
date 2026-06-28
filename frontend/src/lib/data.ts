import type { Category } from "@/lib/types";
import { basePath } from "@/config/site-config";

export async function fetchCategories(): Promise<Category[]> {
  const response = await fetch(`${basePath}/categories.json`, {
    next: { revalidate: false },
  });

  if (!response.ok) {
    throw new Error(`Failed to load categories: ${response.statusText}`);
  }

  return response.json();
}

export function flattenScripts(categories: Category[]) {
  return categories.flatMap((category) => category.scripts);
}
