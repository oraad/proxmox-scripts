"use client";

import {
  ArrowLeft,
  BookOpenText,
  Code2,
  Cpu,
  ExternalLink,
  Globe,
  HardDrive,
  MemoryStick,
  Network,
} from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import { useMemo, useState } from "react";

import { CopyButton } from "@/components/copy-button";
import { ScriptBadges } from "@/components/scripts/script-badges";
import { ScriptCard } from "@/components/scripts/script-card";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { githubRepo } from "@/config/site-config";
import { formatDate, getRelatedScripts } from "@/lib/scripts";
import { buildInstallCommand, methodLabel } from "@/lib/install-command";
import type { Category, Script } from "@/lib/types";
import { cn } from "@/lib/utils";

const noteStyles = {
  info: "border-blue-500/30 bg-blue-500/10 text-blue-900 dark:text-blue-100",
  warning: "border-amber-500/30 bg-amber-500/10 text-amber-950 dark:text-amber-100",
  error: "border-red-500/30 bg-red-500/10 text-red-950 dark:text-red-100",
};

const noteTitles = {
  info: "Info",
  warning: "Warnings",
  error: "Errors",
};

export function ScriptDetail({
  script,
  categories,
}: {
  script: Script;
  categories: Category[];
}) {
  const [methodIndex, setMethodIndex] = useState(0);
  const method = script.install_methods[methodIndex] ?? script.install_methods[0];
  const command = method ? buildInstallCommand(method) : "";
  const related = useMemo(
    () => getRelatedScripts(categories, script),
    [categories, script],
  );
  const sourcePath = method?.script;
  const sourceUrl = sourcePath ? `${githubRepo}/blob/main/${sourcePath}` : null;

  const notesByType = useMemo(() => {
    const groups: Record<"info" | "warning" | "error", Script["notes"]> = {
      info: [],
      warning: [],
      error: [],
    };
    for (const note of script.notes) {
      groups[note.type].push(note);
    }
    return groups;
  }, [script.notes]);

  const hasCredentials =
    script.default_credentials.username !== null ||
    script.default_credentials.password !== null;

  return (
    <div className="space-y-8">
      <div>
        <Link
          href="/scripts"
          className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" />
          All scripts
        </Link>
      </div>

      <div className="flex flex-col gap-6 sm:flex-row sm:items-start">
        {script.logo ? (
          <Image
            src={script.logo}
            alt=""
            width={72}
            height={72}
            className="rounded-xl border border-border bg-card p-2"
            unoptimized
          />
        ) : (
          <div className="flex h-[72px] w-[72px] items-center justify-center rounded-xl border border-border bg-muted text-xl font-semibold">
            {script.name.slice(0, 2)}
          </div>
        )}
        <div className="min-w-0 flex-1 space-y-3">
          <div className="space-y-2">
            <h1 className="text-3xl font-semibold tracking-tight">{script.name}</h1>
            <p className="text-sm text-muted-foreground">
              Date added: {formatDate(script.date_created)}
            </p>
          </div>
          <ScriptBadges script={script} />
          <div className="flex flex-wrap gap-2">
            {script.website ? (
              <LinkButton href={script.website} icon={<Globe className="h-4 w-4" />} label="Website" />
            ) : null}
            {script.documentation ? (
              <LinkButton
                href={script.documentation}
                icon={<BookOpenText className="h-4 w-4" />}
                label="Documentation"
              />
            ) : null}
            {sourceUrl ? (
              <LinkButton href={sourceUrl} icon={<Code2 className="h-4 w-4" />} label="Source" />
            ) : null}
          </div>
        </div>
      </div>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold tracking-tight">About</h2>
        <p className="max-w-3xl text-sm leading-7 text-muted-foreground">{script.description}</p>
      </section>

      {script.notes.length > 0 ? (
        <section className="space-y-4">
          <h2 className="text-xl font-semibold tracking-tight">Notes</h2>
          {(["warning", "error", "info"] as const).map((type) =>
            notesByType[type].length > 0 ? (
              <div key={type} className="space-y-2">
                <h3 className="text-sm font-medium">{noteTitles[type]}</h3>
                {notesByType[type].map((note, index) => (
                  <div
                    key={`${type}-${index}`}
                    className={cn("rounded-lg border px-4 py-3 text-sm leading-6", noteStyles[type])}
                  >
                    {note.text}
                  </div>
                ))}
              </div>
            ) : null,
          )}
        </section>
      ) : null}

      {method ? (
        <section className="space-y-4">
          <div className="flex flex-wrap items-center gap-3">
            <h2 className="text-xl font-semibold tracking-tight">Install</h2>
            {script.updateable ? <Badge variant="success">Updateable</Badge> : null}
          </div>

          {script.install_methods.length > 1 ? (
            <Tabs
              defaultValue="0"
              value={String(methodIndex)}
              onValueChange={(value) => setMethodIndex(Number(value))}
            >
              <TabsList>
                {script.install_methods.map((item, index) => (
                  <TabsTrigger key={`${item.type}-${index}`} value={String(index)}>
                    {methodLabel(item)}
                  </TabsTrigger>
                ))}
              </TabsList>
              {script.install_methods.map((item, index) => (
                <TabsContent key={`${item.type}-${index}`} value={String(index)}>
                  <InstallBlock
                    command={buildInstallCommand(item)}
                    type={script.type}
                    name={script.name}
                  />
                </TabsContent>
              ))}
            </Tabs>
          ) : (
            <InstallBlock command={command} type={script.type} name={script.name} />
          )}
        </section>
      ) : null}

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <ResourceCard
          icon={<Cpu className="h-4 w-4" />}
          label="CPU"
          value={method?.resources.cpu != null ? `${method.resources.cpu} cores` : "—"}
        />
        <ResourceCard
          icon={<MemoryStick className="h-4 w-4" />}
          label="RAM"
          value={method?.resources.ram != null ? `${method.resources.ram} MB` : "—"}
        />
        <ResourceCard
          icon={<HardDrive className="h-4 w-4" />}
          label="Disk"
          value={method?.resources.hdd != null ? `${method.resources.hdd} GB` : "—"}
        />
        <ResourceCard
          icon={<Network className="h-4 w-4" />}
          label="Port"
          value={script.interface_port != null ? String(script.interface_port) : "—"}
        />
      </section>

      {method?.resources.os || method?.resources.version ? (
        <p className="text-sm text-muted-foreground">
          Default OS:{" "}
          <span className="font-medium text-foreground">
            {[method.resources.os, method.resources.version].filter(Boolean).join(" ")}
          </span>
          {script.config_path ? (
            <>
              {" "}
              · Config path: <code className="rounded bg-muted px-1.5 py-0.5">{script.config_path}</code>
            </>
          ) : null}
        </p>
      ) : null}

      {hasCredentials ? (
        <section className="space-y-3">
          <h2 className="text-xl font-semibold tracking-tight">Default credentials</h2>
          <Card>
            <CardContent className="grid gap-3 p-4 sm:grid-cols-2">
              <div>
                <div className="text-xs uppercase tracking-wide text-muted-foreground">Username</div>
                <div className="mt-1 font-mono text-sm">
                  {script.default_credentials.username ?? "—"}
                </div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wide text-muted-foreground">Password</div>
                <div className="mt-1 font-mono text-sm">
                  {script.default_credentials.password ?? "—"}
                </div>
              </div>
            </CardContent>
          </Card>
        </section>
      ) : null}

      {related.length > 0 ? (
        <section className="space-y-4">
          <Separator />
          <h2 className="text-xl font-semibold tracking-tight">You might also like</h2>
          <div className="grid gap-4 sm:grid-cols-2">
            {related.map((item) => (
              <ScriptCard key={item.slug} script={item} />
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}

function InstallBlock({
  command,
  type,
  name,
}: {
  command: string;
  type: Script["type"];
  name: string;
}) {
  const isHostTool = type === "pve" || type === "addon";

  return (
    <div className="space-y-3 rounded-xl border border-border bg-card p-4">
      <p className="text-sm leading-6 text-muted-foreground">
        {isHostTool
          ? `Run the command below in the Proxmox VE Shell to use ${name}.`
          : `Run the command below in the Proxmox VE Shell to install ${name}.`}
      </p>
      <pre className="overflow-x-auto rounded-lg border border-border bg-background p-4 text-xs leading-6">
        {command}
      </pre>
      <CopyButton text={command} />
    </div>
  );
}

function ResourceCard({
  icon,
  label,
  value,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
}) {
  return (
    <Card>
      <CardContent className="p-4">
        <div className="mb-2 inline-flex rounded-md bg-primary/10 p-2 text-primary">{icon}</div>
        <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
        <div className="mt-1 text-lg font-medium">{value}</div>
      </CardContent>
    </Card>
  );
}

function LinkButton({
  href,
  icon,
  label,
}: {
  href: string;
  icon: React.ReactNode;
  label: string;
}) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="inline-flex h-9 items-center justify-center gap-2 rounded-md border border-border bg-background px-3 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
    >
      {icon}
      {label}
      <ExternalLink className="h-3.5 w-3.5" />
    </a>
  );
}
