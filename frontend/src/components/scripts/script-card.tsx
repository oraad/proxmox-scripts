import Image from "next/image";
import Link from "next/link";

import { ScriptBadges } from "@/components/scripts/script-badges";
import { Card, CardContent } from "@/components/ui/card";
import type { Script } from "@/lib/types";

export function ScriptCard({ script, href }: { script: Script; href?: string }) {
  return (
    <Link
      href={href ?? `/scripts?id=${encodeURIComponent(script.slug)}`}
      className="group block h-full"
    >
      <Card className="h-full transition-colors group-hover:border-primary/40">
        <CardContent className="flex h-full items-start gap-3 p-3">
          {script.logo ? (
            <Image
              src={script.logo}
              alt=""
              width={36}
              height={36}
              className="h-9 w-9 shrink-0 rounded-md border border-border bg-background object-contain p-0.5"
              unoptimized
            />
          ) : (
            <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border border-border bg-muted text-xs font-semibold text-muted-foreground">
              {script.name.slice(0, 2)}
            </div>
          )}
          <div className="min-w-0 flex-1 space-y-0.5">
            <div className="flex min-w-0 items-center gap-2">
              <h3 className="truncate text-sm font-medium tracking-tight group-hover:text-primary">
                {script.name}
              </h3>
              <div className="shrink-0">
                <ScriptBadges script={script} />
              </div>
            </div>
            <p className="line-clamp-1 text-xs leading-5 text-muted-foreground sm:text-sm">
              {script.description}
            </p>
          </div>
        </CardContent>
      </Card>
    </Link>
  );
}
