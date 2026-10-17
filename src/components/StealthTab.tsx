import React, { useState, useEffect } from 'react';
import {
  ShieldCheck,
  EyeOff,
  Activity,
  Terminal,
  Zap,
  CheckCircle2,
  AlertTriangle,
  RefreshCw,
  Copy,
  Check,
  Download,
  HelpCircle,
  Cpu,
  Layers,
  Lock,
  Wifi
} from 'lucide-react';
import { StealthConfig, StealthAuditItem } from '../types';

interface StealthTabProps {
  onRefresh: () => void;
}

export const StealthTab: React.FC<StealthTabProps> = ({ onRefresh }) => {
  const [config, setConfig] = useState<StealthConfig | null>(null);
  const [listenPort, setListenPort] = useState<number>(51820);
  const [activeMangleRules, setActiveMangleRules] = useState<string[]>([]);
  const [sysctlRules, setSysctlRules] = useState<string[]>([]);
  const [auditItems, setAuditItems] = useState<StealthAuditItem[]>([]);
  const [loadingAudit, setLoadingAudit] = useState(false);
  const [togglingKey, setTogglingKey] = useState<string | null>(null);
  const [copiedScriptCmd, setCopiedScriptCmd] = useState(false);

  const vpsCurlCmd = `curl -sSfL https://raw.githubusercontent.com/cookiebaits/cbwireguard/main/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh`;

  const fetchStealth = async () => {
    try {
      const res = await fetch('/api/stealth');
      const data = await res.json();
      setConfig(data.config);
      setListenPort(data.serverListenPort);
      setActiveMangleRules(data.activeMangleRules);
      setSysctlRules(data.sysctlRules);
    } catch (e) {
      console.error(e);
    }
  };

  const runAudit = async () => {
    setLoadingAudit(true);
    try {
      const res = await fetch('/api/stealth/audit', { method: 'POST' });
      const data = await res.json();
      setAuditItems(data.items);
    } catch (e) {
      console.error(e);
    } finally {
      setLoadingAudit(false);
    }
  };

  useEffect(() => {
    fetchStealth();
    runAudit();
  }, []);

  const handleToggle = async (key: string) => {
    setTogglingKey(key);
    try {
      const res = await fetch('/api/stealth/toggle', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key }),
      });
      const data = await res.json();
      setConfig(data.config);
      runAudit();
      onRefresh();
    } catch (e) {
      console.error(e);
    } finally {
      setTogglingKey(null);
    }
  };

  const handleCopyCmd = () => {
    navigator.clipboard.writeText(vpsCurlCmd);
    setCopiedScriptCmd(true);
    setTimeout(() => setCopiedScriptCmd(false), 2000);
  };

  const handleDownloadInstallSh = () => {
    window.location.href = '/install.sh';
  };

  return (
    <div className="space-y-6">
      {/* Hero Banner: Stealth Score & VPS Architecture */}
      <div className="bg-gradient-to-r from-[#0d1627] via-[#141e34] to-[#0d1627] border border-slate-800 rounded-3xl p-6 sm:p-8 shadow-2xl relative overflow-hidden">
        <div className="flex flex-col lg:flex-row lg:items-center justify-between gap-6">
          <div className="flex items-start gap-4">
            <div className="p-3.5 rounded-2xl bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 shadow-lg shadow-emerald-950">
              <EyeOff className="w-8 h-8" />
            </div>
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="text-xl font-black text-white">VPS Stealth & Standard Site Unblocking Engine</h2>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-emerald-500/20 text-emerald-300 border border-emerald-500/30 font-bold">
                  Normal Traffic Emulation Active
                </span>
              </div>
              <p className="text-xs sm:text-sm text-slate-300 mt-1.5 max-w-2xl leading-relaxed">
                Personal VPS WireGuard hosting often gets flagged by anti-fraud engines due to mismatched TTL router hops, TLS packet fragmentation, or obvious UDP port profiles. This engine normalizes packets at the Linux kernel level so your personal VPS traffic looks identical to standard residential desktop browsing.
              </p>
            </div>
          </div>

          {/* Stealth Rating Badge */}
          <div className="bg-[#070b14] border border-slate-800 p-5 rounded-2xl flex flex-col items-center justify-center min-w-[210px] text-center shrink-0">
            <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider">Stealth Cloaking Score</span>
            <div className="text-3xl font-black text-emerald-400 font-mono my-1 flex items-baseline gap-1">
              {config?.overallScore ?? 94}
              <span className="text-sm font-normal text-slate-400">/ 100</span>
            </div>
            <span className="text-xs font-semibold text-purple-300 max-w-[180px] leading-tight">
              {config?.rating ?? 'Tier 1 Stealth (Concealed VPS Hop)'}
            </span>
          </div>
        </div>

        {/* Quick Highlights */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-6 pt-6 border-t border-slate-800/80 text-xs">
          <div>
            <span className="text-slate-400 font-medium">TTL Hop Masking:</span>
            <div className="font-bold text-slate-100 flex items-center gap-1.5 mt-0.5">
              <span className="w-2 h-2 rounded-full bg-emerald-400"></span>
              TTL=64 Desktop Normalization
            </div>
          </div>
          <div>
            <span className="text-slate-400 font-medium">Anti-Fragmentation:</span>
            <div className="font-bold text-slate-100 flex items-center gap-1.5 mt-0.5">
              <span className="w-2 h-2 rounded-full bg-emerald-400"></span>
              TCPMSS Clamp & PMTU Probe
            </div>
          </div>
          <div>
            <span className="text-slate-400 font-medium">WebRTC Leak Shield:</span>
            <div className="font-bold text-slate-100 flex items-center gap-1.5 mt-0.5">
              <span className="w-2 h-2 rounded-full bg-emerald-400"></span>
              IPv6 Subnet Blackhole (::/1)
            </div>
          </div>
          <div>
            <span className="text-slate-400 font-medium">Port Profile:</span>
            <div className="font-bold text-slate-100 flex items-center gap-1.5 mt-0.5">
              <span className="w-2 h-2 rounded-full bg-purple-400"></span>
              {listenPort === 443 ? 'HTTP/3 QUIC (Port 443)' : `Port ${listenPort}/udp`}
            </div>
          </div>
        </div>
      </div>

      {/* Main Grid: Toggles & Stealth Audit */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Stealth Optimizations Controls */}
        <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-bold text-white flex items-center gap-2">
              <Layers className="w-4 h-4 text-emerald-400" />
              VPS Stealth Optimization Layers
            </h3>
            <span className="text-[11px] text-slate-400">Zero extra software needed</span>
          </div>

          <div className="space-y-3">
            {/* 1. TTL Normalization */}
            <div className="p-3.5 rounded-xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
              <div>
                <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                  TTL Hop Normalization (TTL = 64)
                  <span className="text-[10px] px-1.5 py-0.2 rounded bg-emerald-500/10 text-emerald-400 font-mono">
                    iptables -j TTL
                  </span>
                </div>
                <div className="text-[11px] text-slate-400 mt-0.5">
                  Rewrites the Time-to-Live on all outgoing VPS packets to 64. Prevents websites and banks from counting router hops and identifying a cloud datacenter proxy.
                </div>
              </div>
              <button
                onClick={() => handleToggle('ttlNormalization')}
                disabled={togglingKey === 'ttlNormalization'}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                  config?.ttlNormalization ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'
                }`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            {/* 2. TCP MSS Clamping */}
            <div className="p-3.5 rounded-xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
              <div>
                <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                  TCP MSS Clamping & Anti-Fragmentation
                  <span className="text-[10px] px-1.5 py-0.2 rounded bg-emerald-500/10 text-emerald-400 font-mono">
                    --clamp-mss-to-pmtu
                  </span>
                </div>
                <div className="text-[11px] text-slate-400 mt-0.5">
                  Prevents oversized TLS ClientHello packets from fragmenting with DF flags, resolving site hangs on strict banking and corporate networks.
                </div>
              </div>
              <button
                onClick={() => handleToggle('mssClamping')}
                disabled={togglingKey === 'mssClamping'}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                  config?.mssClamping ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'
                }`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            {/* 3. PLPMTUD Probing */}
            <div className="p-3.5 rounded-xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
              <div>
                <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                  Path MTU Discovery Probing (PLPMTUD)
                  <span className="text-[10px] px-1.5 py-0.2 rounded bg-purple-500/10 text-purple-400 font-mono">
                    tcp_mtu_probing=1
                  </span>
                </div>
                <div className="text-[11px] text-slate-400 mt-0.5">
                  Dynamically detects Path MTU blackholes across mobile carrier networks and restrictive public Wi-Fi hotspots.
                </div>
              </div>
              <button
                onClick={() => handleToggle('pmtuProbing')}
                disabled={togglingKey === 'pmtuProbing'}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                  config?.pmtuProbing ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'
                }`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            {/* 4. WebRTC & IPv6 Location Leak Shield */}
            <div className="p-3.5 rounded-xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
              <div>
                <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                  WebRTC & IPv6 Geolocation Shield
                  <span className="text-[10px] px-1.5 py-0.2 rounded bg-emerald-500/10 text-emerald-400 font-mono">
                    ::/1 Blackhole
                  </span>
                </div>
                <div className="text-[11px] text-slate-400 mt-0.5">
                  Blocks WebRTC STUN requests in Chrome/Safari from resolving your true residential physical location through ISP IPv6 leaks.
                </div>
              </div>
              <button
                onClick={() => handleToggle('ipv6LeakShield')}
                disabled={togglingKey === 'ipv6LeakShield'}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                  config?.ipv6LeakShield ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'
                }`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            {/* 5. ToS / DSCP Normalization */}
            <div className="p-3.5 rounded-xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
              <div>
                <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                  TOS/DSCP Deep Packet Inspection (DPI) Mask
                  <span className="text-[10px] px-1.5 py-0.2 rounded bg-purple-500/10 text-purple-400 font-mono">
                    --set-tos 0x00
                  </span>
                </div>
                <div className="text-[11px] text-slate-400 mt-0.5">
                  Clears non-standard Type of Service bits to blend WireGuard UDP packets with regular browser streaming packets.
                </div>
              </div>
              <button
                onClick={() => handleToggle('tosNormalization')}
                disabled={togglingKey === 'tosNormalization'}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                  config?.tosNormalization ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'
                }`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>
          </div>
        </div>

        {/* Live Stealth Audit & Unblock Diagnostics */}
        <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-bold text-white flex items-center gap-2">
              <ShieldCheck className="w-4 h-4 text-purple-400" />
              Stealth & Unblocking Audit
            </h3>
            <button
              onClick={runAudit}
              disabled={loadingAudit}
              className="flex items-center gap-1.5 text-xs text-emerald-400 hover:text-emerald-300 font-medium"
            >
              <RefreshCw className={`w-3.5 h-3.5 ${loadingAudit ? 'animate-spin' : ''}`} />
              <span>{loadingAudit ? 'Scanning...' : 'Re-Run Audit'}</span>
            </button>
          </div>

          <div className="space-y-3">
            {auditItems.map(item => (
              <div
                key={item.id}
                className="p-3.5 rounded-xl bg-[#070b14] border border-slate-800 flex flex-col gap-1.5"
              >
                <div className="flex items-center justify-between">
                  <span className="text-xs font-bold text-white flex items-center gap-1.5">
                    {item.status === 'passed' ? (
                      <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0" />
                    ) : item.status === 'warning' ? (
                      <AlertTriangle className="w-4 h-4 text-amber-400 shrink-0" />
                    ) : (
                      <AlertTriangle className="w-4 h-4 text-red-400 shrink-0" />
                    )}
                    {item.name}
                  </span>
                  <span
                    className={`text-[10px] font-mono px-2 py-0.5 rounded-md font-semibold ${
                      item.status === 'passed'
                        ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                        : item.status === 'warning'
                        ? 'bg-amber-500/10 text-amber-400 border border-amber-500/20'
                        : 'bg-red-500/10 text-red-400 border border-red-500/20'
                    }`}
                  >
                    {item.metric}
                  </span>
                </div>
                <p className="text-[11px] text-slate-400 leading-relaxed">{item.description}</p>
                {item.recommendation && (
                  <p className="text-[11px] text-purple-300 font-medium mt-0.5">
                    💡 Tip: {item.recommendation}
                  </p>
                )}
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Production VPS install.sh Execution Box */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-sm font-bold text-white flex items-center gap-2">
              <Terminal className="w-4 h-4 text-emerald-400" />
              Direct VPS Installer Script (`install.sh`)
            </h3>
            <p className="text-xs text-slate-400">
              Run this single command on your fresh Ubuntu or Debian VPS to deploy all stealth optimizations and generate your client QR code.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={handleCopyCmd}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold shadow-md shadow-emerald-950 transition"
            >
              {copiedScriptCmd ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
              <span>{copiedScriptCmd ? 'Copied Command!' : 'Copy Command'}</span>
            </button>
            <button
              onClick={handleDownloadInstallSh}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-medium border border-slate-700 transition"
            >
              <Download className="w-3.5 h-3.5" />
              <span>Download install.sh</span>
            </button>
          </div>
        </div>

        <div className="p-4 rounded-xl bg-[#050811] border border-slate-800 text-emerald-400 font-mono text-xs overflow-x-auto select-all">
          {vpsCurlCmd}
        </div>

        {/* Applied Linux Directives Viewer */}
        <div className="pt-2">
          <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider block mb-2">
            Active Host Kernel Directives Enforced by Script:
          </span>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div className="bg-[#070b14] border border-slate-800/90 rounded-xl p-3">
              <span className="text-[11px] text-purple-400 font-semibold block mb-1.5">
                iptables Mangle Hooks (Packet Camouflage)
              </span>
              <pre className="text-[10px] font-mono text-slate-300 space-y-1 overflow-x-auto whitespace-pre-wrap leading-relaxed">
                {activeMangleRules.join('\n')}
              </pre>
            </div>
            <div className="bg-[#070b14] border border-slate-800/90 rounded-xl p-3">
              <span className="text-[11px] text-emerald-400 font-semibold block mb-1.5">
                sysctl Tuning (BBR + PLPMTUD)
              </span>
              <pre className="text-[10px] font-mono text-slate-300 space-y-1 overflow-x-auto whitespace-pre-wrap leading-relaxed">
                {sysctlRules.join('\n')}
              </pre>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
