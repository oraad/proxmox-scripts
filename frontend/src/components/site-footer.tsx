import Link from "next/link";

import {
  communityScriptsRepo,
  communityScriptsUrl,
  githubRepo,
  siteName,
} from "@/config/site-config";

export function SiteFooter() {
  return (
    <footer className="border-t border-border/60 bg-card/40">
      <div className="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-10 sm:px-6 md:flex-row md:items-start md:justify-between">
        <div className="max-w-md space-y-2">
          <p className="font-semibold tracking-tight">{siteName}</p>
          <p className="text-sm leading-6 text-muted-foreground">
            Community-scripts-compatible Proxmox VE helper scripts for apps not in the main
            collection. MIT licensed.
          </p>
        </div>
        <div className="grid gap-6 text-sm sm:grid-cols-2">
          <div className="space-y-2">
            <p className="font-medium">This project</p>
            <ul className="space-y-1 text-muted-foreground">
              <li>
                <Link href="/scripts" className="hover:text-foreground">
                  Browse scripts
                </Link>
              </li>
              <li>
                <a href={githubRepo} target="_blank" rel="noreferrer" className="hover:text-foreground">
                  GitHub repository
                </a>
              </li>
            </ul>
          </div>
          <div className="space-y-2">
            <p className="font-medium">Community Scripts</p>
            <ul className="space-y-1 text-muted-foreground">
              <li>
                <a
                  href={communityScriptsUrl}
                  target="_blank"
                  rel="noreferrer"
                  className="hover:text-foreground"
                >
                  community-scripts.org
                </a>
              </li>
              <li>
                <a
                  href={communityScriptsRepo}
                  target="_blank"
                  rel="noreferrer"
                  className="hover:text-foreground"
                >
                  ProxmoxVE repository
                </a>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </footer>
  );
}
