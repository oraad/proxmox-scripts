import { Badge } from "@/components/ui/badge";
import { hasAlpineMethod, typeLabel } from "@/lib/scripts";
import type { Script } from "@/lib/types";

export function ScriptBadges({ script }: { script: Script }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      <Badge variant="secondary">{typeLabel(script.type)}</Badge>
      {script.privileged ? <Badge variant="warning">Privileged</Badge> : null}
      {script.updateable ? <Badge variant="success">Updateable</Badge> : null}
      {hasAlpineMethod(script) ? <Badge variant="outline">Alpine</Badge> : null}
    </div>
  );
}
