# 3-Node High-Availability K3s with Embedded etcd over WireGuard (and notes for providers with a native VLAN)

**Date researched:** 2026-09-18 · **Applies to:** K3s v1.28+ (all config validated against the current docs, updated Sep 18 2026)

This is a practical, research-backed setup guide for running a 3-node `server` (control-plane) K3s cluster with **embedded etcd** on cheap VPSes that either:

- **have no private networking** (RackNerd, Contabo, Netcup, most $5 VPSes) → we build a **WireGuard mesh** as the "fake LAN", or
- **have a native private VLAN** (OVH vRack / Public Cloud private networks, Hetzner Cloud network, Scaleway) → we use the **private interface directly**.

Everything (etcd Raft traffic, kubelet, Flannel VXLAN, kube-apiserver) should ride a *single private path*. The single most important lesson from years of k3s issues is:

> **Embedded etcd requires that all server nodes can reach each other over private (non-public) IPs.** k3s' embedded etcd will use the value of `--node-ip` for its client/peer URLs. Advertising or listening on public IPs for etcd is explicitly unsupported (k3s-io/k3s #3551, #2850, #5605, #8398). Giving the nodes some private/IP-internal address — WireGuard or a provider VLAN — is the fix.

---

## TL;DR decision table

| Decision | RackNerd / no private network (use WireGuard) | OVH vRack / native VLAN (no WireGuard) |
|---|---|---|
| `--node-ip` | WireGuard IP: `10.10.10.x` | vRack private IP: `10.0.1.x` |
| `--node-external-ip` | public IP (optional) | public IP (optional) |
| `--advertise-address` | WireGuard IP `10.10.10.x` | vRack private IP `10.0.1.x` |
| `--bind-address` | leave default `0.0.0.0` | leave default `0.0.0.0` |
| `--flannel-backend` | `vxlan` riding **over** `wg0` (recommended) — or `wireguard-native` without your own mesh | `vxlan` (or `host-gw` since vRack is L2) |
| `--flannel-iface` | `wg0` | the private NIC (`ens4`/`eth1`) |
| `--flannel-external-ip` | **no** (keeps pod traffic on the mesh) | **no** |
| `--tls-san` | kube-vip VIP + **all three public IPs** + DNS (required since `--tls-san-security` defaults to true on ≥1.28) | VIP + all public IPs + DNS |
| Join URL for nodes 2/3 | `--server https://10.10.10.1:6443` | `--server https://10.0.1.11:6443` |
| Control-plane endpoint | kube-vip VIP on `wg0` (`10.10.10.100`) or HAProxy+keepalived | kube-vip/keepalived on the vRack interface |
| etcd traffic | encrypted by the WireGuard mesh | private by the VLAN |
| Public ports | `22/tcp`, `6443/tcp`, `51820/udp` | `22/tcp`, `6443/tcp` (+ `80/443` if exposing ingress) |
| 2379/2380 exposure | **never public** — allowed only from `10.10.10.0/24` | **never public** — allowed only from vRack CIDR |

---

## 1. K3s HA topology with embedded etcd

Official doc: https://docs.k3s.io/datastore/ha-embedded

### The model

- **Three or more `server` nodes**, odd number. For n servers, etcd quorum is `(n/2)+1`, so 3 nodes tolerate 1 failure (quorum = 2).
- **etcd is embedded** in the `k3s server` process. k3s manages membership, certs, defrag, compaction, and snapshots itself — you never run `etcd` as a separate service.
- The **first** server starts the cluster with `--cluster-init` (this is what swaps SQLite for embedded etcd).
- Servers **2 and 3** join with `--server https://<server-1>:6443` using the same `--token`/`K3S_TOKEN`.
- Node roles show as `control-plane,etcd,master` on all three.
- All three are equal peers. Writes go through Raft (2-of-3 must ack). Lose one node → two remain → full operation. Lose two → reads still work but the API can't accept changes.

### Exact bootstrap

```bash
# Server 1 — initialize:
curl -sfL https://get.k3s.io | K3S_TOKEN=<STRONG_TOKEN> sh -s - server \
  --cluster-init --tls-san=<FIXED_IP_OR_VIP>

# Servers 2 and 3 — join:
curl -sfL https://get.k3s.io | K3S_TOKEN=<STRONG_TOKEN> sh -s - server \
  --server https://<ip-or-hostname-of-server1>:6443 --tls-san=<FIXED_IP_OR_VIP>
```

Verify:

```bash
kubectl get nodes
# NAME     STATUS   ROLES                       AGE   VERSION
# server1  Ready    control-plane,etcd,master  28m   v1.32.x
# server2  Ready    control-plane,etcd,master  13m   v1.32.x
# server3  Ready    control-plane,etcd,master  10m   v1.32.x
```

### Flags that must be identical on all servers

Per https://docs.k3s.io/datastore/ha-embedded:

- Networking: `--cluster-dns`, `--cluster-domain`, `--cluster-cidr`, `--service-cidr`
- `--disable-helm-controller`, `--disable-kube-proxy`, `--disable-network-policy`, anything in `--disable`
- `--secrets-encryption`

Other notes:

- If a node already has a datastore on disk (`/var/lib/rancher/k3s/server/db`), the datastore args (`--cluster-init`, `--server`, ...) are **ignored** — it keeps its existing role. A single-node SQLite cluster can be converted to etcd by restarting with `--cluster-init`.
- Hostnames must be **unique** across nodes.

---

## 2. Which addresses to use for what (the flags that matter)

Reference: `k3s server --help` — https://docs.k3s.io/cli/server and the community discussion that clarifies each flag: https://github.com/k3s-io/k3s/discussions/9888

### Per-flag job description

| Flag | What it actually controls | On WireGuard mesh | On OVH vRack |
|---|---|---|---|
| `--node-ip` | The node's **private/internal IP**. This is what kubelet binds, what the **embedded etcd client/peer URLs** use, and what other nodes dial to reach this node. | WG IP `10.10.10.x` | vRack private IP |
| `--advertise-address` | The IP that **kube-apiserver advertises** to the rest of the cluster (its service endpoint). Defaults to node-external-ip/node-ip. | WG IP `10.10.10.x` | private IP |
| `--node-external-ip` | The public IP, for 1:1-NAT/public-VPS situations. Used for ServiceLB/loadbalancer advertising *to the outside*. **Optional** in a mesh setup. | public IP (optional) | public IP (optional) |
| `--bind-address` | What address the k3s **listener** binds to. Default `0.0.0.0` is fine — you'll firewall externally. | leave default | leave default |
| `--flannel-backend` | `vxlan` (default), `wireguard-native`, `host-gw`, or `none`. | `vxlan` over `wg0` (see below) | `vxlan` (or `host-gw`, vRack is L2) |
| `--flannel-iface` | The interface Flannel **binds** for overlay traffic (both source and expected destination). k3s also uses this to pick the interface etcd binds. | `wg0` | private NIC |
| `--flannel-external-ip` | Makes Flannel target nodes' **external** IPs instead of private ones. Only for the "distributed / no common private net" mode. | no | no |
| `--tls-san` | Extra SANs on the auto-generated API-server certificate. **Since K3s ≥1.28 (`--tls-san-security` defaults to true), public IPs / VIPs / DNS names are NO LONGER auto-added — you must list them explicitly.** | VIP + all 3 public IPs + DNS | VIP + all publics + DNS |

### Two valid "encryption" approaches on a bare VPS — pick one

1. **External WireGuard mesh + Flannel VXLAN over it (RECOMMENDED).**
   You build `wg0` yourself (Section 4). Set `--flannel-iface=wg0 --flannel-backend=vxlan`. The mesh encrypts **everything** — etcd, kubelet, apiserver, flannel — and you get one encryption layer. Pod MTU becomes 1420 (wg0) − 50 (VXLAN) = **1370**.
2. **No external WireGuard; `--flannel-backend=wireguard-native`.**
   Flannel creates its own `flannel-wg` interface and encrypts only **pod-to-pod** traffic. It does **not** protect etcd/kubelet traffic (which would go over the public NICs). Also, that path is really the "distributed/multicloud" mode that pairs with `--node-external-ip` + `--flannel-external-ip`, and it does **not** give you a private network for embedded etcd — which is why for a 3-node **etcd** cluster the externally-meshed option is the right one.

Do **not** do both (double WireGuard = wasted CPU + MTU pain).

### kubeconfig & TLS

- The kubeconfig written on the server (`/etc/rancher/k3s/k3s.yaml`) points at `https://127.0.0.1:6443`. For remote use, rewrite `server:` to the VIP or a public IP **listed in `--tls-san`**.
- Example cert check:

```bash
openssl s_client -connect k3s.example.com:6443 -servername k3s.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A5 "Subject Alternative"
```

- If you forgot a SAN, you can add it with a `config.yaml.d` drop-in (`tls-san+:` additive merge) and run `k3s certificate rotate` (stop k3s → rotate → start), or add a new VIP before install. The cleanest is: **decide your VIP and public IPs before the first install and put them all in `--tls-san` from the start** (the SAN list is effectively baked into the cert at install time).

---

## 3. Stable server address — how do clients/agents reach the API?

Key insight from k3s (https://docs.k3s.io/architecture, and maintainer comments in k3s-io/k3s#7325):

- **Inside the cluster** agents don't need your load balancer at all. After the first registration the k3s agent's built-in *client-side load balancer* syncs a list of actual `kube-apiserver` endpoints from the in-cluster `default/kubernetes` service (local port 6444 by default, `--lb-server-port`) and fails over between them by itself. `--server` is only the seed used at join time.
- **For kubectl / external API access** you need *something* stable, because plain kubectl has no built-in failover and will happily keep pointing at a dead node.

Options for the "fixed registration address" / kubeconfig endpoint (from https://docs.k3s.io/datastore/cluster-loadbalancer):

| Approach | Failure behavior | Verdict on 3×$5 VPS |
|---|---|---|
| kubeconfig → a single node's IP | Single point of failure for management | dev only |
| **kube-vip** (L2/ARP VIP) | VIP floats to healthy node via Lease-based leader election (k8s-native, no multicast needed) | **Recommended — simplest** |
| HAProxy + keepalived (VRRP) | VIP floats via VRRP; HAProxy health-checks 6443 | battle-tested alternative |
| DNS round-robin over 3 A-records | TTL-bound failover; Go's http client sticks to the first returned address | OK to seed node joins; weak for kubectl HA |
| Cloudflare Tunnel / SSH tunnel to 6443 | Extra hop, but hides the API port entirely | good combo with any of the above |

**Recommended pattern (3×$5 VPS, WireGuard):** put a **kube-vip VIP on `wg0`** (e.g. `10.10.10.100`), pass it to `--tls-san` on every node, and point kubeconfig at `https://10.10.10.100:6443`. Connect your laptop to the WG mesh to use kubectl. Optionally front 6443 for the internet via Cloudflare Tunnel or a firewall-restricted public IP — but the mesh keeps the API off the public internet entirely, which is the security win you're paying for.

MetalLB is for **in-cluster `LoadBalancer` Services** (Traefik, Longhorn, apps), not for the control plane. Use kube-vip for the API VIP *and* MetalLB (or kube-vip `--services` / k3s ServiceLB) for app services. Never enable both kube-vip `--services` and MetalLB on overlapping IP ranges (ARP conflict). Exact setup in Section 7.

---

## 4. WireGuard HOW-TO (Ubuntu/Debian 22.04 / 24.04)

Install on **all three nodes**:

```bash
sudo apt update && sudo apt install -y wireguard
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-wireguard.conf
```

Generate keypairs **on each node** (keep each node's private key on that node):

```bash
umask 077
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
cat /etc/wireguard/publickey   # note it down for the other peers; private key stays secret
```

### Topology: full mesh (recommended) vs hub-and-spoke

- **Full mesh (recommended for 3 VPS with public IPs):** every node peers directly with the other two. Lowest latency — which matters for etcd Raft round-trips — and no single point of failure.
- **Hub-and-spoke:** only needed when spokes are behind NAT and can't open UDP 51820. All spoke-to-spoke traffic detours through the hub, doubling etcd RTT on one leg and making the hub a failure point. Avoid on public-IP VPSes.

### MTU: subtract 80 for WireGuard over Ethernet

WireGuard encapsulation on an IPv4 underlay adds ~60–80 bytes (IP 20 + UDP 8 + WG data message/tag 32 → common budget 80). So:

- Ethernet MTU 1500 → **wg0 MTU 1420**.
- If your provider caps MTU (e.g. 1450/1400, PPPoE 1492, cloud overlays), drop accordingly (underlay − 80).
- Downstream: Flannel **VXLAN** on top of wg0 gets −50 → pod MTU **1370**. Flannel's `wireguard-native` backend sets `flannel-wg` = iface − 80 → **1420**.

Always set `MTU = 1420` in `[Interface]`. Symptom of getting it wrong: small pings/ssh work but large transfers stall and `dmesg` shows "message too long".

### `/etc/wireguard/wg0.conf` for the 3-node mesh

Node IPs used throughout this guide:

| Node | Public IP | wg0 IP |
|---|---|---|
| k3s-01 | `198.51.100.11` | `10.10.10.1` |
| k3s-02 | `198.51.100.12` | `10.10.10.2` |
| k3s-03 | `198.51.100.13` | `10.10.10.3` |
| kube-vip API | — | `10.10.10.100` (VIP) |

**`/etc/wireguard/wg0.conf` on k3s-01** (use `AllowedIPs = 10.10.10.0/24` so the VIP is routable too):

```ini
[Interface]
Address = 10.10.10.1/24
ListenPort = 51820
PrivateKey = <PRIVATE_KEY_NODE_1>
MTU = 1420

# Peer: k3s-02
[Peer]
PublicKey = <PUBLIC_KEY_NODE_2>
AllowedIPs = 10.10.10.0/24
Endpoint = 198.51.100.12:51820

# Peer: k3s-03
[Peer]
PublicKey = <PUBLIC_KEY_NODE_3>
AllowedIPs = 10.10.10.0/24
Endpoint = 198.51.100.13:51820
```

**`/etc/wireguard/wg0.conf` on k3s-02:**

```ini
[Interface]
Address = 10.10.10.2/24
ListenPort = 51820
PrivateKey = <PRIVATE_KEY_NODE_2>
MTU = 1420

# Peer: k3s-01
[Peer]
PublicKey = <PUBLIC_KEY_NODE_1>
AllowedIPs = 10.10.10.0/24
Endpoint = 198.51.100.11:51820

# Peer: k3s-03
[Peer]
PublicKey = <PUBLIC_KEY_NODE_3>
AllowedIPs = 10.10.10.0/24
Endpoint = 198.51.100.13:51820
```

**`/etc/wireguard/wg0.conf` on k3s-03** — same shape, own `Address = 10.10.10.3/24`, peers 1 and 2.

Notes:

- No `PersistentKeepalive` needed — all endpoints are static public IPs. Add `PersistentKeepalive = 25` only if a peer is behind NAT.
- Full `AllowedIPs = 10.10.10.0/24` keeps the kube-vip VIP (`10.10.10.100`) routable to every peer and is simpler to reason about on a dedicated mesh. (You can tighten to `/32`s + `10.10.10.100/32` later.)
- chmod: `sudo chmod 600 /etc/wireguard/*` (the private key is in the file).

Start and enable:

```bash
sudo systemctl enable --now wg-quick@wg0
sudo wg show
ping -c3 10.10.10.2 && ping -c3 10.10.10.3
```

### Firewall for WireGuard (UDP 51820)

```bash
sudo ufw allow 51820/udp    # WireGuard handshake + data — must be reachable on the public IP
```

(Or nftables, see Section 5.)

---

## 5. Ports and firewall

From https://docs.k3s.io/installation/requirements (Inbound Rules table):

| Port | Proto | Between | Why | Exposure |
|---|---|---|---|---|
| **6443** | TCP | Agents ↔ Servers, external kubectl | K3s supervisor + Kubernetes API | **public** (or via tunnel) |
| **9345** | TCP | Nodes → servers | supervisor/registration (only in some layouts/versions; not on the official requirement page) | private |
| **2379–2380** | TCP | Servers ↔ Servers | embedded etcd client (2379) + peer (2380) | **private only** (WG / VLAN) |
| **8472** | UDP | All nodes | Flannel **VXLAN** overlay | **private only** — never expose |
| **51820** | UDP | All nodes | Flannel WireGuard backend *or* your own WG mesh | public (that's the mesh listener) |
| **51821** | UDP | All nodes | Flannel WireGuard with IPv6 | public (IPv6 only) |
| **10250** | TCP | All nodes | kubelet metrics/API | **private** (or restricted) |
| **5001** | TCP | All nodes | embedded registry (Spegel, newer k3s) | private |

### UFW example (Recommended for the WireGuard setup)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp                # API — optionally: ufw allow from <your-ip> to any port 6443 proto tcp
sudo ufw allow 51820/udp               # WireGuard mesh (public listener)
sudo ufw allow from 10.10.10.0/24      # all mesh traffic: etcd 2379/2380, kubelet 10250, VXLAN 8472, spegel 5001
sudo ufw allow from 10.42.0.0/16       # pod CIDR
sudo ufw allow from 10.43.0.0/16       # service CIDR
sudo ufw enable
```

The `from 10.10.10.0/24` line is what keeps 2379/2380, 8472 and 10250 **off the public internet** while fully open inside the mesh.

### nftables alternative

```nftables
table inet filter {
  chain input {
    type filter hook input priority filter; policy drop
    ct state established,related accept
    iif "lo" accept
    iifname "wg0" accept                      # everything from the mesh
    ip saddr { 10.42.0.0/16, 10.43.0.0/16 } accept
    tcp dport { 22, 6443 } accept
    udp dport 51820 accept
  }
}
```

### OVH vRack specifics

- vRack has **no security groups** — each host's local firewall is your only control; use the same rules but with `from 10.0.1.0/24` (your vRack subnet) instead of `10.10.10.0/24`.
- Avoid OVH reserved ranges that collide with its managed-k8s overlays: `10.2.0.0/16`, `10.3.0.0/16`, `172.17.0.0/16`. Keep k3s defaults `10.42.0.0/16` / `10.43.0.0/16`, which do not overlap.
- Identify your private NIC: `ip -4 -br addr` (typically a second interface like `ens4`/`eth1`). Point `--flannel-iface` at it.

---

## 6. etcd performance, snapshots, and the public-IP trap

### Disk

etcd is a **write-ahead-log consensus store**; its stability is bounded by *fsync latency*, not raw throughput.

- Minimum: 50 sequential 8K IOPS with `fdatasync` < 10 ms (a 7200 RPM disk).
- Recommended for loaded clusters: **~500 sequential IOPS, fsync p99 < 2 ms** — i.e. a decent local NVMe. SSD min, **NVMe preferred**; avoid SD/eMMC and any network/block shares (iSCSI, NFS-backed volumes) for `/var/lib/rancher/k3s`.
- k3s docs: "etcd is write intensive; SD cards and eMMC cannot handle the IO load." (https://docs.k3s.io/installation/requirements)

Benchmark before deploying:

```bash
sudo fio --name=fsynctest --ioengine=sync --rw=write --bs=8k --size=512M \
  --directory=/var/lib/rancher/k3s --fsync_on_close=1 --time_based --runtime=60 --group_reporting
# then inspect fsync/fdatasync percentiles; p99 must be <10ms, ideally <2ms
```

Watch these etcd metrics (Prometheus): `etcd_disk_wal_fsync_duration_seconds`, `etcd_disk_backend_commit_duration_seconds`, `etcd_network_peer_round_trip_time_seconds` (keep p99 RTT < 50 ms).

### Latency / placement

- Keep all three server nodes **in the same region/provider**. etcd Raft writes require a quorum round-trip; k3s already raises the heartbeat to 500 ms and election timeout to 5 s, but cross-datacenter / cross-provider RTT is the classic cause of flapping leader elections.
- "Deploy etcd members within a single data center when possible" — etcd hardware guide (https://etcd.io/docs/latest/op-guide/hardware/).
- WireGuard adds a few ms; fine within the same DC. Keep `RTT < 50 ms` between any pair.

### Storage quota & compaction

- k3s default etcd quota is **2 GB** (`quota-backend-bytes`). k3s auto-compacts every 5 minutes; run `defrag` during maintenance windows if the DB balloons.
- Check size: `/var/lib/rancher/k3s/server/db/etcd/member/snap/` and the metric `etcd_mvcc_db_total_size_in_bytes`.

### Snapshots (enable + tighten)

k3s already takes scheduled embedded-etcd snapshots; set your own cadence in `/etc/rancher/k3s/config.yaml.d/90-etcd-snapshots.yaml` on each server:

```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: "10"
etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots
```

Off-node backup (S3-compatible) in the same file:

```yaml
etcd-s3: true
etcd-s3-endpoint: s3.eu-west-3.amazonaws.com
etcd-s3-bucket: my-cluster-etcd
etcd-s3-folder: k3s
etcd-s3-region: eu-west-3
etcd-s3-access-key: <AK>
etcd-s3-secret-key: <SK>
```

Manual ops:

```bash
sudo k3s etcd-snapshot save           # one-off
sudo k3s etcd-snapshot list
sudo k3s etcd-snapshot delete --name <snapshot>
```

**Restore caveat:** you must restore/pass the same `--token` (it encrypts data inside the snapshot). Take a snapshot before every upgrade; upgrade one server at a time.

### The k3s "advertised public IP" trap (k3s-io/k3s #3551 and friends)

- **#3551 "etcd is advertising public instead of private IP"** (https://github.com/k3s-io/k3s/issues/3551): second/third servers failed to join because the embedded etcd peer/clien URLs used public IPs, which firewalls correctly block.
- Related: #2850 (etcd cannot bootstrap through NAT), #5605 (etcd expects a private LAN), #8398 + PR #8001 (feature request to listen on public IPs was **decided against** — embedded etcd stays private-only), #2965 (embedded etcd ignores `--advertise-address` for its own listeners; it keys off `node-ip`).

The maintainer-consolidated guidance:

1. Set `--node-ip` to the **private** address you want everything to use (WG IP or vRack IP) — this overrides the default "interface with the default route" selection.
2. Set `--flannel-iface` to the matching interface (this also steers where the embedded etcd listener binds).
3. Don't rely on public IPs for etcd. The WireGuard mesh / chosen private VLAN is exactly the supported shape: servers reach each other on private IPs, low latency, firewallable.

---

## 7. Control-plane load balancer on 3 × $5 VPS — exact steps

Choose **one** Control-plane endpoint mechanism. MetalLB is *only* for in-cluster services — it is a poor fit for the kube-apiserver.

### Option A — kube-vip (recommended, simplest)

kube-vip in L2/ARP mode is a DaemonSet; it uses k8s **Lease** leader election and gratuitous ARP — no VRRP multicast, so it works cleanly over WireGuard. It binds the VIP to `wg0`.

1. **Include the VIP in `--tls-san` on every node from the start** (see Section 2) — the VIP is baked into the API cert at install time.
2. Add RBAC:

   ```bash
   kubectl apply -f https://kube-vip.io/manifests/rbac.yaml
   ```

3. Generate the DaemonSet manifest (run once from a container, then `kubectl apply -f`):

   ```bash
   docker run --network host --rm ghcr.io/kube-vip/kube-vip:v1.0.4 \
     manifest daemonset \
     --interface wg0 \
     --address 10.10.10.100 \
     --controlplane \
     --services \
     --arp \
     --leaderElection > /tmp/kube-vip.yaml
   ```

   > For control-plane-only, drop `--services` (then use MetalLB or k3s ServiceLB for app Services). Never run kube-vip `--services` **and** MetalLB on overlapping IP pools.

   Adjust `--interface` to `wg0` for the WireGuard mesh, or to your vRack NIC on OVH. `kubectl apply -f /tmp/kube-vip.yaml`.

4. Verify:

   ```bash
   kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-vip
   ip neigh show | grep 10.10.10.100
   kubectl --server https://10.10.10.100:6443 get nodes
   ```

5. Point kubeconfig at the VIP. Your kubectl client must be able to route to `10.10.10.0/24` (join the mesh from your laptop by adding a `[Peer]` for your laptop with its own `10.10.10.254` — turn on `PersistentKeepalive = 25` on your side).

**Caveats:** if you add the VIP *after* install, do `systemctl stop k3s && k3s certificate rotate && systemctl start k3s` after adding it via a `tls-san+` drop-in. In ARP mode the VIP is reachable only where ARP reaches it (the WG mesh / the connected LAN), so in-mesh kubectl and in-cluster clients use it, but internet clients still need a tunnel or public-IP access — which is what you want on a budget VPS.

### Option B — HAProxy + keepalived (classic, still documented by k3s)

Install on **all three server nodes**:

```bash
sudo apt install -y haproxy keepalived
```

`/etc/haproxy/haproxy.cfg` (same on all nodes):

```
frontend k3s-frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend k3s-backend

backend k3s-backend
    mode tcp
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s
    server k3s-01 10.10.10.1:6443 check
    server k3s-02 10.10.10.2:6443 check
    server k3s-03 10.10.10.3:6443 check
```

`/etc/keepalived/keepalived.conf` — use **unicast** VRRP (WireGuard is point-to-point; unicast is more reliable than multicast here):

k3s-01 (MASTER):

```
global_defs {
  enable_script_security
  script_user root
}
vrrp_script chk_haproxy {
  script 'killall -0 haproxy'
  interval 2
}
vrrp_instance haproxy-vip {
  state MASTER
  interface wg0
  virtual_router_id 51
  priority 200
  advert_int 1
  unicast_src_ip 10.10.10.1
  unicast_peer {
    10.10.10.2
    10.10.10.3
  }
  virtual_ipaddress {
    10.10.10.100/24
  }
  track_script {
    chk_haproxy
  }
}
```

k3s-02 / k3s-03: `state BACKUP`, `priority 150` / `priority 100`, `unicast_src_ip 10.10.10.2` / `10.10.10.3`.

Then:

```bash
sudo systemctl enable --now haproxy keepalived
```

Verify from a mesh-connected host: `curl -k https://10.10.10.100:6443/version`.

### Option C — just DNS (fine for join seeding)

Point a DNS name at all three public IPs and pass `--tls-san <that-name>` on every server. k3s agents seed their client-side LB with the `--server` URL; joins work as long as *one* server answers. Not a substitute for a real kubeconfig endpoint with HA.

### MetalLB — services only

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/main/config/manifests/metallb-native.yaml
# configure an IPAddressPool + L2Advertisement for e.g. 10.10.10.200-10.10.10.249 (mesh) — never overlapping the kube-vip VIP
```

Use it so Traefik/Longhorn get stable IPs; keep the Control-plane VIP on kube-vip.

---

## 8. Canonical config cheat-sheets

### A. RackNerd-style nodes over WireGuard — `/etc/rancher/k3s/config.yaml`

**k3s-01:**

```yaml
token: <STRONG_TOKEN>
cluster-init: true
tls-san:
  - 10.10.10.100      # kube-vip VIP (must match Section 7)
  - 10.10.10.1
  - 198.51.100.11     # this node's public IP
  - k3s.example.com   # optional DNS
node-ip: 10.10.10.1
node-external-ip: 198.51.100.11   # optional
advertise-address: 10.10.10.1
flannel-backend: vxlan
flannel-iface: wg0
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: "10"
write-kubeconfig-mode: "0644"
```

**k3s-02 / k3s-03** (join; only `node-ip`, `node-external-ip`, `advertise-address`, `tls-san` change):

```yaml
token: <STRONG_TOKEN>
server: https://10.10.10.1:6443
tls-san:
  - 10.10.10.100
  - 10.10.10.2       # node's own WG IP on k3s-02 (10.10.10.3 on k3s-03)
  - 198.51.100.12    # node's own public IP
node-ip: 10.10.10.2
node-external-ip: 198.51.100.12
advertise-address: 10.10.10.2
flannel-backend: vxlan
flannel-iface: wg0
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: "10"
write-kubeconfig-mode: "0644"
```

Install with:

```bash
sudo mkdir -p /etc/rancher/k3s
# write /etc/rancher/k3s/config.yaml, then:
curl -sfL https://get.k3s.io | sh -s - server
```

(On a server that already has a datastore, `cluster-init`/`server` are ignored — if you make a mistake, run `/usr/local/bin/k3s-uninstall.sh` and start again.)

### B. OVH vRack — `/etc/rancher/k3s/config.yaml`

Same shape, but private IPs from the vRack (say `10.0.1.0/24`, NIC `ens4`) and no WireGuard:

```yaml
token: <STRONG_TOKEN>
cluster-init: true          # only on node 1
node-ip: 10.0.1.11          # 10.0.1.12 / .13 on the others
advertise-address: 10.0.1.11
flannel-backend: vxlan
flannel-iface: ens4         # your vRack NIC
tls-san:
  - 10.10.10.100            # kube-vip VIP on the vRack interface (or keepalived VIP)
  - <your-public-IP>
  - k3s.example.com
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: "10"
```

Nodes 2/3: add `server: https://10.0.1.11:6443`. Keep public ports to `22`, `6443` (+80/443 for ingress); allow `10.0.1.0/24`, `10.42.0.0/16`, `10.43.0.0/16` from the private side.

### C. systemd/env-var style (equivalent alternative)

Prefer `config.yaml`; if you use env vars set them in a systemd drop-in `/etc/systemd/system/k3s.service.d/10-addr.conf`:

```ini
[Service]
Environment="K3S_TOKEN=<STRONG_TOKEN>"
Environment="K3S_NODE_IP=10.10.10.1"
Environment="K3S_URL=https://10.10.10.1:6443"   # join nodes only
# then keep --cluster-init / flannel / tls-san as CLI args in ExecStart
```

`config.yaml` is easier to audit; pick one style per node.

---

## 9. Go-live checklist

1. All three nodes: WireGuard up (`wg show` shows peers & handshakes), `ping` across the mesh < a few ms.
2. Unique hostnames, NTP/chrony synced, no `firewalld`, UFW rules as in Section 5.
3. Node 1 installed with `server: ...`/`cluster-init: true`, full `tls-san` (VIP + publics), expected roles `control-plane,etcd,master`.
4. Nodes 2–3 join via `--server https://<node1-private-IP>:6443`; all three `Ready`.
5. `kubectl get nodes -o wide` shows WG/vRack IPs as `INTERNAL-IP`; pod-to-pod ping across nodes works.
6. etcd healthy: install `etcdctl`, then:

   ```bash
   MY_ETCD_ENDPOINTS=https://127.0.0.1:2379
   etcdctl --endpoints=$MY_ETCD_ENDPOINTS \
     --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
     --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
     --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
     member list
   ```

7. kube-vip / HAProxy-VIP answers `curl -k https://10.10.10.100:6443/version`; kubeconfig uses the VIP.
8. Kill a node; `kubectl get nodes` from the VIP still works; etcd keeps quorum on the other two.

---

## 10. Sources

Official k3s docs (checked 2026-09-18):

- HA embedded etcd: https://docs.k3s.io/datastore/ha-embedded
- Backup & restore: https://docs.k3s.io/datastore/backup-restore
- External cluster load balancer (HAProxy, kube-vip examples): https://docs.k3s.io/datastore/cluster-loadbalancer
- Requirements / ports table / disks: https://docs.k3s.io/installation/requirements
- Server CLI (all flags above): https://docs.k3s.io/cli/server
- Agent CLI / `--lb-server-port`: https://docs.k3s.io/cli/agent
- Basic network options (flannel backends): https://docs.k3s.io/networking/basic-network-options
- Distributed / multicloud mode (`--flannel-external-ip`, `wireguard-native`): https://docs.k3s.io/networking/distributed-multicloud
- Architecture (agent client-side load balancer): https://docs.k3s.io/architecture

GitHub issues / discussions:

- **etcd advertising public IP**: https://github.com/k3s-io/k3s/issues/3551
- etcd behind NAT: https://github.com/k3s-io/k3s/issues/2850
- etcd multi-network: https://github.com/k3s-io/k3s/issues/5605
- etcd `--advertise-address` ignored: https://github.com/k3s-io/k3s/issues/2965
- etcd on public IPs feature request (closed, "decided against"): https://github.com/k3s-io/k3s/issues/8398
- Multiple server addresses for `--server` / LB: https://github.com/k3s-io/k3s/issues/7325
- `--node-ip` vs `--node-external-ip` vs `--flannel-iface`: https://github.com/k3s-io/k3s/discussions/9888
- K3s flannel MTU behaviour over WireGuard: https://github.com/k3s-io/k3s/discussions/9315
- TLS SAN stuffing CVEG-2023-32187 / `--tls-san-security`: https://notcve.org/cve/CVE-2023-32187

etcd operational guidance:

- Hardware recommendations (IOPS, fsync latency, single-DC): https://etcd.io/docs/latest/op-guide/hardware/
- Performance: https://etcd.io/docs/latest/op-guide/performance/
- OKD etcd practices (50/500 IOPS, <50ms RTT, fsync p99 <10ms, metrics): https://docs.okd.io/latest/etcd/etcd-practices.html

Community tutorials used to cross-check the WireGuard patterns:

- dataforest "Setting Up a Kubernetes Cluster with k3s" (VXLAN-over-WG mesh, ports, flags): https://cloud.dataforest.net/en/guides/kubernetes-cluster-setup
- "Setup K3s Multi-Master HA Cluster with WireGuard" (hub-and-spoke variant): https://www.thinhhv.com/blog/setup-k3s-multi-master-cluster-with-wireguard
- raiun.de "k3s on VPS" (flag matrix): https://raiun.de/posts/k3s/
- Terraform provider `k3s-vps-wg` (wireguard mtu 1420 design): https://github.com/igorovh/terraform-provider-k3s-vps-wg
- Taegost: kube-vip for k3s control plane (VIP must be in `--tls-san`; kube-vip vs MetalLB): https://taegost.com/2026/06/kube-vip-for-k3s-homelab-control-plane-ha-with-a-virtual-ip/
- OneUptime: k3s etcd maintenance + TLS SAN config: https://oneuptime.com/blog/post/2026-02-02-k3s-etcd-maintenance/view and https://oneuptime.com/blog/post/2026-03-20-k3s-tls-san/view

OVH vRack references:

- vRack + Kubernetes overview / reserved subnets: https://docs.ovhcloud.com/en/guides/public-cloud/containers-orchestration/managed-kubernetes/using-vrack
- Configuring vRack for Public Cloud: https://support.us.ovhcloud.com/hc/en-us/articles/360002093130-Configuring-vRack-for-Public-Cloud