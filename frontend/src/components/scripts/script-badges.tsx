import { Badge } from "@/components/ui/badge";
import { typeLabel } from "@/lib/scripts";
import type { Script } from "@/lib/types";

export function ScriptBadges({ script }: { script: Script }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      <Badge variant="secondary">{typeLabel(script.type)}</Badge>
    </div>
  );
}
