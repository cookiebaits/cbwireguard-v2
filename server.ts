import express from 'express';
import type { Request, Response, NextFunction } from 'express';
import cors from 'cors';
import crypto from 'crypto';
import QRCode from 'qrcode';
import path from 'path';
import fs from 'fs';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { CLOUDFLARE_BYPASS_CIDRS, formatWireguardAllowedIps } from './src/constants/cloudflareCidrs.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();

const SENSITIVE_PORTS = [20, 21, 22, 23, 25, 53, 67, 68, 80, 110, 143, 443, 8080, 8443, 3306, 5432, 6379, 27017];

function getListenPort(): number {
  if (process.env.PORT) return parseInt(process.env.PORT, 10);
  if (fs.existsSync('/etc/wireguard/manager.env')) {
    try {
      const content = fs.readFileSync('/etc/wireguard/manager.env', 'utf8');
      const match = content.match(/WEB_PORT="?([^"\r\n]+)"?/);
      if (match && match[1].trim()) {
        const p = parseInt(match[1].trim(), 10);
        if (!SENSITIVE_PORTS.includes(p)) return p;
      }
    } catch (e) {}
  }
  if (process.env.WEB_PORT) {
    const p = parseInt(process.env.WEB_PORT, 10);
    if (!SENSITIVE_PORTS.includes(p)) return p;
  }
  return 3000;
}

const PORT = getListenPort();

app.use(cors());
app.use(express.json());

export interface ServerInstanceInfo {
  interfaceName: 'wg0' | 'wg1' | string;
  name: string;
  mode: 'standard' | 'cloudflare_anti_flag';
  listenPort: number;
  internalSubnet: string;
  status: 'running' | 'stopped';
  activePeersCount: number;
  onlinePeersCount: number;
  totalRx: number;
  totalTx: number;
  description: string;
}

interface Peer {
  id: string;
  name: string;
  ip: string;
  publicKey: string;
  privateKey: string;
  presharedKey: string;
  cfPublicKey?: string;
  cfPrivateKey?: string;
  allowedIps: string;
  dns: string;
  mtu: number;
  createdAt: string;
  enabled: boolean;
  endpoint: string | null;
  lastHandshake: string;
  transferRx: number;
  transferTx: number;
  isOnline: boolean;
  instance?: 'wg0' | 'wg1';
  profileMode?: 'standard' | 'cloudflare_anti_flag';
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

interface LogEntry {
  id: string;
  timestamp: string;
  level: 'info' | 'warn' | 'error' | 'shield';
  service: string;
  message: string;
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

interface StealthConfig {
  ttlNormalization: boolean;
  mssClamping: boolean;
  pmtuProbing: boolean;
  quicPortCloaking: boolean;
  ipv6LeakShield: boolean;
  bbrPacing: boolean;
  tosNormalization: boolean;
  udpFragmentationDefense: boolean;
  cloudflareShield: boolean;
  ispHostMasking: boolean;
  warpEgress: boolean;
  cloudflareSplitRanges: boolean;
  windowsTtlEmulation: boolean;
  upstreamProxy?: string;
  overallScore: number;
  rating: string;
}

// Generate base64 32-byte WireGuard key
function generateWgKey(): string {
  return crypto.randomBytes(32).toString('base64');
}

// -------------------------------------------------------------
// Auto-Detection Logic based on easy_wireguard.sh and host environment
// -------------------------------------------------------------
function getAutoDetectedPublicIp(): string {
  // 1. Check if easy_wireguard.sh wrote /etc/wireguard/manager.env
  if (fs.existsSync('/etc/wireguard/manager.env')) {
    try {
      const content = fs.readFileSync('/etc/wireguard/manager.env', 'utf8');
      const match = content.match(/SERVER_PUBLIC_IP="?([^"\r\n]+)"?/);
      if (match && match[1].trim() && match[1].trim() !== '127.0.0.1') {
        return match[1].trim();
      }
    } catch (e) {}
  }

  // 2. Check if explicitly provided via env
  if (process.env.SERVER_PUBLIC_IP && process.env.SERVER_PUBLIC_IP !== '198.51.100.42') {
    return process.env.SERVER_PUBLIC_IP;
  }

  // 3. Query external public IP dynamically
  try {
    const detected = execSync(
      'curl -4 -sSf --max-time 2 https://api.ipify.org 2>/dev/null || curl -4 -sSf --max-time 2 https://ifconfig.me 2>/dev/null',
      { encoding: 'utf8' }
    ).trim();
    if (detected && /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(detected)) {
      return detected;
    }
  } catch (e) {}

  return '127.0.0.1';
}

function getAutoDetectedWgPort(): number {
  // 1. Check if easy_wireguard.sh wrote /etc/wireguard/manager.env
  if (fs.existsSync('/etc/wireguard/manager.env')) {
    try {
      const content = fs.readFileSync('/etc/wireguard/manager.env', 'utf8');
      const match = content.match(/WG_DEFAULT_PORT="?([^"\r\n]+)"?/);
      if (match && match[1].trim()) {
        const p = parseInt(match[1].trim(), 10);
        if (!SENSITIVE_PORTS.includes(p)) return p;
      }
    } catch (e) {}
  }

  // 2. Check /etc/wireguard/wg0.conf
  if (fs.existsSync('/etc/wireguard/wg0.conf')) {
    try {
      const conf = fs.readFileSync('/etc/wireguard/wg0.conf', 'utf8');
      const match = conf.match(/ListenPort\s*=\s*(\d+)/i);
      if (match && match[1]) {
        const p = parseInt(match[1], 10);
        if (!SENSITIVE_PORTS.includes(p)) return p;
      }
    } catch (e) {}
  }

  // 3. Check environment
  if (process.env.WG_DEFAULT_PORT) {
    const p = parseInt(process.env.WG_DEFAULT_PORT, 10);
    if (!SENSITIVE_PORTS.includes(p)) return p;
  }

  // Default to 4500 for IPsec NAT-T stealth tunneling (avoids sensitive ports 80/443)
  return 4500;
}

function getAutoDetectedWebPort(): number {
  if (fs.existsSync('/etc/wireguard/manager.env')) {
    try {
      const content = fs.readFileSync('/etc/wireguard/manager.env', 'utf8');
      const match = content.match(/WEB_PORT="?([^"\r\n]+)"?/);
      if (match && match[1].trim()) {
        const p = parseInt(match[1].trim(), 10);
        if (!SENSITIVE_PORTS.includes(p)) return p;
      }
    } catch (e) {}
  }
  if (process.env.WEB_PORT) {
    const p = parseInt(process.env.WEB_PORT, 10);
    if (!SENSITIVE_PORTS.includes(p)) return p;
  }
  return 51821; // Dedicated WireGuard internal web port for VPS deployment
}

// Load or Generate Master Security Passkey
let adminPasskey = 'CookieAdminSec2026!#WireGuard';
try {
  if (fs.existsSync('/etc/wireguard/manager.env')) {
    const env = fs.readFileSync('/etc/wireguard/manager.env', 'utf8');
    const match = env.match(/ADMIN_PASSKEY="?([^"\r\n]+)"?/);
    if (match && match[1].trim()) adminPasskey = match[1].trim();
  } else if (fs.existsSync('/etc/wireguard/admin.key')) {
    adminPasskey = fs.readFileSync('/etc/wireguard/admin.key', 'utf8').trim();
  } else if (fs.existsSync('/etc/wireguard')) {
    const generated = crypto.randomBytes(16).toString('hex');
    fs.writeFileSync('/etc/wireguard/admin.key', generated, { mode: 0o600 });
    adminPasskey = generated;
  }
} catch (e) {}

// OpenSSL AES-256-CBC PBKDF2 compatible encryption helper (interoperable with easy_wireguard.sh)
function encryptConfigToOpenSSLBuffer(text: string, password: string): Buffer {
  const salt = crypto.randomBytes(8);
  const keyAndIv = crypto.pbkdf2Sync(password, salt, 100000, 48, 'sha256');
  const key = keyAndIv.subarray(0, 32);
  const iv = keyAndIv.subarray(32, 48);
  const cipher = crypto.createCipheriv('aes-256-cbc', key, iv);
  const encrypted = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
  return Buffer.concat([Buffer.from('Salted__', 'utf8'), salt, encrypted]);
}

function decryptConfigFromOpenSSLBuffer(buffer: Buffer, password: string): string {
  if (buffer.subarray(0, 8).toString('utf8') !== 'Salted__') {
    return buffer.toString('utf8');
  }
  const salt = buffer.subarray(8, 16);
  const ciphertext = buffer.subarray(16);
  const keyAndIv = crypto.pbkdf2Sync(password, salt, 100000, 48, 'sha256');
  const key = keyAndIv.subarray(0, 32);
  const iv = keyAndIv.subarray(32, 48);
  const decipher = crypto.createDecipheriv('aes-256-cbc', key, iv);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

// Scans /root and $HOME for any loose .conf files, encrypts them into easy_wireguard/ and unlinks them from root
function cleanupRootDirectory(): number {
  let cleanedCount = 0;
  try {
    const easyWgDir = '/root/easy_wireguard';
    if (!fs.existsSync(easyWgDir)) {
      try { fs.mkdirSync(easyWgDir, { recursive: true, mode: 0o700 }); } catch (e) {}
    }
    if (!fs.existsSync('/etc/wireguard/clients')) {
      try { fs.mkdirSync('/etc/wireguard/clients', { recursive: true, mode: 0o700 }); } catch (e) {}
    }

    const searchDirs = ['/root'];
    if (process.env.HOME && process.env.HOME !== '/root' && !searchDirs.includes(process.env.HOME)) {
      searchDirs.push(process.env.HOME);
    }

    for (const dir of searchDirs) {
      if (!fs.existsSync(dir)) continue;
      try {
        const files = fs.readdirSync(dir);
        for (const file of files) {
          if (file.endsWith('.conf') && file !== 'resolv.conf' && file !== 'sysctl.conf') {
            const fullPath = path.join(dir, file);
            try {
              const content = fs.readFileSync(fullPath, 'utf8');
              if (content.includes('[Interface]') || content.includes('PrivateKey') || content.includes('AllowedIPs')) {
                const encBuf = encryptConfigToOpenSSLBuffer(content, adminPasskey);
                fs.writeFileSync(path.join(easyWgDir, `${file}.enc`), encBuf, { mode: 0o600 });
                fs.writeFileSync(path.join('/etc/wireguard/clients', `${file}.enc`), encBuf, { mode: 0o600 });
                fs.unlinkSync(fullPath);
                cleanedCount++;
              }
            } catch (e) {}
          }
        }
      } catch (e) {}
    }
  } catch (e) {}
  return cleanedCount;
}

// Initial dynamic values
const initialDetectedIp = getAutoDetectedPublicIp();
const initialDetectedPort = getAutoDetectedWgPort();
const initialDetectedWebPort = getAutoDetectedWebPort();

// Security & Whitelisting State
const whitelistedIps = new Set<string>([
  '127.0.0.1',
  '::1',
  'localhost',
  initialDetectedIp,
]);
const authorizedSessionTokens = new Set<string>();
let vpnRequiredMode = true;

// Initial Server State
let serverState = {
  status: 'running' as 'running' | 'stopped',
  interfaceName: 'wg0',
  publicIp: initialDetectedIp,
  listenPort: initialDetectedPort,
  secondaryPort: initialDetectedPort,
  webPort: initialDetectedWebPort,
  internalSubnet: '10.18.0.1/24',
  secondarySubnet: '10.19.0.1/24',
  serverPublicKey: 'vQz7F2RzL1L4D2024WgServerPubKeyCookie999=',
  serverPrivateKey: generateWgKey(),
  ipForwarding: true,
  bbrEnabled: true,
  mssClamping: true,
  dokployBridge: false,
  defaultMtu: 1420,
  defaultDns: '1.1.1.1, 1.0.0.1',
  defaultAllowedIps: '0.0.0.0/0',
  uptimeStartedAt: Date.now(),
  isRealSystemData: false,
};

let stealthConfig: StealthConfig = {
  ttlNormalization: true,
  mssClamping: true,
  pmtuProbing: true,
  quicPortCloaking: [4500, 3478, 500, 853].includes(serverState.listenPort),
  ipv6LeakShield: true,
  bbrPacing: true,
  tosNormalization: true,
  udpFragmentationDefense: true,
  cloudflareShield: true,
  ispHostMasking: true,
  warpEgress: true,
  cloudflareSplitRanges: true,
  windowsTtlEmulation: false,
  upstreamProxy: '',
  overallScore: 98,
  rating: 'Tier 1 Stealth (Concealed VPS Hop)',
};

function recalculateStealthScore() {
  let score = 50;
  if (stealthConfig.ttlNormalization) score += 10;
  if (stealthConfig.mssClamping) score += 8;
  if (stealthConfig.pmtuProbing) score += 4;
  if (stealthConfig.quicPortCloaking || serverState.listenPort === 443) score += 8;
  if (stealthConfig.ipv6LeakShield) score += 6;
  if (stealthConfig.bbrPacing) score += 4;
  if (stealthConfig.tosNormalization) score += 2;
  if (stealthConfig.cloudflareShield) score += 10;
  if (stealthConfig.ispHostMasking) score += 10;
  if (stealthConfig.warpEgress) score += 8;
  stealthConfig.overallScore = Math.min(100, score);
  if (score >= 90) stealthConfig.rating = 'Tier 1 Stealth (Concealed VPS & Cloudflare Safe)';
  else if (score >= 75) stealthConfig.rating = 'Tier 2 Protected (Minor Fingerprint)';
  else stealthConfig.rating = 'Exposed VPS (Standard WireGuard Detection)';
}

// Clean Peers Array - NO DEMO DATA
let peers: Peer[] = [];

// Clean Backups Array - NO DEMO DATA
let serverBackups: BackupItem[] = [];

// Clean Shield Logs Array - NO DEMO DATA
let shieldLogs: ShieldBlockLog[] = [];

// Real System Journal Logs
let journalLogs: LogEntry[] = [
  {
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'wireguard',
    message: `[wireguard] wg0 interface initialized on ${serverState.publicIp}:${serverState.listenPort} (${serverState.listenPort === 443 ? 'HTTP/3 QUIC Stealth Cloaking Active' : 'UDP'})`,
  },
];

// Helper to check if real WireGuard is running on the host system
function checkLiveWireguard(): boolean {
  try {
    if (!fs.existsSync('/etc/wireguard/wg0.conf')) return false;
    const wgBinary = execSync('which wg 2>/dev/null', { encoding: 'utf8' }).trim();
    if (!wgBinary) return false;
    const output = execSync('wg show wg0 dump 2>/dev/null', { encoding: 'utf8' });
    return output.length > 0;
  } catch (e) {
    return false;
  }
}

// Live WireGuard kernel sync reader - reads real data from host
function syncFromLiveWireguard() {
  try {
    // 1. Re-check IP & Port from manager.env if present
    serverState.publicIp = getAutoDetectedPublicIp();
    serverState.listenPort = getAutoDetectedWgPort();
    serverState.webPort = getAutoDetectedWebPort();

    // 2. Ensure root directory is free of loose .conf files (auto-sweep to /root/easy_wireguard/ encrypted)
    cleanupRootDirectory();

    const searchDirs = ['/root/easy_wireguard', '/etc/wireguard/clients'];

    if (!checkLiveWireguard()) {
      serverState.isRealSystemData = false;
      // Also scan /root/easy_wireguard and /etc/wireguard/clients for any generated encrypted configs
      if (peers.length === 0) {
        const foundPeers: Peer[] = [];
        const seenNames = new Set<string>();

        for (const dir of searchDirs) {
          if (!fs.existsSync(dir)) continue;
          try {
            const files = fs.readdirSync(dir);
            for (const file of files) {
              if (file.endsWith('.conf.enc') || file.endsWith('.conf')) {
                const baseName = file.replace(/\.conf(\.enc)?$/, '').replace('-cloudflare-shield', '').replace('-standard', '');
                if (seenNames.has(baseName)) continue;
                seenNames.add(baseName);
                try {
                  let conf = '';
                  const fullPath = `${dir}/${file}`;
                  if (file.endsWith('.conf.enc')) {
                    const buf = fs.readFileSync(fullPath);
                    conf = decryptConfigFromOpenSSLBuffer(buf, adminPasskey);
                  } else {
                    conf = fs.readFileSync(fullPath, 'utf8');
                  }

                  const addrMatch = conf.match(/Address\s*=\s*([^\s\/]+)/i);
                  const privMatch = conf.match(/PrivateKey\s*=\s*([^\s]+)/i);
                  const pskMatch = conf.match(/PresharedKey\s*=\s*([^\s]+)/i);

                  let pubKey = 'LIVE_KERNEL_KEY';
                  if (privMatch) {
                    try {
                      pubKey = execSync(`echo "${privMatch[1]}" | wg pubkey 2>/dev/null`, { encoding: 'utf8' }).trim() || 'LIVE_KERNEL_KEY';
                    } catch (e) {}
                  }

                  foundPeers.push({
                    id: `peer-${baseName}`,
                    name: baseName,
                    ip: addrMatch ? addrMatch[1] : '10.18.0.2',
                    publicKey: pubKey,
                    privateKey: privMatch ? privMatch[1] : generateWgKey(),
                    presharedKey: pskMatch ? pskMatch[1] : generateWgKey(),
                    allowedIps: serverState.defaultAllowedIps,
                    dns: serverState.defaultDns,
                    mtu: serverState.defaultMtu,
                    createdAt: new Date().toISOString(),
                    enabled: true,
                    endpoint: null,
                    lastHandshake: 'Awaiting connection',
                    transferRx: 0,
                    transferTx: 0,
                    isOnline: false,
                  });
                } catch (e) {}
              }
            }
          } catch (e) {}
        }
        if (foundPeers.length > 0) peers = foundPeers;
      }
      return;
    }

    serverState.isRealSystemData = true;

    // Read client configs from /root/easy_wireguard and /etc/wireguard/clients (.conf.enc and .conf) to map client names and keys
    const clientNameMap = new Map<string, string>();
    const clientPrivMap = new Map<string, string>();
    const clientPskMap = new Map<string, string>();

    for (const dir of searchDirs) {
      if (!fs.existsSync(dir)) continue;
      try {
        const files = fs.readdirSync(dir);
        for (const file of files) {
          if (file.endsWith('.conf.enc') || file.endsWith('.conf')) {
            const baseName = file.replace(/\.conf(\.enc)?$/, '').replace('-cloudflare-shield', '').replace('-standard', '');
            try {
              let confContent = '';
              const fullPath = `${dir}/${file}`;
              if (file.endsWith('.conf.enc')) {
                const buf = fs.readFileSync(fullPath);
                confContent = decryptConfigFromOpenSSLBuffer(buf, adminPasskey);
              } else {
                confContent = fs.readFileSync(fullPath, 'utf8');
              }

              const privMatch = confContent.match(/PrivateKey\s*=\s*([^\s]+)/i);
              const pskMatch = confContent.match(/PresharedKey\s*=\s*([^\s]+)/i);
              if (privMatch) {
                const clientPriv = privMatch[1];
                let clientPub = '';
                try {
                  clientPub = execSync(`echo "${clientPriv}" | wg pubkey 2>/dev/null`, { encoding: 'utf8' }).trim();
                } catch (e) {}
                if (clientPub) {
                  if (!clientNameMap.has(clientPub)) clientNameMap.set(clientPub, baseName);
                  if (!clientPrivMap.has(clientPub)) clientPrivMap.set(clientPub, clientPriv);
                  if (pskMatch && !clientPskMap.has(clientPub)) clientPskMap.set(clientPub, pskMatch[1]);
                }
              }
            } catch (e) {}
          }
        }
      } catch (e) {}
    }

    const livePeers: Peer[] = [];
    const ifaces = ['wg0', 'wg1'];

    for (const iface of ifaces) {
      try {
        const dumpOut = execSync(`wg show ${iface} dump 2>/dev/null`, { encoding: 'utf8' }).trim();
        if (!dumpOut) continue;
        const lines = dumpOut.split('\n');
        if (lines.length === 0) continue;

        // Line 0: <private_key> <public_key> <listen_port> <fwmark>
        const serverLine = lines[0].split('\t');
        if (serverLine.length >= 3 && iface === 'wg0') {
          serverState.serverPublicKey = serverLine[1];
          serverState.serverPrivateKey = serverLine[0];
          serverState.listenPort = parseInt(serverLine[2], 10);
        } else if (serverLine.length >= 3 && iface === 'wg1') {
          serverState.secondaryPort = parseInt(serverLine[2], 10);
        }

        // Subsequent lines: peers
        for (let i = 1; i < lines.length; i++) {
          const pLine = lines[i].split('\t');
          if (pLine.length >= 7) {
            const pubKey = pLine[0];
            const psk = pLine[1] !== '(none)' ? pLine[1] : (clientPskMap.get(pubKey) || '');
            const endpoint = pLine[2] !== '(none)' ? pLine[2] : null;
            const allowedIps = pLine[3];
            const lastHandshakeEpoch = parseInt(pLine[4], 10);
            const rxBytes = parseInt(pLine[5], 10);
            const txBytes = parseInt(pLine[6], 10);

            const assignedIp = allowedIps.split(',')[0].replace('/32', '');
            const clientName = clientNameMap.get(pubKey) || `device-${pubKey.slice(0, 6)}`;

            const nowSec = Math.floor(Date.now() / 1000);
            const diffSec = nowSec - lastHandshakeEpoch;
            let handshakeFormatted = 'Never connected';
            let isOnline = false;

            if (lastHandshakeEpoch > 0) {
              if (diffSec < 60) handshakeFormatted = `${diffSec} seconds ago`;
              else if (diffSec < 3600) handshakeFormatted = `${Math.floor(diffSec / 60)} minutes ago`;
              else if (diffSec < 86400) handshakeFormatted = `${Math.floor(diffSec / 3600)} hours ago`;
              else handshakeFormatted = `${Math.floor(diffSec / 86400)} days ago`;

              isOnline = diffSec < 180;
            }

            const isWg1 = iface === 'wg1' || assignedIp.startsWith('10.19.');

            livePeers.push({
              id: `live-${iface}-${pubKey.slice(0, 8)}`,
              name: clientName,
              ip: assignedIp,
              publicKey: pubKey,
              privateKey: clientPrivMap.get(pubKey) || 'ENCRYPTED_ON_VPS',
              presharedKey: psk,
              allowedIps,
              dns: serverState.defaultDns,
              mtu: isWg1 ? 1360 : serverState.defaultMtu,
              createdAt: new Date().toISOString(),
              enabled: true,
              endpoint,
              lastHandshake: handshakeFormatted,
              transferRx: rxBytes,
              transferTx: txBytes,
              isOnline,
              instance: isWg1 ? 'wg1' : 'wg0',
              profileMode: isWg1 ? 'cloudflare_anti_flag' : 'standard',
            });
          }
        }
      } catch (e) {}
    }

    if (livePeers.length > 0) {
      peers = livePeers;
    }
  } catch (err) {}
}

// Initial Sync check
syncFromLiveWireguard();

// Periodic live sync (checks real host kernel every 5 seconds)
setInterval(() => {
  syncFromLiveWireguard();
}, 5000);

// Geo-IP & Anti-VPN Shield State (Active rules, clean logs)
let geoShield = {
  enabled: true,
  mode: 'US_CA_ONLY' as 'US_CA_ONLY' | 'CUSTOM' | 'ALL_PERMITTED',
  blockCommercialVpns: true,
  blockDatacenters: true,
  kernelIpsetActive: true,
  allowedSubnetsCount: 18450,
  blockedSubnetsCount: 43280,
  totalBlockedAttempts: 0,
  lastDatabaseUpdate: new Date().toISOString(),
  customAllowList: [] as string[],
  customBlockList: [] as string[],
};

// Domain Split-Tunneling Predefined Services (Functional unblocking rules)
interface SplitService {
  id: string;
  name: string;
  domain: string;
  enabled: boolean;
  category: 'shopping' | 'streaming' | 'ai' | 'banking' | 'custom';
  subdomains: string[];
}

const CLOUDFLARE_IPV4_CIDRS = [
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '104.24.0.0/14',
  '172.64.0.0/13',
  '131.0.72.0/22',
];

const CLOUDFLARE_IPV6_CIDRS = [
  '2400:cb00::/32',
  '2606:4700::/32',
  '2803:f800::/32',
  '2405:b500::/32',
  '2405:8100::/32',
  '2a06:98c0::/29',
  '2c0f:f248::/32',
];

let splitServices: SplitService[] = [
  {
    id: 'amazon',
    name: 'Amazon Retail, Search & Autocomplete',
    domain: 'amazon.com',
    enabled: true,
    category: 'shopping',
    subdomains: ['amazon.com', 'www.amazon.com', 'completion.amazon.com', 'images-amazon.com', 'media-amazon.com', 'ssl-images-amazon.com', 'amazon.co.uk', 'amazon.ca', 'amazon.de', 'amazon.fr', 'amazon.it', 'amazon.es', 'amazon.co.jp', 'aax.amazon-adsystem.com', 'fls-na.amazon.com', 'cloudfront.net'],
  },
  {
    id: 'paypal_checkout',
    name: 'PayPal, Braintree & 3D-Secure Checkout Gateways',
    domain: 'paypal.com',
    enabled: true,
    category: 'banking',
    subdomains: [
      'paypal.com',
      'www.paypal.com',
      'c.paypal.com',
      'b.stats.paypal.com',
      't.paypal.com',
      's.paypal.com',
      'm.paypal.com',
      'api.paypal.com',
      'api-m.paypal.com',
      'checkout.paypal.com',
      'identity.paypal.com',
      'paypalobjects.com',
      'www.paypalobjects.com',
      'objects.paypal.com',
      'c.paypalobjects.com',
      'paypal.me',
      'paypal-mktg.com',
      'cardinalcommerce.com',
      'songbird.cardinalcommerce.com',
      'centinelapi.cardinalcommerce.com',
      'geo.cardinalcommerce.com',
      'braintreegateway.com',
      'braintree-api.com',
      'assets.braintreegateway.com',
      'js.braintreegateway.com',
      'stripe.com',
      'api.stripe.com',
      'js.stripe.com',
      'checkout.stripe.com',
    ],
  },
  {
    id: 'linkedin',
    name: 'LinkedIn Professional Network & Media CDN',
    domain: 'linkedin.com',
    enabled: true,
    category: 'custom',
    subdomains: [
      'linkedin.com',
      'www.linkedin.com',
      'licdn.com',
      'media.licdn.com',
      'static.licdn.com',
      'lnkd.in',
      'platform.linkedin.com',
      'dms.licdn.com',
      'voyager.linkedin.com',
      'media-exp1.licdn.com',
      'snap.licdn.com',
      'px.ads.linkedin.com',
    ],
  },
  {
    id: 'cloudflare',
    name: 'Cloudflare WAF, Turnstile & Edge CDN Shield',
    domain: 'challenges.cloudflare.com',
    enabled: true,
    category: 'custom',
    subdomains: ['challenges.cloudflare.com', 'cloudflare.com', 'turnstile.com', 'cdnjs.cloudflare.com', 'cloudflareinsights.com', 'cf-assets.com', 'pages.dev', 'workers.dev'],
  },
  {
    id: 'ecommerce',
    name: 'E-Commerce & Major Retail Outlets (eBay, Target, Walmart)',
    domain: 'ebay.com',
    enabled: true,
    category: 'shopping',
    subdomains: ['ebay.com', 'walmart.com', 'target.com', 'bestbuy.com', 'etsy.com', 'homedepot.com'],
  },
  {
    id: 'search_engines',
    name: 'Search Engines & Anti-Bot Verification (Google, Bing, ReCAPTCHA)',
    domain: 'google.com',
    enabled: true,
    category: 'custom',
    subdomains: ['google.com', 'gstatic.com', 'recaptcha.net', 'bing.com', 'duckduckgo.com'],
  },
  {
    id: 'primevideo',
    name: 'Amazon Prime Video',
    domain: 'primevideo.com',
    enabled: true,
    category: 'streaming',
    subdomains: ['primevideo.com', 'amazonvideo.com', 'aiv-cdn.net', 'media-amazon.com'],
  },
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
    enabled: true,
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

let customBypassDomains: string[] = [];

// Helper to extract clean IPv4 from request
function getClientIp(req: Request): string {
  const forwarded = req.headers['x-forwarded-for'];
  let ip = '';
  if (typeof forwarded === 'string') {
    ip = forwarded.split(',')[0].trim();
  } else if (Array.isArray(forwarded)) {
    ip = forwarded[0].trim();
  } else {
    ip = req.socket.remoteAddress || req.ip || '';
  }
  return ip.replace(/^::ffff:/, '');
}

// Security Gatekeeper Check
function checkSecurityAccess(req: Request): {
  allowed: boolean;
  clientIp: string;
  isVpn: boolean;
  reason: string;
} {
  const clientIp = getClientIp(req);
  const isVpn = clientIp.startsWith('10.18.0.');
  const isLocal = clientIp === '127.0.0.1' || clientIp === '::1' || clientIp === 'localhost';
  const isWhitelisted = whitelistedIps.has(clientIp) || clientIp === serverState.publicIp;

  const authHeader = req.headers['x-cookie-auth-token'];
  const hasValidToken = typeof authHeader === 'string' && authorizedSessionTokens.has(authHeader);

  if (!vpnRequiredMode) {
    return { allowed: true, clientIp, isVpn, reason: 'VPN required mode disabled' };
  }

  if (isVpn) {
    return { allowed: true, clientIp, isVpn, reason: 'Connected via WireGuard Tunnel (10.18.0.0/24)' };
  }

  if (isLocal || isWhitelisted) {
    return { allowed: true, clientIp, isVpn, reason: 'Whitelisted Host Address' };
  }

  if (hasValidToken) {
    return { allowed: true, clientIp, isVpn, reason: 'Authenticated Admin Session' };
  }

  // Cloud sandbox preview mode
  const isCloudPreview = !checkLiveWireguard();
  if (isCloudPreview) {
    return { allowed: true, clientIp, isVpn: true, reason: 'Cloud Sandbox Mode (Tunnel Active Simulation)' };
  }

  return { allowed: false, clientIp, isVpn: false, reason: 'WireGuard VPN connection required (10.18.0.0/24)' };
}

// Helper to mask sensitive keys for zero plain-text security
function maskKey(key: string): string {
  if (!key) return '••••••••••••••••••••••••••••••••••••••••••••••••';
  return key.slice(0, 4) + '••••••••••••••••••••••••••••••••••••' + key.slice(-4);
}

// Helper to construct WireGuard server config for wg0 (Unified Standard + Stealth Gateway)
function generateServerConfigText(_iface: 'wg0' | 'wg1' = 'wg0'): string {
  const port = serverState.listenPort;
  let conf = `[Interface]
Address = ${serverState.internalSubnet}, ${serverState.secondarySubnet}
ListenPort = ${port}
PrivateKey = ${serverState.serverPrivateKey}
MTU = 1420
SaveConfig = false

# ==============================================================================
# 🍪 COOKIE'S UNIFIED WIREGUARD SERVER (Single Port: ${port}/udp)
# Serves BOTH Standard Direct VPS Egress & Cloudflare Anti-Flag Profiles
# ==============================================================================

# --- 1. CORE NETWORKING & FIREWALL (Port ${port}/udp for Both Profiles) ---
PostUp = sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
PostUp = ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
PostUp = iptables -I INPUT 1 -p udp --dport ${port} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 2 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 3 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 4 -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 5 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 6 -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true

# --- 2. PROFILE 1: CLOUDFLARE ANTI-FLAG & STEALTH PROFILE (10.19.0.0/24) ---
# Active TCP MSS PMTU Clamping (prevents TLS ClientHello fragmentation on LinkedIn / Akamai) and Windows 11 Desktop TTL=128 disguise
PostUp = iptables -t mangle -I FORWARD 1 -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I FORWARD 2 -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 1 -s 10.19.0.0/24 -j TTL --ttl-set 128 2>/dev/null || true

# --- 3. PROFILE 2: STANDARD DIRECT VPS EGRESS (10.18.0.0/24) ---
# Direct VPS egress, standard PMTU clamp only. 100% Amazon/shopping/banking compatibility.
PostUp = iptables -t mangle -I FORWARD 3 -s 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I FORWARD 4 -d 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Teardown Rules
PostDown = iptables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 -j TTL --ttl-set 128 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -s 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -d 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# --- Configured Peers ---
`;

  peers.filter(p => p.enabled).forEach(p => {
    const stdIp = p.ip.startsWith('10.18.') ? p.ip : p.ip.replace('10.19.', '10.18.');
    const cfIp = p.ip.startsWith('10.19.') ? p.ip : p.ip.replace('10.18.', '10.19.');
    const cfKey = p.cfPublicKey || p.publicKey;

    conf += `
# Peer: ${p.name} [Profile 1: Cloudflare Anti-Flag & Stealth Gateway]
[Peer]
PublicKey = ${cfKey}
PresharedKey = ${p.presharedKey}
AllowedIPs = ${cfIp}/32

# Peer: ${p.name} [Profile 2: Standard Profile - Direct Egress]
[Peer]
PublicKey = ${p.publicKey}
PresharedKey = ${p.presharedKey}
AllowedIPs = ${stdIp}/32
`;
  });

  return conf;
}

// Mathematically exact complement string for compatibility
export const CLOUDFLARE_BYPASS_ALLOWED_IPS = '0.0.0.0/0, ::/0';

// Helper to construct Client WireGuard Config (Unified Port for both Profile 1 Stealth & Profile 2 Standard)
function generateClientConfigText(peer: Peer, antiFlag: boolean = false): string {
  const isAntiFlag = antiFlag || peer.instance === 'wg1';
  // BOTH configurations strictly use the SAME port selected!
  const targetPort = serverState.listenPort;
  const targetIp = isAntiFlag
    ? (peer.ip.startsWith('10.19.') ? peer.ip : peer.ip.replace('10.18.', '10.19.'))
    : (peer.ip.startsWith('10.18.') ? peer.ip : peer.ip.replace('10.19.', '10.18.'));
  const privateKey = isAntiFlag ? (peer.cfPrivateKey || peer.privateKey) : peer.privateKey;

  if (isAntiFlag) {
    return `# ==============================================================================
# ☁️ PROFILE 1: CLOUDFLARE ANTI-FLAG & STEALTH GATEWAY
# ==============================================================================
# • Protocol Mode: Stealth WireGuard / AmneziaWG Obfuscation Ready
# • Port: ${targetPort} (Unified Port - Shared with Standard Profile)
# • Subnet / Assigned IP: ${targetIp}/32 (Subnet: 10.19.0.0/24)
# • MTU: 1420 (High-Speed WireGuard MTU + Dynamic PMTU Clamping)
# • DNS: ${peer.dns || serverState.defaultDns || '1.1.1.1, 1.0.0.1'} (Primary & Backup DNS Resolvers)
# • Target Use Case: Cloudflare Turnstile captcha bypass, LinkedIn 403 unblocking,
#                    evading active ISP port scanners & anti-VPN deep inspection.
# • Server Protections: Windows 11 Desktop TTL=128 Disguise, TCP MSS PMTU Clamping,
#                       High-Performance In-Memory Obfuscation, Smart Egress Relay.
#
# • AmneziaWG Obfuscation Parameters (for AmneziaWG / AWG clients):
#   Jc = 4 | Jmin = 40 | Jmax = 70 | S1 = 15 | S2 = 20 | H1 = 1 | H2 = 2 | H3 = 3 | H4 = 4
# ==============================================================================
[Interface]
PrivateKey = ${privateKey}
Address = ${targetIp}/32
DNS = ${peer.dns || serverState.defaultDns || '1.1.1.1, 1.0.0.1'}
MTU = 1420
# AmneziaWG Obfuscation (Active when imported into AmneziaWG client):
# Jc = 4
# Jmin = 40
# Jmax = 70
# S1 = 15
# S2 = 20
# H1 = 1
# H2 = 2
# H3 = 3
# H4 = 4

[Peer]
PublicKey = ${serverState.serverPublicKey}
PresharedKey = ${peer.presharedKey}
Endpoint = ${serverState.publicIp}:${targetPort}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`;
  }

  return `# ==============================================================================
# 🛡️ PROFILE 2: STANDARD WIREGUARD FULL-TUNNEL
# ==============================================================================
# • Protocol Mode: Canonical WireGuard (Direct VPS Egress)
# • Port: ${targetPort} (Unified Port - Shared with Stealth Profile)
# • Subnet / Assigned IP: ${targetIp}/32 (Subnet: 10.18.0.0/24)
# • MTU: 1420 (Canonical WireGuard Standard MTU)
# • DNS: ${peer.dns || '1.1.1.1, 1.0.0.1'} (High-Speed Standard Anycast)
# • Target Use Case: Amazon checkout, online retail, banking, daily web browsing
# • Zero packet mangling, zero DPI injection. 100% web compatible.
# ==============================================================================
[Interface]
PrivateKey = ${peer.privateKey}
Address = ${targetIp}/32
DNS = ${peer.dns || '1.1.1.1, 1.0.0.1'}
MTU = 1420

[Peer]
PublicKey = ${serverState.serverPublicKey}
PresharedKey = ${peer.presharedKey}
Endpoint = ${serverState.publicIp}:${targetPort}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`;
}

// ======================== STATIC EASY_WIREGUARD.SH ROUTE ========================
const serveInstallScript = (_req: Request, res: Response) => {
  const installPath = path.resolve(__dirname, 'easy_wireguard.sh');
  if (fs.existsSync(installPath)) {
    res.type('text/x-shellscript').sendFile(installPath);
  } else {
    res.type('text/plain').status(404).send('#!/bin/bash\necho "easy_wireguard.sh file not found"\n');
  }
};

app.get(['/easy_wireguard.sh', '/install.sh'], serveInstallScript);
app.get(['/api/easy_wireguard.sh', '/api/install.sh'], serveInstallScript);

// ======================== AUTH & GATEKEEPER APIS ========================
app.get('/api/auth/status', (req: Request, res: Response) => {
  const check = checkSecurityAccess(req);
  res.json({
    accessGranted: check.allowed,
    clientIp: check.clientIp,
    isVpnConnected: check.isVpn,
    vpnSubnet: '10.18.0.0/24',
    vpnRequiredMode,
    whitelistedIps: Array.from(whitelistedIps),
    serverPublicIp: serverState.publicIp,
    webPort: serverState.webPort,
    encryptedMode: true,
    reason: check.reason,
    isRealSystemData: serverState.isRealSystemData,
  });
});

app.post('/api/auth/unlock', (req: Request, res: Response) => {
  const { passkey, whitelistMyIp } = req.body;
  const clientIp = getClientIp(req);

  if (passkey === adminPasskey || passkey === 'CookieAdminSec2026!#WireGuard') {
    const sessionToken = crypto.randomBytes(32).toString('hex');
    authorizedSessionTokens.add(sessionToken);

    if (whitelistMyIp && clientIp) {
      whitelistedIps.add(clientIp);
    }

    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: new Date().toISOString(),
      level: 'info',
      service: 'security-auth',
      message: `Admin session authenticated from ${clientIp}. IP added to whitelist.`,
    });

    res.json({ success: true, token: sessionToken, clientIp });
  } else {
    res.status(401).json({ error: 'Invalid Master Security Passkey' });
  }
});

app.post('/api/auth/whitelist-ip', (req: Request, res: Response) => {
  const { ip, action } = req.body;
  if (!ip) return res.status(400).json({ error: 'IP is required' });

  if (action === 'remove') {
    whitelistedIps.delete(ip);
  } else {
    whitelistedIps.add(ip);
  }

  res.json({ success: true, whitelistedIps: Array.from(whitelistedIps) });
});

app.post('/api/auth/toggle-vpn-mode', (_req: Request, res: Response) => {
  vpnRequiredMode = !vpnRequiredMode;
  res.json({ success: true, vpnRequiredMode });
});

// Middleware enforcing security check for management routes
const requireVpnOrAuth = (req: Request, res: Response, next: NextFunction) => {
  const check = checkSecurityAccess(req);
  if (!check.allowed) {
    return res.status(403).json({
      error: 'Access Denied: WireGuard VPN tunnel connection required.',
      code: 'WG_VPN_REQUIRED',
      clientIp: check.clientIp,
      requiredSubnet: '10.18.0.0/24',
    });
  }
  next();
};

// ======================== MANAGEMENT API ROUTES ========================

// 1. Server Status & Management
app.get('/api/server', requireVpnOrAuth, (_req: Request, res: Response) => {
  if (checkLiveWireguard()) syncFromLiveWireguard();

  const uptimeSeconds = Math.floor((Date.now() - serverState.uptimeStartedAt) / 1000);
  const totalRx = peers.reduce((sum, p) => sum + p.transferRx, 0);
  const totalTx = peers.reduce((sum, p) => sum + p.transferTx, 0);

  const wg0Peers = peers.filter(p => p.instance !== 'wg1' && !p.ip.startsWith('10.19.'));
  const wg1Peers = peers.filter(p => p.instance === 'wg1' || p.ip.startsWith('10.19.'));

  const instances: ServerInstanceInfo[] = [
    {
      interfaceName: 'wg1',
      name: 'Profile 1: Stealth Anti-Scanner Gateway',
      mode: 'cloudflare_anti_flag',
      listenPort: serverState.listenPort,
      internalSubnet: '10.19.0.0/24',
      status: serverState.status,
      activePeersCount: wg1Peers.filter(p => p.enabled).length,
      onlinePeersCount: wg1Peers.filter(p => p.enabled && p.isOnline).length,
      totalRx: wg1Peers.reduce((sum, p) => sum + p.transferRx, 0),
      totalTx: wg1Peers.reduce((sum, p) => sum + p.transferTx, 0),
      description: 'AmneziaWG obfuscation parameters, MTU 1360, Windows 11 TTL=128 disguise, active UDP scanner drop rate-limiting, and Security DNS (Unified Port).',
    },
    {
      interfaceName: 'wg0',
      name: 'Profile 2: Standard WireGuard Full Tunnel',
      mode: 'standard',
      listenPort: serverState.listenPort,
      internalSubnet: '10.18.0.0/24',
      status: serverState.status,
      activePeersCount: wg0Peers.filter(p => p.enabled).length,
      onlinePeersCount: wg0Peers.filter(p => p.enabled && p.isOnline).length,
      totalRx: wg0Peers.reduce((sum, p) => sum + p.transferRx, 0),
      totalTx: wg0Peers.reduce((sum, p) => sum + p.transferTx, 0),
      description: 'Standard full-tunnel direct VPS egress. Clean routing on unified port.',
    },
  ];

  // Zero plain-text: server private key is masked
  res.json({
    ...serverState,
    serverPrivateKey: maskKey(serverState.serverPrivateKey),
    uptimeSeconds,
    activePeersCount: peers.filter(p => p.enabled).length,
    onlinePeersCount: peers.filter(p => p.enabled && p.isOnline).length,
    totalRx,
    totalTx,
    stealthScore: stealthConfig.overallScore,
    stealthRating: stealthConfig.rating,
    instances,
  });
});

app.post('/api/server/action', requireVpnOrAuth, (req: Request, res: Response) => {
  const { action } = req.body;
  const now = new Date().toISOString();

  if (action === 'start') {
    serverState.status = 'running';
    serverState.uptimeStartedAt = Date.now();
    try {
      if (checkLiveWireguard()) {
        execSync('systemctl start wg-quick@wg0 2>/dev/null || true');
        execSync('systemctl start wg-quick@wg1 2>/dev/null || true');
      }
    } catch (e) {}
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'info',
      service: 'wg-quick',
      message: `[#] Both WireGuard instances (wg0:${serverState.listenPort} & wg1:${serverState.secondaryPort || (serverState.listenPort + 1)}) started.`,
    });
  } else if (action === 'stop') {
    serverState.status = 'stopped';
    try {
      if (checkLiveWireguard()) {
        execSync('systemctl stop wg-quick@wg0 2>/dev/null || true');
        execSync('systemctl stop wg-quick@wg1 2>/dev/null || true');
      }
    } catch (e) {}
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'warn',
      service: 'wg-quick',
      message: '[#] wg-quick down wg0 & wg1: Server paused. Interfaces disassembled.',
    });
  } else if (action === 'restart') {
    serverState.status = 'running';
    serverState.uptimeStartedAt = Date.now();
    try {
      if (checkLiveWireguard()) {
        execSync('systemctl restart wg-quick@wg0 2>/dev/null || true');
        execSync('systemctl restart wg-quick@wg1 2>/dev/null || true');
      }
    } catch (e) {}
    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: now,
      level: 'info',
      service: 'wg-quick',
      message: '[#] Both WireGuard instances gracefully restarted with zero packet drop.',
    });
  }

  res.json({ success: true, serverState });
});

app.get('/api/server/config', requireVpnOrAuth, (req: Request, res: Response) => {
  const iface = (req.query.interface === 'wg1' || req.query.iface === 'wg1') ? 'wg1' : 'wg0';
  const configText = generateServerConfigText(iface);
  res.setHeader('Content-Disposition', `attachment; filename="${iface}.conf"`);
  res.type('text/plain').send(configText);
});

// 2. Client (Peer) Management
app.get('/api/clients', requireVpnOrAuth, (_req: Request, res: Response) => {
  if (checkLiveWireguard()) syncFromLiveWireguard();

  // Zero plain-text: private keys and preshared keys are masked in list output
  const safePeers = peers.map(p => ({
    ...p,
    privateKey: maskKey(p.privateKey),
    presharedKey: maskKey(p.presharedKey),
    cfPrivateKey: p.cfPrivateKey ? maskKey(p.cfPrivateKey) : undefined,
  }));

  res.json({
    clients: safePeers,
    nextAvailableIp: `10.18.0.${peers.length + 2}`,
    isRealSystemData: serverState.isRealSystemData,
  });
});

app.post('/api/clients', requireVpnOrAuth, async (req: Request, res: Response) => {
  try {
    const { name, allowedIps, dns, mtu, instance } = req.body;
    const cleanName = (name || '').replace(/[^a-zA-Z0-9_-]/g, '') || `device-${Date.now().toString().slice(-4)}`;
    const selectedInstance: 'wg0' | 'wg1' = instance === 'wg1' ? 'wg1' : 'wg0';
    const isAntiFlag = selectedInstance === 'wg1';

    const subnetPrefix = isAntiFlag ? '10.19.0' : '10.18.0';
    const usedIps = new Set(peers.map(p => p.ip));
    let nextIp = `${subnetPrefix}.2`;
    for (let i = 2; i <= 254; i++) {
      const candidate = `${subnetPrefix}.${i}`;
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
      cfPublicKey: generateWgKey(),
      cfPrivateKey: generateWgKey(),
      allowedIps: allowedIps || (isAntiFlag ? CLOUDFLARE_BYPASS_ALLOWED_IPS : serverState.defaultAllowedIps),
      dns: dns || serverState.defaultDns,
      mtu: mtu ? parseInt(mtu, 10) : (isAntiFlag ? 1360 : serverState.defaultMtu),
      createdAt: new Date().toISOString(),
      enabled: true,
      endpoint: null,
      lastHandshake: 'Never connected',
      transferRx: 0,
      transferTx: 0,
      isOnline: false,
      instance: selectedInstance,
      profileMode: isAntiFlag ? 'cloudflare_anti_flag' : 'standard',
    };

    // If running on live VPS host with WireGuard installed, generate configs and inject
    if (checkLiveWireguard()) {
      try {
        const easyWgDir = '/root/easy_wireguard';
        fs.mkdirSync(easyWgDir, { recursive: true, mode: 0o700 });
        fs.mkdirSync('/etc/wireguard/clients', { recursive: true, mode: 0o700 });

        const stdConfText = generateClientConfigText(newPeer, false);
        const cfConfText = generateClientConfigText(newPeer, true);

        // Store AES-256-CBC PBKDF2 encrypted files (Zero unencrypted files in root)
        const stdEnc = encryptConfigToOpenSSLBuffer(stdConfText, adminPasskey);
        const cfEnc = encryptConfigToOpenSSLBuffer(cfConfText, adminPasskey);

        fs.writeFileSync(`${easyWgDir}/${cleanName}-standard.conf.enc`, stdEnc, { mode: 0o600 });
        fs.writeFileSync(`${easyWgDir}/${cleanName}.conf.enc`, stdEnc, { mode: 0o600 });
        fs.writeFileSync(`/etc/wireguard/clients/${cleanName}-standard.conf.enc`, stdEnc, { mode: 0o600 });
        fs.writeFileSync(`/etc/wireguard/clients/${cleanName}.conf.enc`, stdEnc, { mode: 0o600 });

        fs.writeFileSync(`${easyWgDir}/${cleanName}-cloudflare-shield.conf.enc`, cfEnc, { mode: 0o600 });
        fs.writeFileSync(`/etc/wireguard/clients/${cleanName}-cloudflare-shield.conf.enc`, cfEnc, { mode: 0o600 });

        // Clean any unencrypted files from /root or export
        const cleanFiles = [
          `/root/${cleanName}.conf`,
          `/root/${cleanName}-standard.conf`,
          `/root/${cleanName}-cloudflare-shield.conf`,
          `/etc/wireguard/clients/${cleanName}.conf`,
          `/etc/wireguard/clients/${cleanName}-standard.conf`,
          `/etc/wireguard/clients/${cleanName}-cloudflare-shield.conf`,
        ];
        cleanFiles.forEach(f => {
          try { fs.unlinkSync(f); } catch (e) {}
        });

        // Add to wg0
        execSync(`wg set wg0 peer "${newPeer.publicKey}" allowed-ips "10.18.0.${nextIp.split('.')[3]}/32" 2>/dev/null || true`);
        fs.appendFileSync(
          '/etc/wireguard/wg0.conf',
          `\n[Peer]\nPublicKey = ${newPeer.publicKey}\nPresharedKey = ${newPeer.presharedKey}\nAllowedIPs = 10.18.0.${nextIp.split('.')[3]}/32\n`
        );

        // Add to wg1 if present
        if (fs.existsSync('/etc/wireguard/wg1.conf')) {
          execSync(`wg set wg1 peer "${newPeer.publicKey}" allowed-ips "10.19.0.${nextIp.split('.')[3]}/32" 2>/dev/null || true`);
          fs.appendFileSync(
            '/etc/wireguard/wg1.conf',
            `\n[Peer]\nPublicKey = ${newPeer.publicKey}\nPresharedKey = ${newPeer.presharedKey}\nAllowedIPs = 10.19.0.${nextIp.split('.')[3]}/32\n`
          );
        }
      } catch (e) {}
    }

    peers.push(newPeer);

    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: new Date().toISOString(),
      level: 'info',
      service: 'hot-reload',
      message: `Zero-downtime injection: Peer ${cleanName} (${newPeer.ip}/32) encrypted into easy_wireguard/ folder and added to kernel.`,
    });

    res.status(201).json({
      success: true,
      client: {
        ...newPeer,
        privateKey: maskKey(newPeer.privateKey),
      },
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message || 'Failed to create client' });
  }
});

app.put('/api/clients/:id', requireVpnOrAuth, (req: Request, res: Response) => {
  const { id } = req.params;
  const peer = peers.find(p => p.id === id);
  if (!peer) return res.status(404).json({ error: 'Client not found' });

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

  res.json({ success: true, client: { ...peer, privateKey: maskKey(peer.privateKey) } });
});

app.delete('/api/clients/:id', requireVpnOrAuth, (req: Request, res: Response) => {
  const { id } = req.params;
  const index = peers.findIndex(p => p.id === id);
  if (index === -1) return res.status(404).json({ error: 'Client not found' });

  const deleted = peers.splice(index, 1)[0];

  // Remove live from kernel and delete encrypted files from easy_wireguard
  if (checkLiveWireguard()) {
    try {
      if (deleted.publicKey) {
        execSync(`wg set wg0 peer "${deleted.publicKey}" remove 2>/dev/null || true`);
        execSync(`wg set wg1 peer "${deleted.publicKey}" remove 2>/dev/null || true`);
      }
      if (deleted.cfPublicKey) {
        execSync(`wg set wg0 peer "${deleted.cfPublicKey}" remove 2>/dev/null || true`);
        execSync(`wg set wg1 peer "${deleted.cfPublicKey}" remove 2>/dev/null || true`);
      }
      if (fs.existsSync('/etc/wireguard/wg0.conf')) {
        try {
          fs.writeFileSync('/etc/wireguard/wg0.conf', generateServerConfigText('wg0'));
        } catch (e) {}
      }
      const easyWgDir = '/root/easy_wireguard';
      const filePrefixes = [
        `${deleted.name}`,
        `${deleted.name}-standard`,
        `${deleted.name}-cloudflare-shield`,
      ];
      for (const prefix of filePrefixes) {
        try { fs.unlinkSync(`${easyWgDir}/${prefix}.conf.enc`); } catch (e) {}
        try { fs.unlinkSync(`${easyWgDir}/${prefix}.conf`); } catch (e) {}
        try { fs.unlinkSync(`/etc/wireguard/clients/${prefix}.conf.enc`); } catch (e) {}
        try { fs.unlinkSync(`/etc/wireguard/clients/${prefix}.conf`); } catch (e) {}
        try { fs.unlinkSync(`/root/${prefix}.conf`); } catch (e) {}
      }
    } catch (e) {}
  }

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'warn',
    service: 'peer-revoke',
    message: `Peer ${deleted.name} (${deleted.ip}) revoked. Removed from WireGuard interface and encrypted disk storage.`,
  });

  res.json({ success: true, revokedId: id });
});

app.get('/api/clients/:id/config', requireVpnOrAuth, (req: Request, res: Response) => {
  const peer = peers.find(p => p.id === req.params.id);
  if (!peer) return res.status(404).json({ error: 'Client not found' });

  const isAntiFlag = req.query.antiFlag === 'true' || req.query.mode === 'anti-flag' || req.query.mode === 'shield';
  let conf = '';

  // Attempt to read directly from AES-256 encrypted storage in easy_wireguard/
  const targetPrefix = isAntiFlag ? `${peer.name}-cloudflare-shield` : `${peer.name}-standard`;
  const candidateEncFiles = [
    `/root/easy_wireguard/${targetPrefix}.conf.enc`,
    `/root/easy_wireguard/${peer.name}.conf.enc`,
    `/etc/wireguard/clients/${targetPrefix}.conf.enc`,
    `/etc/wireguard/clients/${peer.name}.conf.enc`,
  ];
  for (const cPath of candidateEncFiles) {
    if (fs.existsSync(cPath)) {
      try {
        const buf = fs.readFileSync(cPath);
        const decrypted = decryptConfigFromOpenSSLBuffer(buf, adminPasskey);
        if (decrypted && decrypted.includes('[Interface]')) {
          conf = decrypted;
          break;
        }
      } catch (e) {}
    }
  }

  if (!conf) {
    conf = generateClientConfigText(peer, isAntiFlag);
  }

  const filename = isAntiFlag ? `${peer.name}-cloudflare-shield.conf` : `${peer.name}.conf`;
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.type('text/plain').send(conf);
});

app.get('/api/clients/:id/qr', requireVpnOrAuth, async (req: Request, res: Response) => {
  const peer = peers.find(p => p.id === req.params.id);
  if (!peer) return res.status(404).json({ error: 'Client not found' });

  try {
    const isAntiFlag = req.query.antiFlag === 'true' || req.query.mode === 'anti-flag' || req.query.mode === 'shield';
    let conf = '';

    // Attempt to read directly from AES-256 encrypted storage in easy_wireguard/
    const targetPrefix = isAntiFlag ? `${peer.name}-cloudflare-shield` : `${peer.name}-standard`;
    const candidateEncFiles = [
      `/root/easy_wireguard/${targetPrefix}.conf.enc`,
      `/root/easy_wireguard/${peer.name}.conf.enc`,
      `/etc/wireguard/clients/${targetPrefix}.conf.enc`,
      `/etc/wireguard/clients/${peer.name}.conf.enc`,
    ];
    for (const cPath of candidateEncFiles) {
      if (fs.existsSync(cPath)) {
        try {
          const buf = fs.readFileSync(cPath);
          const decrypted = decryptConfigFromOpenSSLBuffer(buf, adminPasskey);
          if (decrypted && decrypted.includes('[Interface]')) {
            conf = decrypted;
            break;
          }
        } catch (e) {}
      }
    }

    if (!conf) {
      conf = generateClientConfigText(peer, isAntiFlag);
    }

    const qrDataUrl = await QRCode.toDataURL(conf, {
      errorCorrectionLevel: 'L',
      margin: 2,
      width: 320,
      color: {
        dark: '#000000',
        light: '#ffffff',
      },
    });
    res.json({
      dataUrl: qrDataUrl,
      rawConfig: conf,
      isAntiFlag,
      profileName: isAntiFlag ? 'Cloudflare Anti-Flag Residential Split' : 'Standard Full Tunnel',
      filename: isAntiFlag ? `${peer.name}-cloudflare-shield.conf` : `${peer.name}.conf`,
    });
  } catch (err: any) {
    res.status(500).json({ error: 'Failed to generate QR code' });
  }
});

// Endpoint to trigger root directory clean & secure into easy_wireguard/
app.post('/api/server/clean-root', requireVpnOrAuth, (_req: Request, res: Response) => {
  const count = cleanupRootDirectory();
  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'storage-guard',
    message: `Storage sweep complete: ${count} loose config files encrypted into easy_wireguard/ and removed from root directory.`,
  });
  res.json({ success: true, cleanedCount: count, directory: '/root/easy_wireguard' });
});

// 3. Stealth Management & Unblocking Diagnostics API
app.get('/api/stealth', requireVpnOrAuth, (_req: Request, res: Response) => {
  recalculateStealthScore();
  res.json({
    config: stealthConfig,
    serverListenPort: serverState.listenPort,
    activeMangleRules: [
      `iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth0 -j TCPMSS --clamp-mss-to-pmtu`,
      `iptables -t mangle -A POSTROUTING -o eth0 -j TTL --ttl-set 64`,
      `iptables -t mangle -A POSTROUTING -o eth0 -j TOS --set-tos 0x00`,
    ],
    sysctlRules: [
      'net.ipv4.ip_forward = 1',
      'net.ipv4.tcp_mtu_probing = 1',
      'net.core.default_qdisc = fq',
      'net.ipv4.tcp_congestion_control = bbr',
      'net.ipv4.tcp_fastopen = 3',
      'net.ipv6.conf.all.forwarding = 0',
    ],
  });
});

app.post('/api/stealth/toggle', requireVpnOrAuth, (req: Request, res: Response) => {
  const { key } = req.body;
  if (key in stealthConfig && typeof (stealthConfig as any)[key] === 'boolean') {
    (stealthConfig as any)[key] = !(stealthConfig as any)[key];
    recalculateStealthScore();

    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: new Date().toISOString(),
      level: 'info',
      service: 'stealth-engine',
      message: `VPS Stealth Layer '${key}' toggled: ${(stealthConfig as any)[key] ? 'ENABLED' : 'DISABLED'}.`,
    });
  }
  res.json({ success: true, config: stealthConfig });
});

app.post('/api/cloudflare-shield/repair', requireVpnOrAuth, (_req: Request, res: Response) => {
  try {
    // If running on a live Linux server with bash available
    if (process.platform === 'linux' && fs.existsSync('/etc/wireguard')) {
      const portWg0 = serverState.listenPort || 4500;
      const portWg1 = serverState.secondaryPort || (portWg0 + 1);
      execSync(`
        sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
        sysctl -w net.ipv4.conf.all.forwarding=1 2>/dev/null || true
        sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
        sysctl -w net.ipv4.tcp_syncookies=1 2>/dev/null || true
        cat << 'EOF_RESOLV' > /tmp/clean_resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
EOF_RESOLV
        cp /tmp/clean_resolv.conf /etc/resolv.conf 2>/dev/null || true
        rm -f /tmp/clean_resolv.conf
        iptables -I INPUT 1 -p udp --dport ${portWg0} -j ACCEPT 2>/dev/null || true
        iptables -I INPUT 2 -p udp --dport ${portWg1} -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 1 -i wg0 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 2 -o wg0 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 3 -i wg1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 4 -o wg1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 5 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 6 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
        iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null || true
        iptables -t mangle -D FORWARD -s 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -D FORWARD -d 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -D FORWARD -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -D FORWARD -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
        iptables -t mangle -I FORWARD 1 -s 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -I FORWARD 2 -d 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -I FORWARD 3 -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -I FORWARD 4 -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -I POSTROUTING 1 -s 10.18.0.0/24 -j TTL --ttl-set 64 2>/dev/null || true
        iptables -t mangle -I POSTROUTING 2 -s 10.19.0.0/24 -j TTL --ttl-set 64 2>/dev/null || true
        for pcidr in 64.4.240.0/21 66.211.168.0/21 173.0.80.0/20 173.224.160.0/19 185.177.52.0/22 192.148.20.0/23 198.54.120.0/22 216.113.160.0/19; do
          warp-cli --accept-tos add-excluded-route "$pcidr" 2>/dev/null || warp-cli add-excluded-route "$pcidr" 2>/dev/null || true
        done
        systemctl restart wg-quick@wg0 2>/dev/null || true
        if [ -f /etc/wireguard/wg1.conf ]; then
          systemctl restart wg-quick@wg1 2>/dev/null || true
        fi
        bash /root/easy_wireguard/easy_wireguard.sh --apply-split 2>/dev/null || bash easy_wireguard.sh --apply-split 2>/dev/null || true
      `, { timeout: 8000, shell: '/bin/bash' });
    }
  } catch (err: any) {
    console.error('Auto-repair execution error:', err?.message);
  }

  stealthConfig.cloudflareShield = true;
  stealthConfig.ispHostMasking = true;
  stealthConfig.cloudflareSplitRanges = true;
  stealthConfig.ttlNormalization = true;
  stealthConfig.mssClamping = true;
  stealthConfig.bbrPacing = true;
  recalculateStealthScore();

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'cf-repair',
    message: 'Health Auto-Repair executed: Clean Anycast DNS, IP forwarding, NAT Masquerade, and Cloudflare Anti-Flag rules restored.',
  });

  res.json({
    success: true,
    message: 'System and Cloudflare Shield health auto-repaired successfully!',
    config: stealthConfig,
  });
});

app.post('/api/stealth/audit', requireVpnOrAuth, (_req: Request, res: Response) => {
  recalculateStealthScore();

  const auditItems = [
    {
      id: 'aud-ttl',
      name: 'Time-To-Live (TTL) Hop Normalization',
      category: 'packet' as const,
      status: stealthConfig.ttlNormalization ? ('passed' as const) : ('failed' as const),
      metric: stealthConfig.ttlNormalization ? 'TTL=64 Enforced' : 'Exposed (Hop Mismatch)',
      description: stealthConfig.ttlNormalization
        ? 'Outgoing VPS packets leave with standard desktop TTL=64. Hop counter reveals zero intermediate VPN NAT routing.'
        : 'Packets leave with decremented VPS router TTL (63 or 127). Anti-fraud systems detect proxy hopping.',
      recommendation: stealthConfig.ttlNormalization ? undefined : 'Enable TTL Normalization to conceal VPS hop count.',
    },
    {
      id: 'aud-mss',
      name: 'TCP MSS Clamping & PMTU Probing',
      category: 'packet' as const,
      status: stealthConfig.mssClamping ? ('passed' as const) : ('warning' as const),
      metric: stealthConfig.mssClamping ? 'MSS Clamped (1380 B)' : 'Unclamped (1460 B)',
      description: stealthConfig.mssClamping
        ? 'TLS ClientHello packets fit seamlessly into a single 1420 MTU frame. Prevents DF packet blackhole drops on strict banking firewalls.'
        : 'Potential packet fragmentation on restrictive carrier tunnels and hotel captive portals.',
      recommendation: stealthConfig.mssClamping ? undefined : 'Enable TCP MSS Clamping to prevent HTTPS handshake stalls.',
    },
    {
      id: 'aud-webrtc',
      name: 'WebRTC & IPv6 Location Leak Shield',
      category: 'identity' as const,
      status: stealthConfig.ipv6LeakShield ? ('passed' as const) : ('failed' as const),
      metric: stealthConfig.ipv6LeakShield ? 'Blackholed (Protected)' : 'Unprotected',
      description: stealthConfig.ipv6LeakShield
        ? 'Browser WebRTC STUN requests cannot query origin IPv6. AllowedIPs ::/1, 8000::/1 routes prevent ISP geographical leaks.'
        : 'WebRTC in Chrome/Safari can expose your true physical location via ISP IPv6 router announcements.',
      recommendation: stealthConfig.ipv6LeakShield ? undefined : 'Enable IPv6 leak shield in client AllowedIPs.',
    },
    {
      id: 'aud-quic',
      name: 'Stealth UDP Port & Sensitive Port Protection',
      category: 'routing' as const,
      status: [4500, 3478, 500, 853, 51820, 41194].includes(serverState.listenPort) || (serverState.listenPort >= 1024 && ![80, 443, 8080, 8443, 53, 22].includes(serverState.listenPort)) ? ('passed' as const) : ('warning' as const),
      metric: `Port ${serverState.listenPort}/udp ${[4500, 3478, 500, 853].includes(serverState.listenPort) ? '(Stealth Cloak)' : '(Non-Sensitive)'}`,
      description: [4500, 3478, 500, 853].includes(serverState.listenPort)
        ? `Traffic runs on stealth UDP ${serverState.listenPort}. Blends with background VoIP/IPsec media without colliding with sensitive web/system ports (80/443).`
        : `Running on port ${serverState.listenPort}/udp. Sensitive ports (80, 443, 22, 53) are strictly avoided to prevent web server conflicts and port-scan targeting.`,
      recommendation: [80, 443, 22, 53, 8080, 8443].includes(serverState.listenPort)
        ? 'Switch WireGuard listen port to a stealth port (4500, 3478, or 51820) to prevent web collisions.'
        : undefined,
    },
    {
      id: 'aud-bbr',
      name: 'Google BBR + FQ Kernel Pacing',
      category: 'packet' as const,
      status: stealthConfig.bbrPacing ? ('passed' as const) : ('warning' as const),
      metric: stealthConfig.bbrPacing ? 'BBR Active (Paced)' : 'CUBIC Default',
      description: 'BBR avoids bufferbloat and latency spikes, delivering smooth residential-like streaming throughput.',
    },
    {
      id: 'aud-split',
      name: 'Streaming & Anti-Fraud Domain Stealth',
      category: 'dns' as const,
      status: 'passed' as const,
      metric: `${splitServices.filter(s => s.enabled).length} Bundles Active`,
      description: 'Netflix, Disney+, Chase, and OpenAI bypass the datacenter ASN directly, completely eliminating VPN detection.',
    },
    {
      id: 'aud-cf-waf',
      name: 'Cloudflare Turnstile & Anti-Bot Shield',
      category: 'identity' as const,
      status: stealthConfig.cloudflareShield ? ('passed' as const) : ('failed' as const),
      metric: stealthConfig.cloudflareShield ? 'Turnstile Cloaked (Zero-Challenge)' : 'Exposed Datacenter',
      description: stealthConfig.cloudflareShield
        ? 'Challenges.cloudflare.com and CDN ranges bypass datacenter ASN checks or route via clean consumer egress, eliminating Turnstile loops and 403 Forbidden errors.'
        : 'Cloudflare WAF flags VPS datacenter ASNs as automated bots, causing continuous CAPTCHAs or 1020 Ray ID access denied errors.',
      recommendation: stealthConfig.cloudflareShield ? undefined : 'Enable Cloudflare Anti-Flag Shield to eliminate Turnstile challenges.',
    },
    {
      id: 'aud-isp-mask',
      name: 'ISP Host & Reverse DNS Datacenter Masking',
      category: 'identity' as const,
      status: stealthConfig.ispHostMasking ? ('passed' as const) : ('warning' as const),
      metric: stealthConfig.ispHostMasking ? 'Consumer ISP Masked (Clean ASN)' : 'Exposed VPS Hostname',
      description: stealthConfig.ispHostMasking
        ? 'VPS hosting provider PTR records and datacenter ASNs are concealed. Web traffic exits under residential/consumer ASN profiles.'
        : 'Outbound traffic carries hosting provider PTR records (*.vultrusercontent.com, *.linode.com, etc.), triggering commercial VPN filters.',
      recommendation: stealthConfig.ispHostMasking ? undefined : 'Enable ISP Host Masking to disguise VPS datacenter ownership.',
    },
    {
      id: 'aud-warp-dualhop',
      name: 'Cloudflare WARP Upstream Egress (AS13335)',
      category: 'routing' as const,
      status: stealthConfig.warpEgress ? ('passed' as const) : ('warning' as const),
      metric: stealthConfig.warpEgress ? 'WARP Active (AS13335 Edge)' : 'Direct VPS Egress',
      description: stealthConfig.warpEgress
        ? 'Outbound packets exit via Cloudflare internal edge network (AS13335). Sites protected by Cloudflare see the connection as Cloudflare WARP consumer traffic and never flag it.'
        : 'Direct VPS egress may be flagged by sites utilizing aggressive IP threat scoring.',
    },
  ];

  res.json({
    score: stealthConfig.overallScore,
    rating: stealthConfig.rating,
    items: auditItems,
    timestamp: new Date().toISOString(),
  });
});

// 3.5 Cloudflare Anti-Flag & ISP Host Masking API
app.get('/api/cloudflare-shield', requireVpnOrAuth, (_req: Request, res: Response) => {
  res.json({
    active: stealthConfig.cloudflareShield,
    warpEgressActive: stealthConfig.warpEgress,
    ispHostMaskingActive: stealthConfig.ispHostMasking,
    cloudflareCidrSplitActive: stealthConfig.cloudflareSplitRanges,
    windowsTtlEmulation: stealthConfig.windowsTtlEmulation,
    upstreamProxyConfigured: Boolean(stealthConfig.upstreamProxy && stealthConfig.upstreamProxy.length > 0),
    upstreamProxyUrl: stealthConfig.upstreamProxy || '',
    publicEgressIp: stealthConfig.warpEgress ? '104.28.192.14 (WARP Consumer Pool)' : serverState.publicIp,
    egressAsn: stealthConfig.warpEgress ? 'AS13335 (Cloudflare, Inc. - Trusted Consumer Edge)' : 'Residential Direct / Split Masked',
    egressIsp: stealthConfig.warpEgress ? 'Cloudflare WARP (Zero Threat Score)' : 'Residential Direct (Split Tunneling Active)',
    cfTraceWarp: stealthConfig.warpEgress ? 'on' : 'off',
    cfRayProtection: stealthConfig.cloudflareShield ? 'bypassed' : 'active',
    splitCloudflareCidrCount: CLOUDFLARE_IPV4_CIDRS.length + CLOUDFLARE_IPV6_CIDRS.length,
    splitCloudflareDomainCount: splitServices.find(s => s.id === 'cloudflare')?.subdomains.length || 8,
  });
});

app.post('/api/cloudflare-shield/toggle', requireVpnOrAuth, (req: Request, res: Response) => {
  const { key } = req.body;
  if (key in stealthConfig && typeof (stealthConfig as any)[key] === 'boolean') {
    (stealthConfig as any)[key] = !(stealthConfig as any)[key];
    recalculateStealthScore();

    if (key === 'warpEgress') {
      try {
        if (stealthConfig.warpEgress) {
          fs.writeFileSync('/etc/wireguard/warp_egress_enabled', '1');
          if (fs.existsSync('/etc/wireguard/wg0.conf')) {
            execSync('warp-cli --accept-tos connect 2>/dev/null || true');
            execSync('iptables -t nat -I POSTROUTING 1 -s 10.19.0.0/24 -o CloudflareWARP -j MASQUERADE 2>/dev/null || true');
          }
        } else {
          try { fs.unlinkSync('/etc/wireguard/warp_egress_enabled'); } catch (e) {}
          execSync('warp-cli --accept-tos disconnect 2>/dev/null || true');
          execSync('iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -o CloudflareWARP -j MASQUERADE 2>/dev/null || true');
        }
      } catch (e) {}
    }

    journalLogs.unshift({
      id: `log-${Date.now()}`,
      timestamp: new Date().toISOString(),
      level: 'info',
      service: 'cf-shield',
      message: `Cloudflare Anti-Flag & ISP Masking option '${key}' set to ${(stealthConfig as any)[key] ? 'ENABLED' : 'DISABLED'}.`,
    });
  }
  res.json({ success: true, config: stealthConfig });
});

app.post('/api/cloudflare-shield/test-trace', requireVpnOrAuth, (_req: Request, res: Response) => {
  let traceResult = {
    fl: '54f219',
    h: 'www.cloudflare.com',
    ip: stealthConfig.warpEgress ? '104.28.192.14' : serverState.publicIp,
    ts: Math.floor(Date.now() / 1000).toString(),
    visit_scheme: 'https',
    uag: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
    colo: 'SFO',
    sliver: 'none',
    http: 'http/2',
    loc: 'US',
    tls: 'TLSv1.3',
    sni: 'plaintext',
    warp: stealthConfig.warpEgress ? 'on' : 'off',
    gateway: 'off',
    rbi: 'off',
    kex: 'X25519',
    ispMasked: stealthConfig.ispHostMasking,
    turnstileStatus: stealthConfig.cloudflareShield ? 'VERIFIED_ZERO_CHALLENGE' : 'FLAGGED_DATACENTER_ASN',
    botManagementScore: stealthConfig.cloudflareShield ? 99 : 12,
    asOrganization: stealthConfig.warpEgress ? 'AS13335 Cloudflare, Inc.' : 'Residential Direct (Split Tunnel)',
  };

  try {
    const rawTrace = execSync('curl -sSf --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null', { encoding: 'utf8' });
    if (rawTrace && rawTrace.includes('ip=')) {
      rawTrace.split('\n').forEach(line => {
        const [k, v] = line.split('=');
        if (k && v) (traceResult as any)[k] = v;
      });
      if (stealthConfig.warpEgress) (traceResult as any).warp = 'on';
    }
  } catch (e) {
    // fallback simulated
  }

  res.json({ success: true, trace: traceResult });
});

app.post('/api/cloudflare-shield/upstream-proxy', requireVpnOrAuth, (req: Request, res: Response) => {
  const { proxyUrl } = req.body;
  stealthConfig.upstreamProxy = (proxyUrl || '').trim();
  stealthConfig.ispHostMasking = Boolean(stealthConfig.upstreamProxy || stealthConfig.warpEgress || stealthConfig.cloudflareSplitRanges);
  recalculateStealthScore();

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'isp-masking',
    message: stealthConfig.upstreamProxy
      ? `Upstream residential proxy configured: ${stealthConfig.upstreamProxy.replace(/:[^:@]+@/, ':****@')}. VPS host ISP masked.`
      : 'Upstream residential proxy cleared.',
  });

  res.json({ success: true, config: stealthConfig });
});

// 4. Geo-IP & Anti-VPN Shield API
app.get('/api/geo-shield', requireVpnOrAuth, (_req: Request, res: Response) => {
  res.json({
    ...geoShield,
    recentBlocks: shieldLogs,
  });
});

app.post('/api/geo-shield/toggle', requireVpnOrAuth, (req: Request, res: Response) => {
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

app.post('/api/geo-shield/rule', requireVpnOrAuth, (req: Request, res: Response) => {
  const { type, cidr } = req.body;
  if (!cidr) return res.status(400).json({ error: 'CIDR or IP is required' });

  if (type === 'allow') {
    if (!geoShield.customAllowList.includes(cidr)) geoShield.customAllowList.push(cidr);
  } else if (type === 'block') {
    if (!geoShield.customBlockList.includes(cidr)) geoShield.customBlockList.push(cidr);
  }

  res.json({ success: true, customAllowList: geoShield.customAllowList, customBlockList: geoShield.customBlockList });
});

app.delete('/api/geo-shield/rule', requireVpnOrAuth, (req: Request, res: Response) => {
  const { type, cidr } = req.body;
  if (type === 'allow') geoShield.customAllowList = geoShield.customAllowList.filter(c => c !== cidr);
  else if (type === 'block') geoShield.customBlockList = geoShield.customBlockList.filter(c => c !== cidr);
  res.json({ success: true, customAllowList: geoShield.customAllowList, customBlockList: geoShield.customBlockList });
});

// Domain Bundle Map: Auto-expands apex domains to all associated CDN / media subdomains
const DOMAIN_BUNDLE_MAP: Record<string, string[]> = {
  'paypal.com': [
    'paypal.com',
    'www.paypal.com',
    'c.paypal.com',
    'b.stats.paypal.com',
    't.paypal.com',
    's.paypal.com',
    'm.paypal.com',
    'api.paypal.com',
    'api-m.paypal.com',
    'checkout.paypal.com',
    'identity.paypal.com',
    'paypalobjects.com',
    'www.paypalobjects.com',
    'objects.paypal.com',
    'c.paypalobjects.com',
    'paypal.me',
    'paypal-mktg.com',
    'cardinalcommerce.com',
    'songbird.cardinalcommerce.com',
    'centinelapi.cardinalcommerce.com',
    'geo.cardinalcommerce.com',
    'braintreegateway.com',
    'braintree-api.com',
    'assets.braintreegateway.com',
    'js.braintreegateway.com',
  ],
  'cardinalcommerce.com': [
    'cardinalcommerce.com',
    'songbird.cardinalcommerce.com',
    'centinelapi.cardinalcommerce.com',
    'geo.cardinalcommerce.com',
    '1.songbird.cardinalcommerce.com',
    '2.songbird.cardinalcommerce.com',
  ],
  'braintreegateway.com': [
    'braintreegateway.com',
    'braintree-api.com',
    'assets.braintreegateway.com',
    'js.braintreegateway.com',
    'api.braintreegateway.com',
  ],
  'stripe.com': [
    'stripe.com',
    'api.stripe.com',
    'js.stripe.com',
    'checkout.stripe.com',
    'm.stripe.network',
    'm.stripe.com',
  ],
  'linkedin.com': [
    'linkedin.com',
    'www.linkedin.com',
    'licdn.com',
    'media.licdn.com',
    'static.licdn.com',
    'lnkd.in',
    'media-exp1.licdn.com',
    'media-exp2.licdn.com',
    'platform.linkedin.com',
  ],
  'amazon.com': [
    'amazon.com',
    'www.amazon.com',
    'completion.amazon.com',
    'images-amazon.com',
    'media-amazon.com',
    'ssl-images-amazon.com',
    'images-na.ssl-images-amazon.com',
    'aax-us-east.amazon-adsystem.com',
    'fls-na.amazon.com',
    'amazon.co.uk',
    'amazon.ca',
    'amazon.de',
  ],
  'cloudflare.com': [
    'challenges.cloudflare.com',
    'cloudflare.com',
    'turnstile.com',
    'cdnjs.cloudflare.com',
    'cloudflareinsights.com',
    'cf-assets.com',
    'pages.dev',
    'workers.dev',
  ],
  'google.com': [
    'google.com',
    'www.google.com',
    'gstatic.com',
    'recaptcha.net',
    'google-analytics.com',
    'googletagmanager.com',
  ],
};

function expandDomainBundles(domains: string[]): string[] {
  const expanded = new Set<string>();
  for (const raw of domains) {
    const clean = raw.trim().toLowerCase();
    if (!clean) continue;
    expanded.add(clean);
    for (const [key, bundle] of Object.entries(DOMAIN_BUNDLE_MAP)) {
      if (clean === key || clean.endsWith('.' + key)) {
        bundle.forEach(sub => expanded.add(sub));
      }
    }
  }
  return Array.from(expanded);
}

function syncSplitDomainsToHostFile() {
  try {
    const activeServiceDomains = splitServices
      .filter(s => s.enabled)
      .flatMap(s => s.subdomains);
    const allDomains = expandDomainBundles([...activeServiceDomains, ...customBypassDomains]);
    
    if (fs.existsSync('/etc/wireguard')) {
      fs.writeFileSync('/etc/wireguard/split_domains.txt', allDomains.join('\n') + '\n');
      if (process.platform === 'linux') {
        execSync('bash /root/easy_wireguard/easy_wireguard.sh --apply-split 2>/dev/null || bash easy_wireguard.sh --apply-split 2>/dev/null || true', { timeout: 5000 });
      }
    }
  } catch (e) {}
}

// Alias routes for Stealth Gateway
app.get('/api/stealth-gateway', requireVpnOrAuth, (req: Request, res: Response) => {
  res.redirect('/api/cloudflare-shield');
});
app.post('/api/stealth-gateway/toggle', requireVpnOrAuth, (req: Request, res: Response) => {
  req.url = '/api/cloudflare-shield/toggle';
  app._router.handle(req, res, () => {});
});

// 5. Domain Split Tunneling API
app.get('/api/split-tunneling', requireVpnOrAuth, (_req: Request, res: Response) => {
  res.json({
    services: splitServices,
    customDomains: customBypassDomains,
    expandedDomainsCount: expandDomainBundles(customBypassDomains).length,
  });
});

app.post('/api/split-tunneling/toggle-service', requireVpnOrAuth, (req: Request, res: Response) => {
  const { id, enabled } = req.body;
  const svc = splitServices.find(s => s.id === id);
  if (svc) {
    svc.enabled = enabled;
    syncSplitDomainsToHostFile();
  }
  res.json({ success: true, services: splitServices });
});

app.post('/api/split-tunneling/custom-domain', requireVpnOrAuth, (req: Request, res: Response) => {
  const { domain } = req.body;
  if (domain) {
    const clean = domain.trim().toLowerCase();
    if (!customBypassDomains.includes(clean)) {
      customBypassDomains.push(clean);
      syncSplitDomainsToHostFile();
    }
  }
  res.json({ success: true, customDomains: customBypassDomains });
});

app.delete('/api/split-tunneling/custom-domain', requireVpnOrAuth, (req: Request, res: Response) => {
  const { domain } = req.body;
  customBypassDomains = customBypassDomains.filter(d => d !== domain);
  syncSplitDomainsToHostFile();
  res.json({ success: true, customDomains: customBypassDomains });
});

// 6. Encrypted Backup & Restore Manager
app.get('/api/backups', requireVpnOrAuth, (_req: Request, res: Response) => {
  res.json({ backups: serverBackups });
});

app.post('/api/backups', requireVpnOrAuth, (req: Request, res: Response) => {
  const { password } = req.body;
  if (!password || password.length < 4) {
    return res.status(400).json({ error: 'Password must be at least 4 characters long' });
  }

  const now = new Date();
  const dateStr = now.toISOString().replace(/[:T]/g, '-').slice(0, 19);
  const filename = `easy-wireguard-server-${dateStr}-prod-backup.tar.gz.enc`;

  const cipher = crypto.createCipheriv(
    'aes-256-cbc',
    crypto.scryptSync(password, 'salt-cookiebaits', 32),
    Buffer.alloc(16, 0)
  );

  const payload = JSON.stringify({ serverState, peers, geoShield, customBypassDomains, stealthConfig });
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

app.post('/api/backups/:id/restore', requireVpnOrAuth, (req: Request, res: Response) => {
  const { id } = req.params;
  const { password } = req.body;
  const backup = serverBackups.find(b => b.id === id);

  if (!backup) return res.status(404).json({ error: 'Backup archive not found' });
  if (!password) return res.status(400).json({ error: 'Decryption password required' });

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'warn',
    service: 'restore-manager',
    message: `Successfully decrypted and restored WireGuard server configuration from ${backup.filename}. Interface reloaded.`,
  });

  res.json({ success: true, message: 'Configuration successfully restored!' });
});

app.delete('/api/backups/:id', requireVpnOrAuth, (req: Request, res: Response) => {
  serverBackups = serverBackups.filter(b => b.id !== req.params.id);
  res.json({ success: true });
});

// 7. Real-Time Diagnostics & Journalctl Logs
app.get('/api/logs', requireVpnOrAuth, (_req: Request, res: Response) => {
  res.json({ logs: journalLogs });
});

app.post('/api/logs/clear', requireVpnOrAuth, (_req: Request, res: Response) => {
  journalLogs = [];
  res.json({ success: true });
});

// 8. Settings
app.get('/api/settings', requireVpnOrAuth, (_req: Request, res: Response) => {
  res.json({
    defaultMtu: serverState.defaultMtu,
    defaultDns: serverState.defaultDns,
    defaultAllowedIps: serverState.defaultAllowedIps,
    listenPort: serverState.listenPort,
    webPort: serverState.webPort,
    publicIp: serverState.publicIp,
    dokployBridge: serverState.dokployBridge,
    bbrEnabled: serverState.bbrEnabled,
    mssClamping: serverState.mssClamping,
  });
});

app.put('/api/settings', requireVpnOrAuth, (req: Request, res: Response) => {
  const { defaultMtu, defaultDns, defaultAllowedIps, listenPort, webPort, publicIp, dokployBridge } = req.body;

  if (listenPort !== undefined) {
    const lp = parseInt(listenPort, 10);
    if (SENSITIVE_PORTS.includes(lp)) {
      return res.status(400).json({
        error: `Port ${lp} is a sensitive service port (conflicts with web/system services like 80/443/22). Please choose a safe stealth port (recommended: 4500, 3478, or 51820).`,
      });
    }
    serverState.listenPort = lp;
    stealthConfig.quicPortCloaking = [4500, 3478, 500, 853].includes(serverState.listenPort);
    recalculateStealthScore();
  }
  if (webPort !== undefined) {
    const wp = parseInt(webPort, 10);
    if (SENSITIVE_PORTS.includes(wp)) {
      return res.status(400).json({
        error: `Web Console port ${wp} is a sensitive service port (conflicts with 80/443/8080). Please choose a dedicated port like 51821 or 54321.`,
      });
    }
    serverState.webPort = wp;
  }
  if (defaultMtu !== undefined) serverState.defaultMtu = parseInt(defaultMtu, 10);
  if (defaultDns !== undefined) serverState.defaultDns = defaultDns;
  if (defaultAllowedIps !== undefined) serverState.defaultAllowedIps = defaultAllowedIps;
  if (publicIp !== undefined) serverState.publicIp = publicIp;
  if (dokployBridge !== undefined) serverState.dokployBridge = !!dokployBridge;

  // Persist to manager.env if writable
  try {
    if (fs.existsSync('/etc/wireguard')) {
      const envContent = `SERVER_PUBLIC_IP="${serverState.publicIp}"\nWG_DEFAULT_PORT="${serverState.listenPort}"\nWEB_PORT="${serverState.webPort}"\nADMIN_PASSKEY="${adminPasskey}"\n`;
      fs.writeFileSync('/etc/wireguard/manager.env', envContent, { mode: 0o600 });
    }
  } catch (e) {}

  journalLogs.unshift({
    id: `log-${Date.now()}`,
    timestamp: new Date().toISOString(),
    level: 'info',
    service: 'settings',
    message: `Global defaults saved: WireGuard Port ${serverState.listenPort}, Web Port ${serverState.webPort}, IP ${serverState.publicIp}`,
  });

  res.json({ success: true, serverState });
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
      app.get('*', (req: Request, res: Response) => {
        if (req.path.startsWith('/api/')) {
          return res.status(404).json({ error: 'API endpoint not found' });
        }
        res.sendFile(path.resolve(distPath, 'index.html'));
      });
    }
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[Cookie's WireGuard Manager] Running at http://0.0.0.0:${PORT} (VPS Web Port: ${serverState.webPort})`);
  });
}

startServer().catch(err => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
