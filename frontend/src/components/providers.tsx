"use client";

import { ThemeProvider } from "next-themes";

import { SiteHeader } from "@/components/site-header";

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
      <SiteHeader />
      <main className="mx-auto min-h-[calc(100vh-4rem)] w-full max-w-7xl px-4 py-8 sm:px-6">{children}</main>
    </ThemeProvider>
  );
}
