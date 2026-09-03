import {
  Container,
  Home,
  Music,
  Network,
  Server,
  type LucideIcon,
} from "lucide-react";

const iconMap: Record<string, LucideIcon> = {
  server: Server,
  container: Container,
  network: Network,
  music: Music,
  home: Home,
};

export function CategoryIcon({
  icon,
  className,
}: {
  icon?: string;
  className?: string;
}) {
  const Icon = (icon && iconMap[icon]) || Server;
  return <Icon className={className} aria-hidden="true" />;
}

export function getCategoryIcon(icon?: string): LucideIcon {
  return (icon && iconMap[icon]) || Server;
}
