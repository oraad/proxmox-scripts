import Link from "next/link";

import { communityScriptsRepo, communityScriptsUrl, githubRepo } from "@/config/site-config";

export function SiteFooter() {
  return (
    <footer className="border-t border-border/60 bg-card/40">
      <div className="mx-auto flex max-w-7xl flex-col gap-3 px-4 py-6 text-sm sm:px-6 md:flex-row md:items-center md:justify-between">
        <p className="text-muted-foreground">
          Community-scripts-compatible helper scripts for Proxmox VE, MIT licensed.
        </p>
        <nav aria-label="Project" className="flex flex-wrap gap-x-4 gap-y-1 text-muted-foreground">
          <Link href="/scripts" className="hover:text-foreground">
            Browse scripts
          </Link>
          <a href={githubRepo} target="_blank" rel="noreferrer" className="hover:text-foreground">
            GitHub
          </a>
        </nav>
        <nav aria-label="Community Scripts" className="flex flex-wrap gap-x-4 gap-y-1 text-muted-foreground">
          <a href={communityScriptsUrl} target="_blank" rel="noreferrer" className="hover:text-foreground">
            community-scripts.org
          </a>
          <a href={communityScriptsRepo} target="_blank" rel="noreferrer" className="hover:text-foreground">
            ProxmoxVE repository
          </a>
        </nav>
      </div>
    </footer>
  );
}
