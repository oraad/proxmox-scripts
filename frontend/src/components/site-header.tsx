"use client";

import Link from "next/link";
import { Github, Moon, Search, Sun } from "lucide-react";
import { useTheme } from "next-themes";
import { useSyncExternalStore } from "react";

import { Button } from "@/components/ui/button";
import { githubRepo, siteName } from "@/config/site-config";

function useIsClient() {
  return useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );
}

export function SiteHeader({ onOpenSearch }: { onOpenSearch?: () => void }) {
  const { theme, setTheme } = useTheme();
  const mounted = useIsClient();

  return (
    <header className="sticky top-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between gap-4 px-4 sm:px-6">
        <div className="flex min-w-0 items-center gap-6">
          <Link href="/" className="truncate font-semibold tracking-tight">
            {siteName}
          </Link>
          <nav className="hidden items-center gap-4 text-sm text-muted-foreground sm:flex">
            <Link href="/" className="hover:text-foreground">
              Home
            </Link>
            <Link href="/scripts" className="hover:text-foreground">
              Scripts
            </Link>
          </nav>
        </div>
        <div className="flex items-center gap-2">
          {onOpenSearch ? (
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={onOpenSearch}
              className="hidden text-muted-foreground md:inline-flex"
            >
              <Search className="h-4 w-4" />
              <span>Search</span>
              <kbd className="pointer-events-none ml-1 hidden rounded border border-border bg-muted px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground lg:inline">
                ⌘K
              </kbd>
            </Button>
          ) : null}
          {onOpenSearch ? (
            <Button
              type="button"
              variant="outline"
              size="icon"
              aria-label="Search scripts"
              onClick={onOpenSearch}
              className="md:hidden"
            >
              <Search className="h-4 w-4" />
            </Button>
          ) : null}
          <Button
            type="button"
            variant="outline"
            size="icon"
            aria-label="Toggle theme"
            onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
          >
            {mounted && theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
          </Button>
          <a
            href={githubRepo}
            target="_blank"
            rel="noreferrer"
            className="hidden h-9 items-center justify-center gap-2 rounded-md border border-border bg-background px-3 text-sm font-medium hover:bg-accent hover:text-accent-foreground sm:inline-flex"
          >
            <Github className="h-4 w-4" />
            GitHub
          </a>
          <a
            href={githubRepo}
            target="_blank"
            rel="noreferrer"
            aria-label="GitHub"
            className="inline-flex h-10 w-10 items-center justify-center rounded-md border border-border bg-background hover:bg-accent hover:text-accent-foreground sm:hidden"
          >
            <Github className="h-4 w-4" />
          </a>
        </div>
      </div>
    </header>
  );
}
