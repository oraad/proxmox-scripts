import Image from "next/image";
import Link from "next/link";

import { ScriptBadges } from "@/components/scripts/script-badges";
import { Card, CardContent } from "@/components/ui/card";
import type { Script } from "@/lib/types";

export function ScriptCard({ script }: { script: Script }) {
  return (
    <Link href={`/scripts?id=${encodeURIComponent(script.slug)}`} className="group block h-full">
      <Card className="h-full transition group-hover:border-primary/40 group-hover:shadow-md">
        <CardContent className="flex h-full flex-col gap-3 p-5">
          <div className="flex items-start gap-3">
            {script.logo ? (
              <Image
                src={script.logo}
                alt=""
                width={40}
                height={40}
                className="rounded-lg border border-border bg-background p-1"
                unoptimized
              />
            ) : (
              <div className="flex h-10 w-10 items-center justify-center rounded-lg border border-border bg-muted text-sm font-semibold">
                {script.name.slice(0, 2)}
              </div>
            )}
            <div className="min-w-0 flex-1">
              <h3 className="truncate font-semibold tracking-tight group-hover:text-primary">
                {script.name}
              </h3>
              <div className="mt-1.5">
                <ScriptBadges script={script} />
              </div>
            </div>
          </div>
          <p className="line-clamp-3 text-sm leading-6 text-muted-foreground">{script.description}</p>
        </CardContent>
      </Card>
    </Link>
  );
}
