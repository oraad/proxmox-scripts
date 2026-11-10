"use client";

import {
  ArrowLeft,
  BookOpenText,
  ExternalLink,
  Globe,
  Info,
  TerminalSquare,
  TriangleAlert,
  XCircle,
} from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import { useMemo, useState } from "react";

import { CopyButton } from "@/components/copy-button";
import { ScriptBadges } from "@/components/scripts/script-badges";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { githubRepo } from "@/config/site-config";
import { getRelatedScripts, typeLabel } from "@/lib/scripts";
import { buildInstallCommand, methodLabel } from "@/lib/install-command";
import type { Category, Script } from "@/lib/types";
import { cn } from "@/lib/utils";

const noteConfig: Record<
  "info" | "warning" | "error",
  { className: string; icon: React.ReactNode }
> = {
  info: {
    className: "border-blue-500/30 bg-blue-500/10 text-blue-900 dark:text-blue-100",
    icon: <Info className="mt-0.5 h-4 w-4 shrink-0" />,
  },
  warning: {
    className: "border-amber-500/30 bg-amber-500/10 text-amber-950 dark:text-amber-100",
    icon: <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" />,
  },
  error: {
    className: "border-red-500/30 bg-red-500/10 text-red-950 dark:text-red-100",
    icon: <XCircle className="mt-0.5 h-4 w-4 shrink-0" />,
  },
};

const noteRank: Record<"info" | "warning" | "error", number> = {
  warning: 0,
  error: 1,
  info: 2,
};

export function ScriptDetail({
  script,
  categories,
  backHref = "/scripts",
  categoryParam,
}: {
  script: Script;
  categories: Category[];
  backHref?: string;
  categoryParam?: string | null;
}) {
  const [methodIndex, setMethodIndex] = useState(0);
  const method = script.install_methods[methodIndex] ?? script.install_methods[0];
  const command = method ? buildInstallCommand(method) : "";
  const related = useMemo(
    () => getRelatedScripts(categories, script, 3),
    [categories, script],
  );

  function scriptHref(slug: string) {
    const params = new URLSearchParams({ id: slug });
    if (categoryParam && /^\d+$/.test(categoryParam)) {
      params.set("category", categoryParam);
    }
    return `/scripts?${params.toString()}`;
  }

  const sortedNotes = useMemo(
    () => script.notes.slice().sort((a, b) => noteRank[a.type] - noteRank[b.type]),
    [script.notes],
  );
  const visibleNotes = sortedNotes.slice(0, 4);
  const moreNotes = sortedNotes.slice(4);

  const sourcePath = method?.script;
  const sourceUrl = sourcePath ? `${githubRepo}/blob/main/${sourcePath}` : null;

  const hasCredentials =
    script.default_credentials.username !== null ||
    script.default_credentials.password !== null;

  const resources = method?.resources;
  const resourceItems = [
    resources?.cpu != null ? `CPU ${resources.cpu}` : null,
    resources?.ram != null ? `RAM ${formatRam(resources.ram)}` : null,
    resources?.hdd != null ? `Disk ${resources.hdd} GB` : null,
    script.interface_port != null ? `Port ${script.interface_port}` : null,
  ].filter((item): item is string => item !== null);

  return (
    <div className="space-y-6">
      <Link
        href={backHref}
        className="focus-surface inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="h-4 w-4" />
        Back
      </Link>

      <header className="flex items-start gap-3 sm:gap-4">
        {script.logo ? (
          <Image
            src={script.logo}
            alt=""
            width={64}
            height={64}
            className="h-14 w-14 shrink-0 rounded-lg border border-border bg-background object-contain p-1 sm:h-16 sm:w-16"
            unoptimized
          />
        ) : (
          <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-lg border border-border bg-muted text-lg font-semibold text-muted-foreground sm:h-16 sm:w-16">
            {script.name.slice(0, 2)}
          </div>
        )}
        <div className="min-w-0 flex-1 space-y-1.5">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <h1 className="text-xl font-semibold tracking-tight sm:text-2xl">{script.name}</h1>
            <ScriptBadges script={script} />
            {script.updateable ? (
              <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" aria-hidden="true" />
                Updateable
              </span>
            ) : null}
          </div>
          <div className="flex flex-wrap gap-x-3 gap-y-1 text-xs">
            {script.website ? (
              <ExternalLinkItem href={script.website} icon={<Globe className="h-3.5 w-3.5" />} label="Website" />
            ) : null}
            {script.documentation ? (
              <ExternalLinkItem
                href={script.documentation}
                icon={<BookOpenText className="h-3.5 w-3.5" />}
                label="Documentation"
              />
            ) : null}
            {sourceUrl ? (
              <ExternalLinkItem
                href={sourceUrl}
                icon={<TerminalSquare className="h-3.5 w-3.5" />}
                label="Source"
              />
            ) : null}
          </div>
        </div>
      </header>

      <p className="max-w-3xl text-sm leading-6 text-muted-foreground">{script.description}</p>

      {method ? (
        <section className="space-y-2">
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
                  <InstallBlock command={buildInstallCommand(item)} />
                </TabsContent>
              ))}
            </Tabs>
          ) : (
            <InstallBlock command={command} />
          )}
        </section>
      ) : null}

      {resourceItems.length > 0 ? (
        <p className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
          {resourceItems.map((item, index) => (
            <span key={item} className="flex items-center gap-3">
              {index > 0 ? (
                <span aria-hidden="true" className="text-border">
                  ·
                </span>
              ) : null}
              {item}
            </span>
          ))}
        </p>
      ) : null}

      {script.config_path ? (
        <details className="text-sm">
          <summary className="focus-surface w-fit cursor-pointer text-muted-foreground hover:text-foreground">
            Details
          </summary>
          <p className="mt-2 text-muted-foreground">
            Config <code className="break-all rounded bg-muted px-1.5 py-0.5 text-xs">{script.config_path}</code>
          </p>
        </details>
      ) : null}

      {visibleNotes.length > 0 ? (
        <section className="space-y-2">
          {visibleNotes.map((note, index) => (
            <NoteAlert key={`${note.type}-${index}`} note={note} />
          ))}
          {moreNotes.length > 0 ? (
            <details>
              <summary className="focus-surface w-fit cursor-pointer text-sm text-muted-foreground hover:text-foreground">
                More notes ({moreNotes.length})
              </summary>
              <div className="mt-2 space-y-2">
                {moreNotes.map((note, index) => (
                  <NoteAlert key={`${note.type}-more-${index}`} note={note} />
                ))}
              </div>
            </details>
          ) : null}
        </section>
      ) : null}

      {hasCredentials ? (
        <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
          <span className="font-medium">Default credentials</span>
          {script.default_credentials.username !== null ? (
            <span className="text-muted-foreground">
              User <code className="break-all rounded bg-muted px-1.5 py-0.5 text-xs">{script.default_credentials.username}</code>
            </span>
          ) : null}
          {script.default_credentials.password !== null ? (
            <span className="text-muted-foreground">
              Password{" "}
              <code className="break-all rounded bg-muted px-1.5 py-0.5 text-xs">
                {script.default_credentials.password}
              </code>
            </span>
          ) : null}
        </p>
      ) : null}

      {related.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-sm font-medium">Related</h2>
          <ul className="divide-y divide-border/60 overflow-hidden rounded-lg border border-border">
            {related.map((item) => (
              <li key={item.slug}>
                <Link
                  href={scriptHref(item.slug)}
                  className="focus-surface flex items-center justify-between gap-3 px-3 py-2 text-sm hover:bg-accent"
                >
                  <span className="truncate">{item.name}</span>
                  <span className="shrink-0 text-xs text-muted-foreground">{typeLabel(item.type)}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}

function InstallBlock({ command }: { command: string }) {
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm text-muted-foreground">Run in the Proxmox shell.</p>
        <CopyButton text={command} />
      </div>
      <pre className="overflow-x-auto rounded-lg border border-border bg-card p-3 text-xs leading-5">
        {command}
      </pre>
    </div>
  );
}

function NoteAlert({ note }: { note: Script["notes"][number] }) {
  const config = noteConfig[note.type];

  return (
    <div
      className={cn(
        "flex gap-2 rounded-lg border px-3 py-2 text-sm leading-6",
        config.className,
      )}
    >
      {config.icon}
      <span className="min-w-0 break-words">{note.text}</span>
    </div>
  );
}

function ExternalLinkItem({
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
      className="focus-surface inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
    >
      {icon}
      {label}
      <ExternalLink className="h-3 w-3" />
    </a>
  );
}

function formatRam(ram: number): string {
  if (ram >= 1024 && ram % 1024 === 0) {
    return `${ram / 1024} GB`;
  }
  return `${ram} MB`;
}
