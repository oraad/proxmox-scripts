import type { Metadata } from "next";
import { Inter } from "next/font/google";

import { Providers } from "@/components/providers";
import { siteDescription, siteName } from "@/config/site-config";
import { flattenScripts, loadCategories } from "@/lib/data";

import "./globals.css";

const inter = Inter({ subsets: ["latin"] });

export const metadata: Metadata = {
  title: siteName,
  description: siteDescription,
};

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const categories = await loadCategories();
  const scripts = flattenScripts(categories);

  return (
    <html lang="en" suppressHydrationWarning>
      <body className={inter.className}>
        <Providers scripts={scripts}>{children}</Providers>
      </body>
    </html>
  );
}
