"use client";

import { ThemeProvider } from "next-themes";
import { useState } from "react";

import { CommandMenu } from "@/components/command-menu";
import { SiteFooter } from "@/components/site-footer";
import { SiteHeader } from "@/components/site-header";
import type { Script } from "@/lib/types";

export function Providers({
  children,
  scripts,
}: {
  children: React.ReactNode;
  scripts: Script[];
}) {
  const [searchOpen, setSearchOpen] = useState(false);

  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
      <div className="flex min-h-screen flex-col">
        <SiteHeader onOpenSearch={() => setSearchOpen(true)} />
        <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-8 sm:px-6">{children}</main>
        <SiteFooter />
      </div>
      <CommandMenu scripts={scripts} open={searchOpen} onOpenChange={setSearchOpen} />
    </ThemeProvider>
  );
}
