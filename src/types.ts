export interface ServerState {
  status: 'running' | 'stopped';
  interfaceName: string;
  publicIp: string;
  listenPort: number;
  internalSubnet: string;
  serverPublicKey: string;
  serverPrivateKey: string;
  ipForwarding: boolean;
  bbrEnabled: boolean;
  mssClamping: boolean;
  dokployBridge: boolean;
  defaultMtu: number;
  defaultDns: string;
  defaultAllowedIps: string;
  uptimeSeconds: number;
  activePeersCount: number;
  onlinePeersCount: number;
  totalRx: number;
  totalTx: number;
}

export interface Peer {
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
  transferRx: number;
  transferTx: number;
  isOnline: boolean;
}

export interface ShieldBlockLog {
  id: string;
  ip: string;
  country: string;
  flag: string;
  reason: string;
  port: number;
  timestamp: string;
}

export interface GeoShieldState {
  enabled: boolean;
  mode: 'US_CA_ONLY' | 'CUSTOM' | 'ALL_PERMITTED';
  blockCommercialVpns: boolean;
  blockDatacenters: boolean;
  kernelIpsetActive: boolean;
  allowedSubnetsCount: number;
  blockedSubnetsCount: number;
  totalBlockedAttempts: number;
  lastDatabaseUpdate: string;
  customAllowList: string[];
  customBlockList: string[];
  recentBlocks: ShieldBlockLog[];
}

export interface SplitService {
  id: string;
  name: string;
  domain: string;
  enabled: boolean;
  category: 'streaming' | 'ai' | 'banking' | 'custom';
  subdomains: string[];
}

export interface BackupItem {
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

export interface LogEntry {
  id: string;
  timestamp: string;
  level: 'info' | 'warn' | 'error' | 'shield';
  service: string;
  message: string;
}
