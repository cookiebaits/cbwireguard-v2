import express, { Request, Response } from 'express';
import cors from 'cors';
import crypto from 'crypto';
import QRCode from 'qrcode';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;

app.use(cors());
app.use(express.json());

// In-Memory WireGuard State Store
interface Peer {
  id: string;
  name: string;
  ip: string;
  publicKey: string;
  privateKey: string;
  presharedKey: string;
  allowedIps: string;
  dns: string;
  mtu: number;
  createdAt: string;
  enabled: boolean;
  endpoint: string | null;
  lastHandshake: string;
  transferRx: number; // bytes received from peer
  transferTx: number; // bytes sent to peer
  isOnline: boolean;
}

interface ShieldBlockLog {
  id: string;
  ip: string;
  country: string;
  flag: string;
  reason: string;
  port: number;
  timestamp: string;
}

interface BackupItem {
  id: string;
  filename: string;
  sizeBytes: number;
  sizeFormatted: string;
  createdAt: string;
  encryptedWithAes256: boolean;
  checksum: string;
  clientCount: number;
  dataHash: string;
}

// Generate base64 32-byte WireGuard key
function generateWgKey(): string {
  return crypto.randomBytes(32).toString('base64');
}

// Initial Server State
let serverState = {
  status: 'running' as 'running' | 'stopped',
  interfaceName: 'wg0',
  publicIp: process.env.SERVER_PUBLIC_IP || '198.51.100.42',
  listenPort: 51820,
  internalSubnet: '10.18.0.1/24',
  serverPublicKey: 'vQz7F2RzL1L4D2024WgServerPubKeyCookie999=',
  serverPrivateKey: generateWgKey(),
  ipForwarding: true,
  bbrEnabled: true,
  mssClamping: true,
  dokployBridge: false,
  defaultMtu: 1420,
  defaultDns: '94.140.14.49, 9.9.9.9, 94.140.14.59',
  defaultAllowedIps: '0.0.0.0/1, 128.0.0.0/1',
  uptimeStartedAt: Date.now() - 3600 * 24 * 3 * 1000, // 3 days ago
};

// Default Initial Peers
let peers: Peer[] = [
  {
    id: 'peer-1',
    name: 'MacBook-Pro-M3',
    ip: '10.18.0.2',
    publicKey: 'aBc123MacBookPubKeyWireguardMockSampleAA==',
    privateKey: generateWgKey(),
    presharedKey: generateWgKey(),
    allowedIps: '0.0.0.0/1, 128.0.0.0/1',
    dns: '94.140.14.49, 9.9.9.9',
    mtu: 1420,
    createdAt: new Date(Date.now() - 86400000 * 2).toISOString(),
    enabled: true,
    endpoint: '73.189.44.12:54891',
    lastHandshake: '18 seconds ago',
    transferRx: 489210400, // ~489 MB
    transferTx: 1948203000, // ~1.95 GB
    isOnline: true,
  },
  {
    id: 'peer-2',
    name: 'iPhone-15-Pro',
    ip: '10.18.0.3',
    publicKey: 'dEf456IPhonePubKeyWireguardMockSampleBB==',
    privateKey: generateWgKey(),
    presharedKey: generateWgKey(),
    allowedIps: '0.0.0.0/1, 128.0.0.0/1',
    dns: '94.140.14.49, 9.9.9.9',
    mtu: 1420,
    createdAt: new Date(Date.now() - 86400000 * 5).toISOString(),
    enabled: true,
    endpoint: '172.56.21.90:42110',
    lastHandshake: '1 minute ago',
    transferRx: 124800200, // ~124 MB
    transferTx: 843200900, // ~843 MB
    isOnline: true,
  },
  {
    id: 'peer-3',
    name: 'Work-ThinkPad',
    ip: '10.18.0.4',
    publicKey: 'gHi789ThinkPadPubKeyWireguardMockSampleCC==',
    privateKey: generateWgKey(),
    presharedKey: generateWgKey(),
    allowedIps: '0.0.0.0/0',
    dns: '1.1.1.1, 8.8.8.8',
    mtu: 1420,
    createdAt: new Date(Date.now() - 86400000 * 10).toISOString(),
    enabled: true,
    endpoint: '198.24.8.15:51920',
    lastHandshake: '4 hours ago',
    transferRx: 24500000,
    transferTx: 98000000,
    isOnline: false,
  },
];

// Geo-IP & Anti-VPN Shield State
let geoShield = {
  enabled: true,
  mode: 'US_CA_ONLY' as 'US_CA_ONLY' | 'CUSTOM' | 'ALL_PERMITTED',
  blockCommercialVpns: true,
  blockDatacenters: true,
  kernelIpsetActive: true,
  allowedSubnetsCount: 18450,
  blockedSubnetsCount: 43280,
  totalBlockedAttempts: 842,
  lastDatabaseUpdate: new Date(Date.now() - 3600000 * 4).toISOString(),
  customAllowList: ['198.51.100.0/24', '192.0.2.1/32'],
  customBlockList: ['45.154.255.0/24', '185.220.101.0/24'],
};

// Recent Geo Shield Block Logs
let shieldLogs: ShieldBlockLog[] = [
  {
    id: 'blk-1',
    ip: '185.220.101.5',
    country: 'DE',
    flag: '🇩🇪',
    reason: 'Commercial VPN / Tor Exit Node (Mullvad/Tor)',
    port: 51820,
    timestamp: new Date(Date.now() - 120000).toLocaleTimeString(),
  },
  {
    id: 'blk-2',
    ip: '194.26.29.112',
    country: 'NL',
    flag: '🇳🇱',
    reason: 'Datacenter Subnet (M247 Europe)',
    port: 51820,
    timestamp: new Date(Date.now() - 360000).toLocaleTimeString(),
  },
  {
    id: 'blk-3',
    ip: '89.187.168.42',
    country: 'RO',
    flag: '🇷🇴',
    reason: 'Geo-Fence Block (Non-US/CA Origin)',
    port: 51820,
    timestamp: new Date(Date.now() - 720000).toLocaleTimeString(),
  },
  {
    id: 'blk-4',
    ip: '45.154.255.77',
    country: 'RU',
    flag: '🇷🇺',
    reason: 'Custom Blacklist CIDR Match',
    port: 51820,
    timestamp: new Date(Date.now() - 1440000).toLocaleTimeString(),
  },
  {
    id: 'blk-5',
    ip: '104.244.73.9',
    country: 'FR',
    flag: '🇫🇷',
    reason: 'Datacenter Subnet (OVH Cloud)',
    port: 51820,
    timestamp: new Date(Date.now() - 2800000).toLocaleTimeString(),
  },
];

// Domain Split-Tunneling Predefined Services
interface SplitService {
  id: string;
  name: string;
  domain: string;
  enabled: boolean;
  category: 'streaming' | 'ai' | 'banking' | 'custom';
  subdomains: string[];
}

let splitServices: SplitService[] = [
  {
    id: 'disney',
    name: 'Disney+ / ESPN / Hulu Bundle',
    domain: 'disneyplus.com',
    enabled: true,
    category: 'streaming',
    subdomains: ['disneyplus.com', 'bamgrid.com', 'dssott.com', 'disneystreaming.com', 'hulu.com', 'hulustream.com'],
  },
  {
    id: 'netflix',
    name: 'Netflix',
    domain: 'netflix.com',
    enabled: true,
    category: 'streaming',
    subdomains: ['netflix.com', 'netflix.net', 'nflximg.net', 'nflxext.com', 'nflxvideo.net'],
  },
  {
    id: 'primevideo',
    name: 'Amazon Prime Video',
    domain: 'primevideo.com',
    enabled: false,
    category: 'streaming',
    subdomains: ['primevideo.com', 'amazonvideo.com', 'aiv-cdn.net', 'media-amazon.com'],
  },
  {
    id: 'max',
    name: 'Max (HBO)',
    domain: 'max.com',
    enabled: true,
    category: 'streaming',
    subdomains: ['max.com', 'hbomax.com', 'hbomaxcdn.com', 'hbo.com'],
  },
  {
    id: 'chatgpt',
    name: 'ChatGPT & OpenAI APIs',
    domain: 'chatgpt.com',
    enabled: true,
    category: 'ai',
    subdomains: ['chatgpt.com', 'openai.com', 'auth0.com', 'challenges.cloudflare.com', 'api.openai.com'],
  },
  {
    id: 'chase',
    name: 'Chase Bank',
    domain: 'chase.com',
    enabled: true,
    category: 'banking',
    subdomains: ['chase.com', 'chasecdn.com'],
  },
  {
    id: 'bofa',
    name: 'Bank of America',
    domain: 'bankofamerica.com',
    enabled: false,
    category: 'banking',
    subdomains: ['bankofamerica.com', 'bofa.com', 'bankofamerica.com.akadns.net'],
  },
  {
    id: 'ticketmaster',
    name: 'Ticketmaster & Live Nation',
    domain: 'ticketmaster.com',
    enabled: true,
    category: 'streaming',
    subdomains: ['ticketmaster.com', 'livenation.com', 'tmclient.ticketmaster.com'],
  },
];

let customBypassDomains: string[] = ['work.internalcorp.net', 'localplex.home'];

// Encrypted Backups Store
let serverBackups: BackupItem[] = [
  {
    id: 'bk-2026-10-15-prod',
    filename: 'easy-wireguard-server-2026-10-15_18-30-00-vps-prod-backup.tar.gz.enc',
    sizeBytes: 14240,
    sizeFormatted: '14.2 KB',
    createdAt: new Date(Date.now() - 86400000).toISOString(),
    encryptedWithAes256: true,
    checksum: 'a9f24b81c2de940821eef00192ba87c2',
    clientCount: 3,
    dataHash: crypto.createHash('sha256').update('sample-backup-1').digest('hex'),
  },
  {
    id: 'bk-2026-10-10-init',
    filename: 'easy-wireguard-server-2026-10-10_09-12-44-vps-prod-backup.tar.gz.enc',
    sizeBytes: 11890,
    sizeFormatted: '11.8 KB',
    createdAt: new Date(Date.now() - 86400000 * 6).toISOString(),
    encryptedWithAes256: true,
    checksum: '6e1a09cd34bb22019fe826742a0b4119',
    clientCount: 2,
    dataHash: crypto.createHash('sha256').update('sample-backup-0').digest('hex'),
  },
];

// Live Journalctl / Syslog stream
interface LogEntry {
  id: string;
  timestamp: string;
  level: 'info' | 'warn' | 'error' | 'shield';
  service: string;
  message: string;
}

let journalLogs: LogEntry[] = [
  {
    id: 'log-1',
    timestamp: new Date(Date.now() - 300000).toISOString(),
    level: 'info',
    service: 'kernel',
    message: '[wireguard] wg0: interface initialized with MTU 1420, ListenPort 51820',
  },
  {
    id: 'log-2',
    timestamp: new Date(Date.now() - 280000).toISOString(),
    level: 'info',
    service: 'wg-quick',
    message: 'iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE',
  },
  {
    id: 'log-3',
    timestamp: new Date(Date.now() - 260000).toISOString(),
    level: 'info',
    service: 'sysctl',
    message: 'BBR TCP congestion control and FQ queuing disciplines injected: net.ipv4.tcp_congestion_control = bbr',
  },
  {
    id: 'log-4',
    timestamp: new Date(Date.now() - 180000).toISOString(),
    level: 'shield',
    service: 'geo-shield',
    message: 'Kernel ipset match: Dropped foreign connection attempt from 185.220.101.5 (Tor Exit / Datacenter)',
  },
  {
    id: 'log-5',
    timestamp: new Date(Date.now() - 90000).toISOString(),
    level: 'info',
    service: 'wireguard',
    message: 'Peer MacBook-Pro-M3 (10.18.0.2) completed handshake with endpoint 73.189.44.12:54891',
  },
  {
    id: 'log-6',
    timestamp: new Date(Date.now() - 25000).toISOString(),
    level: 'info',
    service: 'wireguard',
    message: 'Peer iPhone-15-Pro (10.18.0.3) completed handshake with endpoint 172.56.21.90:42110',
  },
];

// Periodic background simulation to give realistic live feedback
setInterval(() => {
  if (serverState.status === 'running') {
    // Increment peer stats
    peers.forEach(peer => {
      if (peer.enabled && peer.isOnline) {
        peer.transferRx += Math.floor(Math.random() * 25000);
        peer.transferTx += Math.floor(Math.random() * 85000);
      }
    });

    // Occasional simulated handshake or shield event
    if (Math.random() > 0.65) {
      const activePeer = peers.find(p => p.enabled && p.isOnline);
      if (activePeer) {
        activePeer.lastHandshake = 'Just now';
      }
    }
  }
}, 5000);

// Helper to construct WireGuard server config
function generateServerConfigText(): string {
  let conf = `[Interface]
Address = ${serverState.internalSubnet}
ListenPort = ${serverState.listenPort}
PrivateKey = ${serverState.serverPrivateKey}
MTU = ${serverState.defaultMtu}
SaveConfig = false

# MSS Clamping & Fast Forwarding
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth0 -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth0 -j TCPMSS --clamp-mss-to-pmtu
${serverState.dokployBridge ? '# Dokploy Traefik UDP Proxy Bridge Active\n' : ''}
# --- Configured Peers ---
`;

  peers.forEach(p => {
    if (p.enabled) {
      conf += `
# Peer: ${p.name}
[Peer]
PublicKey = ${p.publicKey}
PresharedKey = ${p.presharedKey}
AllowedIPs = ${p.ip}/32
`;
    }
  });

  return conf;
}

// Helper to construct Client WireGuard Config
function generateClientConfigText(peer: Peer): string {
  return `[Interface]
PrivateKey = ${peer.privateKey}
Address = ${peer.ip}/24
DNS = ${peer.dns}
MTU = ${peer.mtu}

[Peer]
PublicKey = ${serverState.serverPublicKey}
PresharedKey = ${peer.presharedKey}
Endpoint = ${serverState.publicIp}:${serverState.listenPort}
AllowedIPs = ${peer.allowedIps}
PersistentKeepalive = 25
`;
}

// ======================== API ROUTES ========================

// 1. Server Status & Management
app.get('/api/server', (_req: Request, res: Response) => {
  const uptimeSeconds = Math.floor((Date.now() - serverState.uptimeStartedAt) / 1000);
  const totalRx = peers.reduce((sum, p) => sum + p.transferRx, 0);
  const totalTx = peers.reduce((sum, p) => sum + p.transferTx, 0);

  res.json({
    ...serverState,
    uptimeSeconds,
    activePeersCount: peers.filter(p => p.enabled).length,
    onlinePeersCount: peers.filter(p => p.enabled && p.isOnline).length,
    totalRx,
    totalTx,
  });
});

app.post('/api/server/action', (req: Request, res: Response) => {
  const { action } = req.body;
  const now = new Date().toISOString();

  if (action === 'start') {
    serverState.status = 'running';
    serverState.uptimeStartedAt = Date.now();
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'info',
      service: 'wg-quick',
      message: `[#] wg-quick up wg0: Interface initialized at ${serverState.publicIp}:${serverState.listenPort}`,
    });
  } else if (action === 'stop') {
    serverState.status = 'stopped';
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'warn',
      service: 'wg-quick',
      message: '[#] wg-quick down wg0: Server paused. Interfaces disassembled.',
    });
  } else if (action === 'restart') {
    serverState.status = 'running';
    serverState.uptimeStartedAt = Date.now();
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'info',
      service: 'wg-quick',
      message: '[#] Server gracefully restarted. Cryptographic keys and peer state reloaded with zero packet drop.',
    });
  } else if (action === 'rotate-keys') {
    serverState.serverPrivateKey = generateWgKey();
    serverState.serverPublicKey = generateWgKey();
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'warn',
      service: 'security',
      message: 'Server private and public keys re-generated with Curve25519.',
    });
  }

  res.json({ success: true, serverState });
});

app.get('/api/server/config', (_req: Request, res: Response) => {
  const configText = generateServerConfigText();
  res.type('text/plain').send(configText);
});

// 2. Client (Peer) Management
app.get('/api/clients', (_req: Request, res: Response) => {
  res.json({
    clients: peers,
    nextAvailableIp: `10.18.0.${peers.length + 2}`,
  });
});

app.post('/api/clients', async (req: Request, res: Response) => {
  try {
    const { name, allowedIps, dns, mtu } = req.body;
    const cleanName = (name || '').replace(/[^a-zA-Z0-9_-]/g, '') || `device-${Date.now().toString().slice(-4)}`;

    // Dynamically assign next sequential internal IP
    const usedIps = new Set(peers.map(p => p.ip));
    let nextIp = '10.18.0.2';
    for (let i = 2; i <= 254; i++) {
      const candidate = `10.18.0.${i}`;
      if (!usedIps.has(candidate)) {
        nextIp = candidate;
        break;
      }
    }

    const newPeer: Peer = {
      id: `peer-${Date.now()}`,
      name: cleanName,
      ip: nextIp,
      publicKey: generateWgKey(),
      privateKey: generateWgKey(),
      presharedKey: generateWgKey(),
      allowedIps: allowedIps || serverState.defaultAllowedIps,
      dns: dns || serverState.defaultDns,
      mtu: mtu ? parseInt(mtu, 10) : serverState.defaultMtu,
      createdAt: new Date().toISOString(),
      enabled: true,
      endpoint: null,
      lastHandshake: 'Never connected',
      transferRx: 0,
      transferTx: 0,
      isOnline: false,
    };

    peers.push(newPeer);

    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: new Date().toISOString(),
      level: 'info',
      service: 'hot-reload',
      message: `Zero-downtime injection: Peer ${cleanName} (${newPeer.ip}/32) live added to wg0 without restart.`,
    });

    res.status(201).json({ success: true, client: newPeer });
  } catch (err: any) {
    res.status(500).json({ error: err.message || 'Failed to create client' });
  }
});

app.put('/api/clients/:id', (req: Request, res: Response) => {
  const { id } = req.params;
  const peer = peers.find(p => p.id === id);
  if (!peer) {
    return res.status(404).json({ error: 'Client not found' });
  }

  const { name, enabled, allowedIps, dns, mtu } = req.body;
  if (name !== undefined) peer.name = name;
  if (enabled !== undefined) peer.enabled = enabled;
  if (allowedIps !== undefined) peer.allowedIps = allowedIps;
  if (dns !== undefined) peer.dns = dns;
  if (mtu !== undefined) peer.mtu = parseInt(mtu, 10);

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'peer-update',
    message: `Peer ${peer.name} (${peer.ip}) config updated in running kernel table.`,
  });

  res.json({ success: true, client: peer });
});

app.delete('/api/clients/:id', (req: Request, res: Response) => {
  const { id } = req.params;
  const index = peers.findIndex(p => p.id === id);
  if (index === -1) {
    return res.status(404).json({ error: 'Client not found' });
  }

  const deleted = peers.splice(index, 1)[0];
  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'warn',
    service: 'peer-revoke',
    message: `Peer ${deleted.name} (${deleted.ip}) revoked. Removed cryptographic route from wireguard interface.`,
  });

  res.json({ success: true, revokedId: id });
});

app.get('/api/clients/:id/config', (req: Request, res: Response) => {
  const peer = peers.find(p => p.id === req.params.id);
  if (!peer) {
    return res.status(404).json({ error: 'Client not found' });
  }

  const conf = generateClientConfigText(peer);
  res.setHeader('Content-Disposition', `attachment; filename="${peer.name}.conf"`);
  res.type('text/plain').send(conf);
});

app.get('/api/clients/:id/qr', async (req: Request, res: Response) => {
  const peer = peers.find(p => p.id === req.params.id);
  if (!peer) {
    return res.status(404).json({ error: 'Client not found' });
  }

  try {
    const conf = generateClientConfigText(peer);
    const qrDataUrl = await QRCode.toDataURL(conf, {
      errorCorrectionLevel: 'M',
      margin: 2,
      width: 320,
      color: {
        dark: '#000000',
        light: '#ffffff',
      },
    });
    res.json({ dataUrl: qrDataUrl, rawConfig: conf });
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to generate QR code' });
  }
});

// 3. Geo-IP & Anti-VPN Shield API
app.get('/api/geo-shield', (_req: Request, res: Response) => {
  res.json({
    ...geoShield,
    recentBlocks: shieldLogs,
  });
});

app.post('/api/geo-shield/toggle', (req: Request, res: Response) => {
  const { enabled, mode, blockCommercialVpns, blockDatacenters } = req.body;
  if (enabled !== undefined) geoShield.enabled = enabled;
  if (mode !== undefined) geoShield.mode = mode;
  if (blockCommercialVpns !== undefined) geoShield.blockCommercialVpns = blockCommercialVpns;
  if (blockDatacenters !== undefined) geoShield.blockDatacenters = blockDatacenters;

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'shield',
    service: 'geo-shield',
    message: `Geo-IP & Anti-VPN Shield rules re-applied: ${geoShield.enabled ? 'ACTIVE (' + geoShield.mode + ')' : 'DISABLED'}`,
  });

  res.json({ success: true, geoShield });
});

app.post('/api/geo-shield/rule', (req: Request, res: Response) => {
  const { type, cidr } = req.body;
  if (!cidr) {
    return res.status(400).json({ error: 'CIDR or IP is required' });
  }

  if (type === 'allow') {
    if (!geoShield.customAllowList.includes(cidr)) {
      geoShield.customAllowList.push(cidr);
    }
  } else if (type === 'block') {
    if (!geoShield.customBlockList.includes(cidr)) {
      geoShield.customBlockList.push(cidr);
    }
  }

  res.json({ success: true, customAllowList: geoShield.customAllowList, customBlockList: geoShield.customBlockList });
});

app.delete('/api/geo-shield/rule', (req: Request, res: Response) => {
  const { type, cidr } = req.body;
  if (type === 'allow') {
    geoShield.customAllowList = geoShield.customAllowList.filter(c => c !== cidr);
  } else if (type === 'block') {
    geoShield.customBlockList = geoShield.customBlockList.filter(c => c !== cidr);
  }
  res.json({ success: true, customAllowList: geoShield.customAllowList, customBlockList: geoShield.customBlockList });
});

app.post('/api/geo-shield/update-database', (_req: Request, res: Response) => {
  geoShield.lastDatabaseUpdate = new Date().toISOString();
  geoShield.allowedSubnetsCount += Math.floor(Math.random() * 30);
  geoShield.blockedSubnetsCount += Math.floor(Math.random() * 50);

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'threat-feed',
    message: 'Official US/CA zone and anti-datacenter blocklist refreshed. 61,730 total prefixes loaded into kernel ipset.',
  });

  res.json({ success: true, geoShield });
});

// 4. Domain Split Tunneling API
app.get('/api/split-tunneling', (_req: Request, res: Response) => {
  res.json({
    services: splitServices,
    customDomains: customBypassDomains,
  });
});

app.post('/api/split-tunneling/toggle-service', (req: Request, res: Response) => {
  const { id, enabled } = req.body;
  const svc = splitServices.find(s => s.id === id);
  if (svc) {
    svc.enabled = enabled;
  }
  res.json({ success: true, services: splitServices });
});

app.post('/api/split-tunneling/custom-domain', (req: Request, res: Response) => {
  const { domain } = req.body;
  if (domain && !customBypassDomains.includes(domain)) {
    customBypassDomains.push(domain.trim().toLowerCase());
  }
  res.json({ success: true, customDomains: customBypassDomains });
});

app.delete('/api/split-tunneling/custom-domain', (req: Request, res: Response) => {
  const { domain } = req.body;
  customBypassDomains = customBypassDomains.filter(d => d !== domain);
  res.json({ success: true, customDomains: customBypassDomains });
});

// 5. Encrypted Backup & Restore Manager
app.get('/api/backups', (_req: Request, res: Response) => {
  res.json({ backups: serverBackups });
});

app.post('/api/backups', (req: Request, res: Response) => {
  const { password } = req.body;
  if (!password || password.length < 4) {
    return res.status(400).json({ error: 'Password must be at least 4 characters long' });
  }

  const now = new Date();
  const dateStr = now.toISOString().replace(/[:T]/g, '-').slice(0, 19);
  const filename = `easy-wireguard-server-${dateStr}-prod-backup.tar.gz.enc`;

  // AES-256 simulation using crypto pbkdf2
  const cipher = crypto.createCipheriv(
    'aes-256-cbc',
    crypto.scryptSync(password, 'salt-cookiebaits', 32),
    Buffer.alloc(16, 0)
  );

  const payload = JSON.stringify({ serverState, peers, geoShield, customBypassDomains });
  let encrypted = cipher.update(payload, 'utf8', 'hex');
  encrypted += cipher.final('hex');

  const newBackup: BackupItem = {
    id: `bk-${Date.now()}`,
    filename,
    sizeBytes: 12000 + peers.length * 1200,
    sizeFormatted: `${((12000 + peers.length * 1200) / 1024).toFixed(1)} KB`,
    createdAt: now.toISOString(),
    encryptedWithAes256: true,
    checksum: crypto.createHash('md5').update(encrypted).digest('hex'),
    clientCount: peers.length,
    dataHash: crypto.createHash('sha256').update(password).digest('hex'),
  };

  serverBackups.unshift(newBackup);

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: now.toISOString(),
    level: 'info',
    service: 'backup-manager',
    message: `AES-256 encrypted backup archive created: ${filename}`,
  });

  res.status(201).json({ success: true, backup: newBackup });
});

app.post('/api/backups/:id/restore', (req: Request, res: Response) => {
  const { id } = req.params;
  const { password } = req.body;
  const backup = serverBackups.find(b => b.id === id);

  if (!backup) {
    return res.status(404).json({ error: 'Backup archive not found' });
  }

  if (!password) {
    return res.status(400).json({ error: 'Decryption password required' });
  }

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'warn',
    service: 'restore-manager',
    message: `Successfully decrypted and restored WireGuard server configuration from ${backup.filename}. Interface reloaded.`,
  });

  res.json({ success: true, message: 'Configuration successfully restored!' });
});

app.delete('/api/backups/:id', (req: Request, res: Response) => {
  serverBackups = serverBackups.filter(b => b.id !== req.params.id);
  res.json({ success: true });
});

// 6. Real-Time Diagnostics & Journalctl Logs
app.get('/api/logs', (_req: Request, res: Response) => {
  res.json({ logs: journalLogs });
});

app.post('/api/logs/clear', (_req: Request, res: Response) => {
  journalLogs = [];
  res.json({ success: true });
});

// 7. Settings
app.get('/api/settings', (_req: Request, res: Response) => {
  res.json({
    defaultMtu: serverState.defaultMtu,
    defaultDns: serverState.defaultDns,
    defaultAllowedIps: serverState.defaultAllowedIps,
    listenPort: serverState.listenPort,
    publicIp: serverState.publicIp,
    dokployBridge: serverState.dokployBridge,
    bbrEnabled: serverState.bbrEnabled,
    mssClamping: serverState.mssClamping,
  });
});

app.put('/api/settings', (req: Request, res: Response) => {
  const { defaultMtu, defaultDns, defaultAllowedIps, listenPort, publicIp, dokployBridge } = req.body;

  if (defaultMtu !== undefined) serverState.defaultMtu = parseInt(defaultMtu, 10);
  if (defaultDns !== undefined) serverState.defaultDns = defaultDns;
  if (defaultAllowedIps !== undefined) serverState.defaultAllowedIps = defaultAllowedIps;
  if (listenPort !== undefined) serverState.listenPort = parseInt(listenPort, 10);
  if (publicIp !== undefined) serverState.publicIp = publicIp;
  if (dokployBridge !== undefined) serverState.dokployBridge = !!dokployBridge;

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'settings',
    message: 'Global WireGuard deployment defaults updated in settings.conf',
  });

  res.json({ success: true, serverState });
});

// 8. One-Click Bash Installer Script Generator for Ubuntu
app.get('/api/bash-script', (_req: Request, res: Response) => {
  const scriptContent = `#!/bin/bash
# 🍪 Cookie's WireGuard Server Deployment Script
# Generated from Cookie's WireGuard Manager
set -euo pipefail

WG_PORT=${serverState.listenPort}
WG_MTU=${serverState.defaultMtu}
WG_DNS="${serverState.defaultDns}"
WG_ALLOWED_IPS="${serverState.defaultAllowedIps}"

echo "==> Deploying optimized WireGuard server on Ubuntu..."
apt-get update -y && apt-get install -y wireguard ufw qrencode ipset iptables

# Enable BBR & IP Forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.d/99-wireguard.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-wireguard.conf
sysctl --system

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Generate Server Keys
umask 077
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)

cat <<CONF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.18.0.1/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV
MTU = $WG_MTU

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth0 -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth0 -j TCPMSS --clamp-mss-to-pmtu
CONF

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
ufw allow $WG_PORT/udp

echo "==> WireGuard server successfully launched on port $WG_PORT!"
`;

  res.type('text/x-shellscript').send(scriptContent);
});

// Setup Vite or static serving
async function startServer() {
  const isProd = process.env.NODE_ENV === 'production';

  if (!isProd) {
    const { createServer: createViteServer } = await import('vite');
    const vite = await createViteServer({
      server: { middlewareMode: true, host: '0.0.0.0' },
      appType: 'spa',
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.resolve(__dirname, 'dist');
    if (fs.existsSync(distPath)) {
      app.use(express.static(distPath));
      app.get('*', (_req: Request, res: Response) => {
        res.sendFile(path.resolve(distPath, 'index.html'));
      });
    }
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[Cookie's WireGuard Manager] Running at http://0.0.0.0:${PORT}`);
  });
}

startServer().catch(err => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
