import React, { useState } from 'react';
import { Shield, Wifi, HardDrive, Download, Copy, Check, Terminal, ExternalLink, QrCode } from 'lucide-react';
import { ServerState, Peer, GeoShieldState, LogEntry } from '../types';

interface OverviewTabProps {
  server: ServerState | null;
  peers: Peer[];
  geoShield: GeoShieldState | null;
  logs: LogEntry[];
  onSelectPeerForQr: (peer: Peer) => void;
  onOpenAddPeer: () => void;
  onNavigateToTab: (tab: string) => void;
}

export const OverviewTab: React.FC<OverviewTabProps> = ({
  server,
  peers,
  geoShield,
  logs,
  onSelectPeerForQr,
  onOpenAddPeer,
  onNavigateToTab,
}) => {
  const [copiedConf, setCopiedConf] = useState(false);
  const [serverConfText, setServerConfText] = useState<string>('');
  const [loadingConf, setLoadingConf] = useState(false);
  const [confVisible, setConfVisible] = useState(false);

  const formatBytes = (bytes: number) => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  };

  const handleFetchServerConf = async () => {
    if (serverConfText) {
      setConfVisible(!confVisible);
      return;
    }
    setLoadingConf(true);
    try {
      const res = await fetch('/api/server/config');
      const text = await res.text();
      setServerConfText(text);
      setConfVisible(true);
    } catch (e) {
      console.error(e);
    } finally {
      setLoadingConf(false);
    }
  };

  const handleCopyConf = () => {
    navigator.clipboard.writeText(serverConfText);
    setCopiedConf(true);
    setTimeout(() => setCopiedConf(false), 2000);
  };

  const handleDownloadConf = () => {
    const blob = new Blob([serverConfText], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'wg0.conf';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-6">
      {/* Metrics Row */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* Status */}
        <div className="bg-[#0f172a]/90 border border-slate-800 rounded-2xl p-5 shadow-lg relative overflow-hidden group hover:border-emerald-500/40 transition">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Interface wg0</span>
            <span className={`w-2.5 h-2.5 rounded-full ${server?.status === 'running' ? 'bg-emerald-400 shadow-lg shadow-emerald-400/50 animate-ping' : 'bg-red-400'}`} />
          </div>
          <div className="mt-3">
            <div className="text-2xl font-black text-white flex items-center gap-2">
              {server?.status === 'running' ? 'ONLINE' : 'STOPPED'}
              <span className="text-xs px-2 py-0.5 rounded bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 font-mono">
                Port {server?.listenPort}
              </span>
            </div>
            <p className="text-xs text-slate-400 mt-1 font-mono">Subnet: {server?.internalSubnet}</p>
          </div>
          <div className="mt-4 pt-3 border-t border-slate-800/80 flex items-center justify-between text-xs text-slate-400">
            <span className="flex items-center gap-1.5 text-emerald-400 font-medium">
              <span className="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
              BBR & FQ Active
            </span>
            <span>MTU {server?.defaultMtu}</span>
          </div>
        </div>

        {/* Clients */}
        <div className="bg-[#0f172a]/90 border border-slate-800 rounded-2xl p-5 shadow-lg relative overflow-hidden group hover:border-purple-500/40 transition">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Connected Peers</span>
            <Wifi className="w-4 h-4 text-purple-400" />
          </div>
          <div className="mt-3">
            <div className="text-2xl font-black text-white flex items-center gap-2">
              {server?.onlinePeersCount || 0}
              <span className="text-xs font-normal text-slate-400">/ {server?.activePeersCount || 0} active</span>
            </div>
            <p className="text-xs text-slate-400 mt-1">Zero-downtime hot reload enabled</p>
          </div>
          <div className="mt-4 pt-3 border-t border-slate-800/80 flex items-center justify-between text-xs">
            <button
              onClick={() => onNavigateToTab('peers')}
              className="text-purple-400 hover:text-purple-300 font-medium flex items-center gap-1"
            >
              Manage all clients &rarr;
            </button>
            <span className="text-slate-500">10.18.0.x</span>
          </div>
        </div>

        {/* Throughput */}
        <div className="bg-[#0f172a]/90 border border-slate-800 rounded-2xl p-5 shadow-lg relative overflow-hidden group hover:border-blue-500/40 transition">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Network Traffic</span>
            <HardDrive className="w-4 h-4 text-blue-400" />
          </div>
          <div className="mt-3">
            <div className="text-xl font-black text-white font-mono flex items-center gap-2">
              <span className="text-emerald-400 text-sm font-semibold">↓</span>
              {formatBytes(server?.totalRx || 0)}
              <span className="text-slate-600">/</span>
              <span className="text-blue-400 text-sm font-semibold">↑</span>
              {formatBytes(server?.totalTx || 0)}
            </div>
            <p className="text-xs text-slate-400 mt-1">TCPMSS clamping auto-synced</p>
          </div>
          <div className="mt-4 pt-3 border-t border-slate-800/80 flex items-center justify-between text-xs text-slate-400 font-mono">
            <span>RX Ingest</span>
            <span>TX Egress</span>
          </div>
        </div>

        {/* Geo-Shield */}
        <div className="bg-[#0f172a]/90 border border-slate-800 rounded-2xl p-5 shadow-lg relative overflow-hidden group hover:border-emerald-500/40 transition">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Geo & Anti-VPN Shield</span>
            <Shield className="w-4 h-4 text-emerald-400" />
          </div>
          <div className="mt-3">
            <div className="text-2xl font-black text-white flex items-center gap-2">
              {geoShield?.enabled ? 'ENFORCED' : 'OFF'}
              <span className="text-xs px-2 py-0.5 rounded bg-purple-500/10 text-purple-300 border border-purple-500/20 font-bold">
                US/CA Only
              </span>
            </div>
            <p className="text-xs text-slate-400 mt-1">
              Blocked {geoShield?.totalBlockedAttempts || 0} unauthorized attempts
            </p>
          </div>
          <div className="mt-4 pt-3 border-t border-slate-800/80 flex items-center justify-between text-xs">
            <button
              onClick={() => onNavigateToTab('shield')}
              className="text-emerald-400 hover:text-emerald-300 font-medium flex items-center gap-1"
            >
              Firewall rules &rarr;
            </button>
            <span className="text-slate-500 font-mono">43k+ subnets</span>
          </div>
        </div>
      </div>

      {/* Main Grid: Active Peers & Quick QR Code */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Configured Peers Section (2 Cols) */}
        <div className="lg:col-span-2 bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl">
          <div className="flex items-center justify-between mb-5">
            <div>
              <h2 className="text-base font-bold text-white flex items-center gap-2">
                Active Client Peers
                <span className="text-xs px-2 py-0.5 rounded-full bg-slate-800 text-slate-300 font-normal">
                  {peers.length} configured
                </span>
              </h2>
              <p className="text-xs text-slate-400">Scan QR codes directly or generate client configs</p>
            </div>
            <button
              onClick={onOpenAddPeer}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold shadow-md shadow-purple-950 transition"
            >
              + Add Peer
            </button>
          </div>

          <div className="space-y-3">
            {peers.map(peer => (
              <div
                key={peer.id}
                className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-xl bg-[#070b14] border border-slate-800/90 hover:border-slate-700 transition gap-4"
              >
                <div className="flex items-center gap-3.5">
                  <div className={`p-2.5 rounded-xl border ${
                    peer.isOnline
                      ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/20'
                      : 'bg-slate-800 text-slate-400 border-slate-700'
                  }`}>
                    <Wifi className="w-4 h-4" />
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-bold text-slate-100">{peer.name}</span>
                      <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full border ${
                        peer.isOnline
                          ? 'bg-emerald-500/20 text-emerald-400 border-emerald-500/30'
                          : 'bg-slate-800 text-slate-400 border-slate-700'
                      }`}>
                        {peer.isOnline ? 'Online' : 'Idle'}
                      </span>
                    </div>
                    <div className="flex flex-wrap items-center gap-2 text-xs text-slate-400 mt-0.5 font-mono">
                      <span className="text-emerald-400 font-semibold">{peer.ip}</span>
                      <span>•</span>
                      <span>Handshake: {peer.lastHandshake}</span>
                      <span>•</span>
                      <span>↓ {formatBytes(peer.transferRx)} / ↑ {formatBytes(peer.transferTx)}</span>
                    </div>
                  </div>
                </div>

                <div className="flex items-center gap-2 shrink-0 self-end sm:self-center">
                  <button
                    onClick={() => onSelectPeerForQr(peer)}
                    className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-emerald-500/10 hover:bg-emerald-500/20 text-emerald-400 text-xs font-semibold border border-emerald-500/30 transition shadow-sm"
                  >
                    <QrCode className="w-3.5 h-3.5" />
                    <span>Show QR</span>
                  </button>
                  <a
                    href={`/api/clients/${peer.id}/config`}
                    download={`${peer.name}.conf`}
                    className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-medium border border-slate-700 transition"
                  >
                    <Download className="w-3.5 h-3.5" />
                    <span className="hidden sm:inline">.conf</span>
                  </a>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Server Config & Security Features Card (1 Col) */}
        <div className="space-y-6">
          {/* Server Config Viewer */}
          <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl">
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-2">
                <Terminal className="w-4 h-4 text-emerald-400" />
                <h3 className="text-sm font-bold text-white">Live wg0.conf File</h3>
              </div>
              <button
                onClick={handleFetchServerConf}
                className="text-xs text-purple-400 hover:text-purple-300 font-medium"
              >
                {confVisible ? 'Hide' : 'Inspect'}
              </button>
            </div>
            <p className="text-xs text-slate-400 mb-4">
              Cryptographically verified configuration for the host Linux kernel WireGuard interface.
            </p>

            {confVisible && (
              <div className="space-y-3">
                {loadingConf ? (
                  <div className="p-4 text-center text-xs text-slate-400">Loading config...</div>
                ) : (
                  <>
                    <pre className="p-3 bg-[#070b14] border border-slate-800 rounded-xl text-xs font-mono text-slate-300 max-h-56 overflow-y-auto leading-relaxed select-all">
                      {serverConfText}
                    </pre>
                    <div className="flex items-center justify-end gap-2">
                      <button
                        onClick={handleCopyConf}
                        className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs border border-slate-700"
                      >
                        {copiedConf ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
                        {copiedConf ? 'Copied' : 'Copy'}
                      </button>
                      <button
                        onClick={handleDownloadConf}
                        className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-xs"
                      >
                        <Download className="w-3.5 h-3.5" />
                        Download
                      </button>
                    </div>
                  </>
                )}
              </div>
            )}

            {!confVisible && (
              <button
                onClick={handleFetchServerConf}
                className="w-full py-2.5 rounded-xl bg-slate-800/80 hover:bg-slate-800 text-slate-300 text-xs font-medium border border-slate-700/80 transition flex items-center justify-center gap-2"
              >
                <Terminal className="w-4 h-4 text-emerald-400" />
                View & Export /etc/wireguard/wg0.conf
              </button>
            )}
          </div>

          {/* Core Optimizations Card */}
          <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-bold text-white flex items-center gap-2">
                <Shield className="w-4 h-4 text-purple-400" />
                Active VPS Stealth & Hardening
              </h3>
              <button
                onClick={() => onNavigateToTab('stealth')}
                className="text-xs text-emerald-400 hover:text-emerald-300 font-semibold"
              >
                Stealth Hub &rarr;
              </button>
            </div>
            <div className="space-y-2.5 text-xs">
              <div className="flex items-start gap-2.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 mt-1.5 shrink-0" />
                <div>
                  <span className="font-semibold text-slate-200">TTL=64 Hop Normalization:</span>
                  <p className="text-slate-400 text-[11px]">Normalizes outgoing TTL to 64 so streaming sites and banks see native residential desktop traffic, hiding the VPS router hop.</p>
                </div>
              </div>
              <div className="flex items-start gap-2.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 mt-1.5 shrink-0" />
                <div>
                  <span className="font-semibold text-slate-200">TCP MSS Clamping (PMTU 1420):</span>
                  <p className="text-slate-400 text-[11px]">Prevents oversized TLS ClientHello packets from fragmenting with DF flags, resolving strict site freezes.</p>
                </div>
              </div>
              <div className="flex items-start gap-2.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 mt-1.5 shrink-0" />
                <div>
                  <span className="font-semibold text-slate-200">Anti-VPN & Geo-Shielding:</span>
                  <p className="text-slate-400 text-[11px]">Commercial VPNs & cloud hosting subnets dropped at raw kernel socket before WireGuard processing.</p>
                </div>
              </div>
              <div className="flex items-start gap-2.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 mt-1.5 shrink-0" />
                <div>
                  <span className="font-semibold text-slate-200">WebRTC IPv6 Blackhole:</span>
                  <p className="text-slate-400 text-[11px]">Natively drops IPv6 leaks (::/1, 8000::/1) to prevent physical browser location leakage.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
