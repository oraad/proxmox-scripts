export type Script = {
  name: string;
  slug: string;
  categories: number[];
  date_created: string;
  type: "vm" | "ct" | "pve" | "addon" | "turnkey";
  updateable: boolean;
  privileged: boolean;
  interface_port: number | null;
  documentation: string | null;
  website: string | null;
  logo: string | null;
  config_path: string;
  description: string;
  install_methods: {
    type: "default" | "alpine";
    script: string;
    resources: {
      cpu: number | null;
      ram: number | null;
      hdd: number | null;
      os: string | null;
      version: string | null;
    };
  }[];
  default_credentials: {
    username: string | null;
    password: string | null;
  };
  notes: {
    text: string;
    type: "info" | "warning" | "error";
  }[];
};

export type Category = {
  name: string;
  id: number;
  sort_order: number;
  description: string;
  icon: string;
  scripts: Script[];
};
