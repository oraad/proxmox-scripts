/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "export",
  basePath: "/proxmox-scripts",
  images: {
    unoptimized: true,
    remotePatterns: [
      {
        protocol: "https",
        hostname: "**",
      },
    ],
  },
  typescript: {
    ignoreBuildErrors: false,
  },
};

export default nextConfig;
