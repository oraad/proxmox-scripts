"use client";

import Image from "next/image";
import { ExternalLink } from "lucide-react";
import { useState } from "react";

import { CopyButton } from "@/components/copy-button";
import { buildInstallCommand, methodLabel } from "@/lib/install-command";
import type { Script } from "@/lib/types";
import { cn } from "@/lib/utils";

const noteStyles = {
  info: "border-blue-500/30 bg-blue-500/10 text-blue-900 dark:text-blue-100",
  warning: "border-amber-500/30 bg-amber-500/10 text-amber-950 dark:text-amber-100",
  error: "border-red-500/30 bg-red-500/10 text-red-950 dark:text-red-100",
};

export function ScriptDetail({ script }: { script: Script }) {
  const [methodIndex, setMethodIndex] = useState(0);
  const method = script.install_methods[methodIndex] ?? script.install_methods[0];
  const command = method ? buildInstallCommand(method) : "";

  return (
    <div className="space-y-6">
      <div className="flex items-start gap-4">
        {script.logo ? (
          <Image
            src={script.logo}
            alt=""
            width={56}
            height={56}
            className="rounded-lg border border-border bg-card p-2"
            unoptimized
          />
        ) : null}
        <div className="min-w-0 flex-1">
          <h2 className="text-2xl font-semibold tracking-tight">{script.name}</h2>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">{script.description}</p>
          <div className="mt-3 flex flex-wrap gap-3 text-sm">
            {script.website ? (
              <a
                href={script.website}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 text-primary hover:underline"
              >
                Website <ExternalLink className="h-3.5 w-3.5" />
              </a>
            ) : null}
            {script.documentation ? (
              <a
                href={script.documentation}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 text-primary hover:underline"
              >
                Documentation <ExternalLink className="h-3.5 w-3.5" />
              </a>
            ) : null}
          </div>
        </div>
      </div>

      {method ? (
        <section className="rounded-xl border border-border bg-card p-4">
          <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
            <h3 className="font-medium">Install on Proxmox host</h3>
            {script.install_methods.length > 1 ? (
              <div className="flex flex-wrap gap-2">
                {script.install_methods.map((item, index) => (
                  <button
                    key={`${item.type}-${index}`}
                    type="button"
                    onClick={() => setMethodIndex(index)}
                    className={cn(
                      "rounded-md border px-3 py-1.5 text-xs",
                      index === methodIndex
                        ? "border-primary bg-primary text-primary-foreground"
                        : "border-border bg-background text-muted-foreground hover:text-foreground",
                    )}
                  >
                    {methodLabel(item)}
                  </button>
                ))}
              </div>
            ) : null}
          </div>
          <pre className="overflow-x-auto rounded-lg border border-border bg-background p-4 text-xs leading-6">
            {command}
          </pre>
          <div className="mt-3">
            <CopyButton text={command} />
          </div>
        </section>
      ) : null}

      <section className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <ResourceCard label="CPU" value={`${method?.resources.cpu ?? "—"} cores`} />
        <ResourceCard label="RAM" value={`${method?.resources.ram ?? "—"} MB`} />
        <ResourceCard label="Disk" value={`${method?.resources.hdd ?? "—"} GB`} />
        <ResourceCard
          label="Port"
          value={script.interface_port ? String(script.interface_port) : "—"}
        />
      </section>

      {script.notes.length > 0 ? (
        <section className="space-y-3">
          <h3 className="font-medium">Notes</h3>
          {script.notes.map((note, index) => (
            <div
              key={index}
              className={cn("rounded-lg border px-4 py-3 text-sm leading-6", noteStyles[note.type])}
            >
              {note.text}
            </div>
          ))}
        </section>
      ) : null}
    </div>
  );
}

function ResourceCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-border bg-card p-4">
      <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
      <div className="mt-1 text-lg font-medium">{value}</div>
    </div>
  );
}
