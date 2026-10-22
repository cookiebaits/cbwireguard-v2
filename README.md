# 🍪 Cookie's Easy WireGuard VPS Stealth Server & Web Manager

> A hyper-optimized WireGuard VPN server and real-time web management console engineered for personal VPS deployments (Ubuntu 20.04/22.04/24.04 LTS & Debian 11/12).
> Designed to make personal VPS traffic **indistinguishable from standard residential desktop browsing** while unblocking strict streaming, banking, and AI services without proxy overhead.

---

## 🚀 Quick VPS Installation

Run this single command in your VPS root terminal to auto-detect your server's public IP, configure stealth kernel modules, assign non-default ports, and deploy the live web console:

### 1️⃣ Curl One-Liner (`easy_wireguard.sh`):
```bash
curl -sSfL https://raw.githubusercontent.com/cookiebaits/cbwireguard-v2/main/easy_wireguard.sh -o easy_wireguard.sh && chmod +x easy_wireguard.sh && sudo ./easy_wireguard.sh
```

### 2️⃣ Wget One-Liner:
```bash
wget -O easy_wireguard.sh https://raw.githubusercontent.com/cookiebaits/cbwireguard-v2/main/easy_wireguard.sh && chmod +x easy_wireguard.sh && sudo ./easy_wireguard.sh
```

During installation, the script automatically:
1. Auto-detects your VPS **`SERVER_PUBLIC_IP`** using public IP lookup services.
2. Prompts for your preferred WireGuard listen port (**`WG_DEFAULT_PORT`**, defaults to **4500** for IPsec cloaking or non-sensitive stealth ports).
3. Assigns a unique, non-default internal Web Management Console port (**`WEB_PORT`**, options include **51821**, **54321**, **51830**, or random high ports).
4. Auto-generates a Master Security Passkey saved securely in `/etc/wireguard/admin.key`.
5. Injects kernel-level TTL=64 normalization, TCP MSS clamping, Google BBR congestion control, and IPv6 leak shields.
6. Auto-creates your first peer, renders a high-fidelity terminal QR code for mobile setup, and prints your management URL.

---

## 🌐 Simple Internal Web Management Console

The web console is hosted directly on your VPS on a dedicated internal management port (e.g., `51821` or chosen port).

### 📱 Accessing the Management Website from Terminal Output

At the end of `./easy_wireguard.sh`, your terminal explicitly outputs your simple internal URL:

```text
=================================================================
🌐 WIREGUARD INTERNAL WEB MANAGEMENT CONSOLE
=================================================================
  Internal Tunnel URL (Requires Active WireGuard Connection):
    👉 http://10.18.0.1:51821
  Master Security Passkey (For admin access):
    🔑 <ADMIN_PASSKEY>
=================================================================
```

### 🔒 Simple Internal Access Control
- **WireGuard Internal Subnet (`10.18.0.0/24`)**: Direct access is open when connected to your WireGuard tunnel (`http://10.18.0.1:51821`).
- **Master Passkey Backup**: If accessing from outside the tunnel, enter the **Master Security Passkey** in the Security Gatekeeper modal to authorize your session.
- **Zero Demo Data**: The dashboard pulls actual live kernel data (`wg show wg0 dump`) directly from your WireGuard interface.
- **Zero Plain-Text Credentials**: Sensitive private and preshared keys are masked in API responses and UI fields (`••••••••••••••••••••••••••••••••`). Backups are AES-256 encrypted using OpenSSL PBKDF2.

---

## 🛡️ VPS Stealth & Traffic Unblocking Architecture

Standard WireGuard deployments on personal VPS hosts frequently trigger anti-fraud, banking, or streaming blocks due to datacenter IP signatures. Cookie's WireGuard addresses this natively at the Linux kernel level:

| Stealth Layer | Problem Solved | Linux Kernel Implementation |
|---|---|---|
| **TTL Hop Normalization** | Conceals VPS proxy hops. Prevents banks & streaming sites from detecting intermediate NAT routers. | `iptables -t mangle -A POSTROUTING -o eth0 -j TTL --ttl-set 64` |
| **TCP MSS Clamping (PMTU 1420)** | Eliminates TLS ClientHello fragmentation with DF flags that stall HTTPS connections and trigger DPI. | `iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` |
| **PLPMTUD Probing** | Dynamically probes Path MTU across restrictive mobile carriers and hotel Wi-Fi networks. | `net.ipv4.tcp_mtu_probing = 1` |
| **HTTP/3 QUIC Port Cloaking** | Runs over UDP 443, making WireGuard traffic look like standard Google/Cloudflare web video streams. | Configurable `ListenPort = 443` or randomized high ports |
| **WebRTC & IPv6 Leak Blackhole** | Stops modern browsers (Chrome/Safari) from leaking origin IPv6 addresses via WebRTC STUN queries. | `AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1` |
| **Google BBR + FQ Pacing** | Eliminates datacenter bufferbloat and latency spikes, delivering smooth residential-like throughput. | `net.core.default_qdisc = fq` & `net.ipv4.tcp_congestion_control = bbr` |
| **TOS / DSCP DPI Camouflage** | Clears non-standard Type of Service bits, removing unique WireGuard packet markers. | `iptables -t mangle -A POSTROUTING -j TOS --set-tos 0x00` |
| **Domain Split-Tunneling** | Routes Netflix, Disney+, Hulu, Chase, and OpenAI around datacenter ASN blocks directly. | Pre-configured subnet CIDR routing tables |
| **Cloudflare Anti-Flag (170 CIDRs)** | Routes standard web traffic via VPS while routing all 15 Cloudflare edge CIDRs via local residential ISP. | Mathematically exact 170-CIDR complement in `AllowedIPs` |
| **Cloudflare WARP Egress (AS13335)** | Conceals VPS datacenter ASN under Cloudflare's own consumer edge network, eliminating Turnstile captcha loops. | `warp-cli` / `wgcf` upstream routing |
| **Transparent DNS Redundancy** | Auto-redirects internal DNS queries to Cloudflare Anycast (1.1.1.1:53) to guarantee zero client connection stalls. | `iptables -t nat -A PREROUTING -p udp --dport 53 -j DNAT --to 1.1.1.1:53` |

---

## ☁️ Cloudflare Anti-Flag & Turnstile Zero-Challenge Engine

Cloudflare Turnstile and Bot Management inspect incoming traffic for datacenter IP ASNs (DigitalOcean, AWS, Hetzner, Vultr, OVH) and mismatched TCP packet signatures. This causes frequent 403 Forbidden Ray ID errors and infinite captcha loops.

Cookie's WireGuard solves this with dual anti-flag paths:

1. **Client-Side Residential Split Profile (`<device>-cloudflare-shield.conf`)**:
   - Uses a mathematically complete **170-CIDR complement** that covers all 4.29 billion IPv4 addresses EXCEPT the 15 official Cloudflare IPv4 ranges (AS13335).
   - Encrypts 100% of standard web traffic through WireGuard VPS.
   - Cloudflare-protected sites and Turnstile challenges resolve and connect directly via your client device's native home/mobile ISP, entirely bypassing datacenter ASN filters with zero captcha challenges!
2. **Server-Side Cloudflare WARP Upstream Egress (`AS13335`)**:
   - For full-tunnel setups, routes outbound packets through Cloudflare's internal edge network (`warp=on`), presenting Cloudflare's own trusted consumer ASN to destination servers.
3. **Transparent DNS & Interface Failover**:
   - Interface-agnostic NAT masquerading and automatic DNS DNAT failover ensure that data packets and domain lookups **always transmit reliably**, preventing post-install connection stalls.

---

## 📱 Live Peer Management & Hot-Reloading

1. **Add Peers**: Click **"+ Add Peer"** in the web interface, enter a device name, choose split or full tunnel, and click **Show QR** to scan with iOS/Android WireGuard apps.
2. **Zero-Downtime Injection**: New peers are added directly to the active WireGuard interface via `wg set wg0 peer ...` without restarting the service or interrupting existing connections.
3. **Live Telemetry**: Real-time monitoring of active handshakes, transfer RX/TX byte counters, and client IP addresses.

---

## 🗄️ AES-256 Encrypted Backups

- Backup archives (`easy-wireguard-server-*.tar.gz.enc`) are encrypted using AES-256-CBC with PBKDF2 salting.
- Passphrase protection ensures configurations and private keys are never stored in plain-text.

---

## 📄 License

Distributed under the terms of the project [LICENSE](LICENSE).
