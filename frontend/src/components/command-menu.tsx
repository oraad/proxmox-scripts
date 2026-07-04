"use client";

import Fuse from "fuse.js";
import { Search, X } from "lucide-react";
import Image from "next/image";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";

import { Input } from "@/components/ui/input";
import { typeLabel } from "@/lib/scripts";
import type { Script } from "@/lib/types";
import { cn } from "@/lib/utils";

type CommandMenuProps = {
  scripts: Script[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
};

export function CommandMenu({ scripts, open, onOpenChange }: CommandMenuProps) {
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        onOpenChange(!open);
      }
      if (event.key === "Escape" && open) {
        onOpenChange(false);
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open, onOpenChange]);

  if (!open) return null;

  return (
    <CommandMenuDialog scripts={scripts} onOpenChange={onOpenChange} />
  );
}

function CommandMenuDialog({
  scripts,
  onOpenChange,
}: {
  scripts: Script[];
  onOpenChange: (open: boolean) => void;
}) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);

  const fuse = useMemo(
    () =>
      new Fuse(scripts, {
        keys: ["name", "slug", "description"],
        threshold: 0.35,
      }),
    [scripts],
  );

  const results = useMemo(() => {
    if (!query.trim()) return scripts.slice(0, 8);
    return fuse.search(query.trim()).map((result) => result.item).slice(0, 8);
  }, [fuse, query, scripts]);

  const safeActiveIndex = Math.min(activeIndex, Math.max(results.length - 1, 0));

  useEffect(() => {
    const timer = window.setTimeout(() => inputRef.current?.focus(), 0);
    return () => window.clearTimeout(timer);
  }, []);

  function selectScript(script: Script) {
    onOpenChange(false);
    router.push(`/scripts?id=${encodeURIComponent(script.slug)}`);
  }

  function updateQuery(value: string) {
    setQuery(value);
    setActiveIndex(0);
  }

  return (
    <div className="fixed inset-0 z-[100]">
      <button
        type="button"
        aria-label="Close search"
        className="absolute inset-0 bg-background/70 backdrop-blur-sm"
        onClick={() => onOpenChange(false)}
      />
      <div className="relative mx-auto mt-[12vh] w-full max-w-xl px-4">
        <div className="overflow-hidden rounded-xl border border-border bg-popover shadow-2xl">
          <div className="flex items-center gap-2 border-b border-border px-3">
            <Search className="h-4 w-4 text-muted-foreground" />
            <Input
              ref={inputRef}
              value={query}
              onChange={(event) => updateQuery(event.target.value)}
              placeholder="Search scripts..."
              className="border-0 bg-transparent px-0 shadow-none focus-visible:ring-0"
              onKeyDown={(event) => {
                if (event.key === "ArrowDown") {
                  event.preventDefault();
                  setActiveIndex((index) => Math.min(index + 1, results.length - 1));
                } else if (event.key === "ArrowUp") {
                  event.preventDefault();
                  setActiveIndex((index) => Math.max(index - 1, 0));
                } else if (event.key === "Enter" && results[safeActiveIndex]) {
                  event.preventDefault();
                  selectScript(results[safeActiveIndex]);
                }
              }}
            />
            <button
              type="button"
              aria-label="Close"
              className="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={() => onOpenChange(false)}
            >
              <X className="h-4 w-4" />
            </button>
          </div>
          <ul className="max-h-80 overflow-y-auto p-2">
            {results.length === 0 ? (
              <li className="px-3 py-6 text-center text-sm text-muted-foreground">
                No scripts found.
              </li>
            ) : (
              results.map((script, index) => (
                <li key={script.slug}>
                  <button
                    type="button"
                    onClick={() => selectScript(script)}
                    onMouseEnter={() => setActiveIndex(index)}
                    className={cn(
                      "flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left",
                      index === safeActiveIndex
                        ? "bg-accent text-accent-foreground"
                        : "hover:bg-accent/60",
                    )}
                  >
                    {script.logo ? (
                      <Image
                        src={script.logo}
                        alt=""
                        width={28}
                        height={28}
                        className="rounded-md"
                        unoptimized
                      />
                    ) : (
                      <div className="flex h-7 w-7 items-center justify-center rounded-md bg-muted text-xs font-semibold">
                        {script.name.slice(0, 2)}
                      </div>
                    )}
                    <div className="min-w-0 flex-1">
                      <div className="truncate font-medium">{script.name}</div>
                      <div className="truncate text-xs text-muted-foreground">
                        {typeLabel(script.type)} · {script.slug}
                      </div>
                    </div>
                  </button>
                </li>
              ))
            )}
          </ul>
        </div>
      </div>
    </div>
  );
}
