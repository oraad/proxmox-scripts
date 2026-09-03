import type { Script } from "@/lib/types";
import { repoRaw } from "@/config/site-config";

type InstallMethod = Script["install_methods"][number];

export function buildInstallCommand(method: InstallMethod): string {
  const scriptUrl = `${repoRaw}/${method.script}`;
  const { os, version } = method.resources;

  if (method.type === "alpine" || os === "alpine") {
    return `var_os=alpine var_version=${version ?? "3.24"} bash -c "$(curl -fsSL ${scriptUrl})"`;
  }

  if (os && os !== "debian") {
    return `var_os=${os} var_version=${version ?? "13"} bash -c "$(curl -fsSL ${scriptUrl})"`;
  }

  return `bash -c "$(curl -fsSL ${scriptUrl})"`;
}

export function methodLabel(method: InstallMethod): string {
  if (method.type === "alpine") {
    return `Alpine ${method.resources.version ?? ""}`.trim();
  }
  const os = method.resources.os ?? "debian";
  const version = method.resources.version ?? "";
  return `${os.charAt(0).toUpperCase()}${os.slice(1)} ${version}`.trim();
}
