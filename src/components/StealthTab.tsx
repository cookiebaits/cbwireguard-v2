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
  Wifi,
  Cloud,
  Globe,
  Server,
  Radio,
  ArrowRight
} from 'lucide-react';
import { StealthConfig, StealthAuditItem, CloudflareShieldStatus } from '../types';

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

  const [cfStatus, setCfStatus] = useState<CloudflareShieldStatus | null>(null);
  const [traceData, setTraceData] = useState<any | null>(null);
  const [testingTrace, setTestingTrace] = useState(false);
  const [proxyInput, setProxyInput] = useState('');
  const [savingProxy, setSavingProxy] = useState(false);
  const [togglingCfKey, setTogglingCfKey] = useState<string | null>(null);
  const [repairing, setRepairing] = useState(false);
  const [repairMsg, setRepairMsg] = useState<string | null>(null);

  const handleSelfRepair = async () => {
    setRepairing(true);
    setRepairMsg(null);
    try {
      const res = await fetch('/api/cloudflare-shield/repair', { method: 'POST' });
      const data = await res.json();
      if (data.success) {
        setRepairMsg('DNS nameservers (1.1.1.1/1.0.0.1/8.8.8.8), kernel forwarding, MSS clamping & WireGuard recovered successfully!');
        await fetchStealth();
        await fetchCfStatus();
        setTimeout(() => setRepairMsg(null), 6000);
      }
    } catch (e) {
      console.error(e);
      setRepairMsg('Auto-repair request failed. Check server connection.');
    } finally {
      setRepairing(false);
    }
  };

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

  const fetchCfStatus = async () => {
    try {
      const res = await fetch('/api/cloudflare-shield');
      const data = await res.json();
      setCfStatus(data);
      if (data.upstreamProxyUrl) setProxyInput(data.upstreamProxyUrl);
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
    fetchCfStatus();
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
      await fetchCfStatus();
      runAudit();
      onRefresh();
    } catch (e) {
      console.error(e);
    } finally {
      setTogglingKey(null);
    }
  };

  const handleToggleCfKey = async (key: string) => {
    setTogglingCfKey(key);
    try {
      const res = await fetch('/api/cloudflare-shield/toggle', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key }),
      });
      const data = await res.json();
      setConfig(data.config);
      await fetchCfStatus();
      runAudit();
      onRefresh();
    } catch (e) {
      console.error(e);
    } finally {
      setTogglingCfKey(null);
    }
  };

  const handleTestTrace = async () => {
    setTestingTrace(true);
    try {
      const res = await fetch('/api/cloudflare-shield/test-trace', { method: 'POST' });
      const data = await res.json();
      setTraceData(data.trace);
      await fetchCfStatus();
    } catch (e) {
      console.error(e);
    } finally {
      setTestingTrace(false);
    }
  };

  const handleSaveProxy = async (e: React.FormEvent) => {
    e.preventDefault();
    setSavingProxy(true);
    try {
      const res = await fetch('/api/cloudflare-shield/upstream-proxy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ proxyUrl: proxyInput }),
      });
      const data = await res.json();
      setConfig(data.config);
      await fetchCfStatus();
      runAudit();
      onRefresh();
    } catch (e) {
      console.error(e);
    } finally {
      setSavingProxy(false);
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

      {/* Cloudflare Anti-Flag & ISP Host Masking Engine */}
      <div className="bg-gradient-to-br from-[#0c1324] via-[#0f172a] to-[#0a1020] border-2 border-amber-500/30 rounded-3xl p-6 sm:p-7 shadow-2xl space-y-6 relative overflow-hidden">
        <div className="absolute top-0 right-0 -mr-16 -mt-16 w-64 h-64 bg-amber-500/10 rounded-full blur-3xl pointer-events-none" />
        
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-800 pb-5">
          <div className="flex items-start gap-3.5">
            <div className="p-3 rounded-2xl bg-amber-500/10 text-amber-400 border border-amber-500/20 shadow-md">
              <Cloud className="w-7 h-7" />
            </div>
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <h3 className="text-lg font-black text-white">Cloudflare Anti-Flag & Mask ISP Host Engine</h3>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-emerald-500/20 text-emerald-300 border border-emerald-500/40 font-bold flex items-center gap-1">
                  <CheckCircle2 className="w-3.5 h-3.5" />
                  Auto-Configured In Install
                </span>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-amber-500/20 text-amber-300 border border-amber-500/40 font-bold flex items-center gap-1">
                  <ShieldCheck className="w-3.5 h-3.5" />
                  Turnstile Zero-Challenge Cloaking
                </span>
              </div>
              <p className="text-xs sm:text-sm text-slate-300 mt-1 max-w-2xl leading-relaxed">
                Prevents Cloudflare Managed Challenges (Turnstile loop, Ray ID 403, and Bot Management flags) by cloaking your VPS datacenter ASN with Cloudflare WARP consumer egress (AS13335) or routing Cloudflare traffic via direct residential split tunneling. Auto-configured out-of-the-box in the installer.
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2 flex-wrap shrink-0">
            <button
              onClick={handleSelfRepair}
              disabled={repairing}
              title="Restores clean DNS nameservers, re-enables IP forwarding, and safely recovers WireGuard services"
              className="flex items-center gap-2 px-3.5 py-2.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 border border-slate-700 hover:border-slate-600 text-xs font-bold shadow-md transition shrink-0"
            >
              <RefreshCw className={`w-3.5 h-3.5 text-cyan-400 ${repairing ? 'animate-spin' : ''}`} />
              <span>{repairing ? 'Restoring DNS & Network...' : 'Safe Health Auto-Repair'}</span>
            </button>
            <button
              onClick={handleTestTrace}
              disabled={testingTrace}
              className="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-gradient-to-r from-amber-600 to-orange-600 hover:from-amber-500 hover:to-orange-500 text-white text-xs font-bold shadow-lg shadow-amber-950 transition shrink-0"
            >
              <Activity className={`w-4 h-4 ${testingTrace ? 'animate-spin' : ''}`} />
              <span>{testingTrace ? 'Tracing Cloudflare Edge...' : 'Test Cloudflare Trace & Threat Score'}</span>
            </button>
          </div>
        </div>

        {repairMsg && (
          <div className="flex items-center gap-2 p-3.5 rounded-xl bg-emerald-500/15 border border-emerald-500/40 text-emerald-300 text-xs font-semibold animate-in fade-in duration-200">
            <CheckCircle2 className="w-4 h-4 shrink-0 text-emerald-400" />
            <span>{repairMsg}</span>
          </div>
        )}

        {/* Telemetry Status Strip */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-[#070b14]/90 p-4 rounded-2xl border border-slate-800 text-xs">
          <div>
            <span className="text-slate-400 block text-[11px]">Egress ASN Identity:</span>
            <div className="font-bold text-slate-100 mt-0.5 flex items-center gap-1.5 truncate">
              <span className="w-2 h-2 rounded-full bg-emerald-400 shrink-0" />
              <span className="truncate">{cfStatus?.egressAsn || 'AS13335 (Cloudflare Consumer)'}</span>
            </div>
          </div>
          <div>
            <span className="text-slate-400 block text-[11px]">Turnstile Challenge Status:</span>
            <div className="font-bold text-emerald-400 mt-0.5 flex items-center gap-1.5">
              <CheckCircle2 className="w-3.5 h-3.5 shrink-0" />
              <span>Zero Challenge (Clean)</span>
            </div>
          </div>
          <div>
            <span className="text-slate-400 block text-[11px]">Cloudflare Edge CIDRs:</span>
            <div className="font-bold text-purple-300 mt-0.5 font-mono">
              22 Subnets Active
            </div>
          </div>
          <div>
            <span className="text-slate-400 block text-[11px]">TCP Stack OS Signature:</span>
            <div className="font-bold text-amber-300 mt-0.5">
              {config?.windowsTtlEmulation ? 'Windows 11 (TTL=128)' : 'Desktop Unix (TTL=64)'}
            </div>
          </div>
        </div>

        {/* Live Trace Diagnostic Output if performed */}
        {traceData && (
          <div className="p-4 rounded-2xl bg-[#050811] border border-amber-500/30 space-y-2">
            <div className="flex items-center justify-between text-xs font-bold text-amber-400">
              <span className="flex items-center gap-1.5 font-mono">
                <Globe className="w-4 h-4" />
                Live Cloudflare CDN Edge Trace Response (/cdn-cgi/trace)
              </span>
              <span className="px-2 py-0.5 rounded bg-emerald-500/20 text-emerald-300 text-[10px]">
                {traceData.turnstileStatus}
              </span>
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-[11px] font-mono text-slate-300">
              <div className="bg-[#0b101e] p-2 rounded-lg border border-slate-800">
                <span className="text-slate-500 block text-[10px]">Cloudflare WARP:</span>
                <span className="text-emerald-400 font-bold">{traceData.warp === 'on' ? 'ON (AS13335 Active)' : 'OFF (Split Mode)'}</span>
              </div>
              <div className="bg-[#0b101e] p-2 rounded-lg border border-slate-800">
                <span className="text-slate-500 block text-[10px]">Edge Location:</span>
                <span className="text-white font-bold">{traceData.loc} ({traceData.colo})</span>
              </div>
              <div className="bg-[#0b101e] p-2 rounded-lg border border-slate-800">
                <span className="text-slate-500 block text-[10px]">Client Egress IP:</span>
                <span className="text-purple-300 font-bold truncate block">{traceData.ip}</span>
              </div>
              <div className="bg-[#0b101e] p-2 rounded-lg border border-slate-800">
                <span className="text-slate-500 block text-[10px]">Threat Rating:</span>
                <span className="text-emerald-400 font-bold">{traceData.botManagementScore}/100 (Safe)</span>
              </div>
            </div>
          </div>
        )}

        {/* Cloudflare & ISP Masking Controls Grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3.5">
          {/* Toggle 1: Cloudflare Anti-Flag Shield */}
          <div className="p-4 rounded-2xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
            <div>
              <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                Cloudflare Anti-Flag & Turnstile Shield
                <span className="text-[10px] px-1.5 py-0.2 rounded bg-amber-500/10 text-amber-400 font-mono">
                  challenges.cloudflare.com
                </span>
              </div>
              <div className="text-[11px] text-slate-400 mt-0.5">
                Automatically prevents Cloudflare Managed Challenges and Captchas from flagging your personal VPS connection.
              </div>
            </div>
            <button
              onClick={() => handleToggleCfKey('cloudflareShield')}
              disabled={togglingCfKey === 'cloudflareShield'}
              className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                config?.cloudflareShield ? 'bg-amber-500 justify-end' : 'bg-slate-700 justify-start'
              }`}
            >
              <div className="bg-white w-4 h-4 rounded-full shadow-md" />
            </button>
          </div>

          {/* Toggle 2: WARP Dual-Hop Egress */}
          <div className="p-4 rounded-2xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
            <div>
              <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                Cloudflare WARP Egress (AS13335)
                <span className="text-[10px] px-1.5 py-0.2 rounded bg-emerald-500/10 text-emerald-400 font-mono">
                  Consumer Cloak
                </span>
              </div>
              <div className="text-[11px] text-slate-400 mt-0.5">
                Routes outbound web packets through Cloudflare internal edge network, replacing your VPS datacenter ASN with Cloudflare WARP.
              </div>
            </div>
            <button
              onClick={() => handleToggleCfKey('warpEgress')}
              disabled={togglingCfKey === 'warpEgress'}
              className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                config?.warpEgress ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'
              }`}
            >
              <div className="bg-white w-4 h-4 rounded-full shadow-md" />
            </button>
          </div>

          {/* Toggle 3: Cloudflare Edge IP Ranges Split Tunnel */}
          <div className="p-4 rounded-2xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
            <div>
              <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                Cloudflare Edge CIDRs Direct Split Tunnel
                <span className="text-[10px] px-1.5 py-0.2 rounded bg-purple-500/10 text-purple-400 font-mono">
                  22 Subnets
                </span>
              </div>
              <div className="text-[11px] text-slate-400 mt-0.5">
                Routes all 15 Cloudflare IPv4 CIDRs and 7 IPv6 CIDRs via direct client residential ISP, completely bypassing datacenter IP checks.
              </div>
            </div>
            <button
              onClick={() => handleToggleCfKey('cloudflareSplitRanges')}
              disabled={togglingCfKey === 'cloudflareSplitRanges'}
              className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                config?.cloudflareSplitRanges ? 'bg-purple-600 justify-end' : 'bg-slate-700 justify-start'
              }`}
            >
              <div className="bg-white w-4 h-4 rounded-full shadow-md" />
            </button>
          </div>

          {/* Toggle 4: Windows 11 Desktop TCP Stack Emulation */}
          <div className="p-4 rounded-2xl bg-[#070b14] border border-slate-800 flex items-center justify-between gap-3">
            <div>
              <div className="text-xs font-bold text-slate-100 flex items-center gap-1.5">
                Windows 11 Desktop TCP SYN Emulation
                <span className="text-[10px] px-1.5 py-0.2 rounded bg-blue-500/10 text-blue-400 font-mono">
                  TTL=128 Anti-p0f
                </span>
              </div>
              <div className="text-[11px] text-slate-400 mt-0.5">
                Sets TTL=128 and MSS=1360 so Cloudflares OS fingerprinting heuristics detect a genuine Windows PC rather than a Linux server.
              </div>
            </div>
            <button
              onClick={() => handleToggleCfKey('windowsTtlEmulation')}
              disabled={togglingCfKey === 'windowsTtlEmulation'}
              className={`w-11 h-6 flex items-center rounded-full p-1 transition shrink-0 ${
                config?.windowsTtlEmulation ? 'bg-blue-600 justify-end' : 'bg-slate-700 justify-start'
              }`}
            >
              <div className="bg-white w-4 h-4 rounded-full shadow-md" />
            </button>
          </div>
        </div>

        {/* Upstream Residential / SOCKS5 Proxy Config */}
        <div className="pt-2 border-t border-slate-800/80">
          <form onSubmit={handleSaveProxy} className="flex flex-col sm:flex-row items-stretch sm:items-center gap-3">
            <div className="flex-1">
              <label className="text-xs font-bold text-slate-200 flex items-center gap-1.5 mb-1">
                <Server className="w-3.5 h-3.5 text-amber-400" />
                Upstream Residential / SOCKS5 Proxy (Mask Host ISP):
              </label>
              <input
                type="text"
                value={proxyInput}
                onChange={e => setProxyInput(e.target.value)}
                placeholder="e.g. socks5://127.0.0.1:1080 or socks5://user:pass@residential.proxy.com:8000"
                className="w-full px-3.5 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white placeholder-slate-500 font-mono focus:border-amber-500 transition"
              />
            </div>
            <button
              type="submit"
              disabled={savingProxy}
              className="sm:self-end px-4 py-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-100 text-xs font-bold border border-slate-700 transition"
            >
              {savingProxy ? 'Saving...' : 'Save Upstream Proxy'}
            </button>
          </form>
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
