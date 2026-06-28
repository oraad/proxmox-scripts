import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../..");
const jsonDir = path.join(repoRoot, "json");
const outFile = path.join(__dirname, "../public/categories.json");

const metadataFile = "metadata.json";

async function main() {
  const metadataRaw = await fs.readFile(path.join(jsonDir, metadataFile), "utf8");
  const metadata = JSON.parse(metadataRaw);

  const entries = await fs.readdir(jsonDir);
  const scripts = await Promise.all(
    entries
      .filter((name) => name.endsWith(".json") && name !== metadataFile)
      .map(async (name) => {
        const content = await fs.readFile(path.join(jsonDir, name), "utf8");
        return JSON.parse(content);
      }),
  );

  const categories = metadata.categories
    .map((category) => ({
      ...category,
      scripts: scripts.filter((script) => script.categories?.includes(category.id)),
    }))
    .filter((category) => category.scripts.length > 0)
    .sort((a, b) => a.sort_order - b.sort_order);

  await fs.mkdir(path.dirname(outFile), { recursive: true });
  await fs.writeFile(outFile, JSON.stringify(categories, null, 2));
  console.log(`Wrote ${categories.length} categories to ${outFile}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
