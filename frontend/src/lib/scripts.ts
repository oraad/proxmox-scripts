import type { Category, Script } from "@/lib/types";

export function flattenScripts(categories: Category[]): Script[] {
  const bySlug = new Map<string, Script>();
  for (const category of categories) {
    for (const script of category.scripts) {
      bySlug.set(script.slug, script);
    }
  }
  return [...bySlug.values()];
}

export function getScriptBySlug(categories: Category[], slug: string): Script | null {
  return flattenScripts(categories).find((script) => script.slug === slug) ?? null;
}

export function getRelatedScripts(
  categories: Category[],
  script: Script,
  limit = 4,
): Script[] {
  const related = flattenScripts(categories).filter(
    (item) =>
      item.slug !== script.slug &&
      item.categories.some((categoryId) => script.categories.includes(categoryId)),
  );
  return related.slice(0, limit);
}

export function formatDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function typeLabel(type: Script["type"]): string {
  switch (type) {
    case "ct":
      return "LXC";
    case "vm":
      return "VM";
    case "pve":
      return "PVE";
    case "addon":
      return "Addon";
    case "turnkey":
      return "Turnkey";
  }
}

export function hasAlpineMethod(script: Script): boolean {
  return script.install_methods.some(
    (method) => method.type === "alpine" || method.resources.os === "alpine",
  );
}
