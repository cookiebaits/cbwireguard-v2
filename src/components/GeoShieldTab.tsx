import React, { useState } from 'react';
import { Shield, ShieldAlert, ShieldCheck, RefreshCw, Plus, Trash2, Globe, Server, AlertTriangle } from 'lucide-react';
import { GeoShieldState, ShieldBlockLog } from '../types';

interface GeoShieldTabProps {
  geoShield: GeoShieldState | null;
  onRefresh: () => void;
}

export const GeoShieldTab: React.FC<GeoShieldTabProps> = ({ geoShield, onRefresh }) => {
  const [newAllowCidr, setNewAllowCidr] = useState('');
  const [newBlockCidr, setNewBlockCidr] = useState('');
  const [updatingDb, setUpdatingDb] = useState(false);
  const [toggling, setToggling] = useState(false);

  const handleToggle = async (updates: Partial<GeoShieldState>) => {
    setToggling(true);
    try {
      await fetch('/api/geo-shield/toggle', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(updates),
      });
      onRefresh();
    } catch (e) {
      console.error(e);
    } finally {
      setToggling(false);
    }
  };

  const handleAddRule = async (type: 'allow' | 'block') => {
    const cidr = type === 'allow' ? newAllowCidr.trim() : newBlockCidr.trim();
    if (!cidr) return;

    try {
      await fetch('/api/geo-shield/rule', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type, cidr }),
      });
      if (type === 'allow') setNewAllowCidr('');
      else setNewBlockCidr('');
      onRefresh();
    } catch (e) {
      console.error(e);
    }
  };

  const handleDeleteRule = async (type: 'allow' | 'block', cidr: string) => {
    try {
      await fetch('/api/geo-shield/rule', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type, cidr }),
      });
      onRefresh();
    } catch (e) {
      console.error(e);
    }
  };

  const handleUpdateDatabase = async () => {
    setUpdatingDb(true);
    try {
      await fetch('/api/geo-shield/update-database', { method: 'POST' });
      onRefresh();
    } catch (e) {
      console.error(e);
    } finally {
      setUpdatingDb(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Top Banner Shield Status */}
      <div className="bg-gradient-to-r from-[#0f172a] via-[#161f36] to-[#0f172a] border border-slate-800 rounded-3xl p-6 sm:p-8 shadow-2xl relative overflow-hidden">
        <div className="relative z-10 flex flex-col md:flex-row md:items-center justify-between gap-6">
          <div className="flex items-start gap-4">
            <div className={`p-4 rounded-2xl border ${
              geoShield?.enabled
                ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/30 shadow-lg shadow-emerald-950'
                : 'bg-red-500/10 text-red-400 border-red-500/30'
            }`}>
              <Shield className="w-8 h-8" />
            </div>

            <div className="space-y-1.5">
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="text-xl font-black text-white tracking-tight">Geo-IP & Anti-VPN Shield</h2>
                <span className={`text-xs font-bold px-2.5 py-0.5 rounded-full border ${
                  geoShield?.enabled
                    ? 'bg-emerald-500/20 text-emerald-300 border-emerald-500/40'
                    : 'bg-slate-800 text-slate-400 border-slate-700'
                }`}>
                  {geoShield?.enabled ? 'ENFORCED (KERNEL IPSET)' : 'DISABLED'}
                </span>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-purple-500/20 text-purple-300 border border-purple-500/30 font-semibold">
                  US & Canada Subnets Only
                </span>
              </div>
              <p className="text-xs sm:text-sm text-slate-300 max-w-2xl leading-relaxed">
                Guards WireGuard UDP port 51820 against stacked VPNs, overseas attackers, and commercial datacenter scanning. Packets from unauthorized locations are dropped before reaching userland.
              </p>
            </div>
          </div>

          <div className="flex items-center gap-3 shrink-0 self-start md:self-center">
            <button
              onClick={() => handleToggle({ enabled: !geoShield?.enabled })}
              disabled={toggling}
              className={`px-5 py-2.5 rounded-xl text-xs font-bold transition shadow-lg ${
                geoShield?.enabled
                  ? 'bg-red-950/60 hover:bg-red-900/60 text-red-300 border border-red-800/60'
                  : 'bg-emerald-600 hover:bg-emerald-500 text-white shadow-emerald-950'
              }`}
            >
              {geoShield?.enabled ? 'Disable Shield' : 'Activate Shield'}
            </button>
            <button
              onClick={handleUpdateDatabase}
              disabled={updatingDb}
              className="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-semibold border border-slate-700 transition"
              title="Pull latest MaxMind and RIR zone files"
            >
              <RefreshCw className={`w-3.5 h-3.5 ${updatingDb ? 'animate-spin text-emerald-400' : ''}`} />
              <span>{updatingDb ? 'Updating Subnets...' : 'Refresh DB'}</span>
            </button>
          </div>
        </div>

        {/* Stats Row */}
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-8 pt-6 border-t border-slate-800/80">
          <div>
            <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider">US/CA Subnets Allowed</span>
            <div className="text-xl font-black text-emerald-400 font-mono mt-0.5">
              {geoShield?.allowedSubnetsCount.toLocaleString()}
            </div>
          </div>
          <div>
            <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider">Datacenter / VPN Blocked</span>
            <div className="text-xl font-black text-red-400 font-mono mt-0.5">
              {geoShield?.blockedSubnetsCount.toLocaleString()}
            </div>
          </div>
          <div>
            <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider">Total Blocked Attacks</span>
            <div className="text-xl font-black text-purple-400 font-mono mt-0.5">
              {geoShield?.totalBlockedAttempts.toLocaleString()}
            </div>
          </div>
          <div>
            <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider">Threat DB Last Sync</span>
            <div className="text-xs font-semibold text-slate-300 mt-1.5 font-mono">
              {new Date(geoShield?.lastDatabaseUpdate || '').toLocaleDateString()}
            </div>
          </div>
        </div>
      </div>

      {/* Rules & Filter Configuration */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Toggle Controls */}
        <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
          <h3 className="text-sm font-bold text-white flex items-center gap-2">
            <Globe className="w-4 h-4 text-emerald-400" />
            Shield Filtering Policies
          </h3>

          <div className="space-y-3">
            <div className="flex items-center justify-between p-3.5 rounded-xl bg-[#070b14] border border-slate-800">
              <div>
                <div className="text-xs font-bold text-slate-200">Enforce USA & Canada Only Mode</div>
                <div className="text-[11px] text-slate-400">Strictly drop incoming handshake packets originating outside North America.</div>
              </div>
              <button
                onClick={() => handleToggle({ mode: geoShield?.mode === 'US_CA_ONLY' ? 'ALL_PERMITTED' : 'US_CA_ONLY' })}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition ${geoShield?.mode === 'US_CA_ONLY' ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'}`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            <div className="flex items-center justify-between p-3.5 rounded-xl bg-[#070b14] border border-slate-800">
              <div>
                <div className="text-xs font-bold text-slate-200">Block Commercial VPNs & Tor Exits</div>
                <div className="text-[11px] text-slate-400">Blocks NordVPN, ExpressVPN, Surfshark, Mullvad, and Tor exit relays.</div>
              </div>
              <button
                onClick={() => handleToggle({ blockCommercialVpns: !geoShield?.blockCommercialVpns })}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition ${geoShield?.blockCommercialVpns ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'}`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            <div className="flex items-center justify-between p-3.5 rounded-xl bg-[#070b14] border border-slate-800">
              <div>
                <div className="text-xs font-bold text-slate-200">Block Datacenter Subnets (AWS, GCP, Hetzner, DO)</div>
                <div className="text-[11px] text-slate-400">Drops incoming scans from server farms and cloud hosts.</div>
              </div>
              <button
                onClick={() => handleToggle({ blockDatacenters: !geoShield?.blockDatacenters })}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition ${geoShield?.blockDatacenters ? 'bg-emerald-600 justify-end' : 'bg-slate-700 justify-start'}`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>
          </div>
        </div>

        {/* Custom Whitelist & Blacklist */}
        <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
          <h3 className="text-sm font-bold text-white flex items-center gap-2">
            <Server className="w-4 h-4 text-purple-400" />
            Custom Whitelist & Blacklist CIDRs
          </h3>

          <div className="space-y-4">
            {/* Whitelist Input */}
            <div>
              <div className="flex items-center justify-between mb-1.5">
                <span className="text-xs font-semibold text-emerald-400 uppercase tracking-wider">Custom Whitelist (Always Allowed)</span>
              </div>
              <div className="flex gap-2">
                <input
                  type="text"
                  value={newAllowCidr}
                  onChange={e => setNewAllowCidr(e.target.value)}
                  placeholder="e.g. 198.51.100.0/24 or single IP"
                  className="flex-1 px-3 py-1.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white font-mono focus:border-emerald-500"
                />
                <button
                  onClick={() => handleAddRule('allow')}
                  className="px-3 py-1.5 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold flex items-center gap-1"
                >
                  <Plus className="w-3.5 h-3.5" />
                  Add
                </button>
              </div>
              <div className="flex flex-wrap gap-1.5 mt-2">
                {geoShield?.customAllowList.map(cidr => (
                  <span
                    key={cidr}
                    className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-emerald-950/40 border border-emerald-800/40 text-emerald-300 text-xs font-mono"
                  >
                    {cidr}
                    <button onClick={() => handleDeleteRule('allow', cidr)} className="hover:text-red-400">
                      <Trash2 className="w-3 h-3" />
                    </button>
                  </span>
                ))}
              </div>
            </div>

            {/* Blacklist Input */}
            <div className="pt-2 border-t border-slate-800">
              <div className="flex items-center justify-between mb-1.5">
                <span className="text-xs font-semibold text-red-400 uppercase tracking-wider">Custom Blacklist (Always Dropped)</span>
              </div>
              <div className="flex gap-2">
                <input
                  type="text"
                  value={newBlockCidr}
                  onChange={e => setNewBlockCidr(e.target.value)}
                  placeholder="e.g. 45.154.255.0/24"
                  className="flex-1 px-3 py-1.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white font-mono focus:border-red-500"
                />
                <button
                  onClick={() => handleAddRule('block')}
                  className="px-3 py-1.5 rounded-xl bg-red-600 hover:bg-red-500 text-white text-xs font-semibold flex items-center gap-1"
                >
                  <Plus className="w-3.5 h-3.5" />
                  Add
                </button>
              </div>
              <div className="flex flex-wrap gap-1.5 mt-2">
                {geoShield?.customBlockList.map(cidr => (
                  <span
                    key={cidr}
                    className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-red-950/40 border border-red-800/40 text-red-300 text-xs font-mono"
                  >
                    {cidr}
                    <button onClick={() => handleDeleteRule('block', cidr)} className="hover:text-red-400">
                      <Trash2 className="w-3 h-3" />
                    </button>
                  </span>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Live Dropped Connections Log */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl">
        <h3 className="text-sm font-bold text-white flex items-center gap-2 mb-4">
          <AlertTriangle className="w-4 h-4 text-orange-400" />
          Recent Dropped Connection Events
        </h3>

        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead>
              <tr className="border-b border-slate-800 text-slate-400 uppercase font-semibold">
                <th className="pb-3 pl-2">Country</th>
                <th className="pb-3">Source IP</th>
                <th className="pb-3">Target Port</th>
                <th className="pb-3">Detection Reason</th>
                <th className="pb-3">Time</th>
                <th className="pb-3 pr-2 text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-800/60 font-mono">
              {geoShield?.recentBlocks.map(blk => (
                <tr key={blk.id} className="hover:bg-slate-800/30">
                  <td className="py-2.5 pl-2">
                    <span className="text-base mr-1.5">{blk.flag}</span>
                    <span className="text-slate-300 font-semibold">{blk.country}</span>
                  </td>
                  <td className="py-2.5 text-slate-200">{blk.ip}</td>
                  <td className="py-2.5 text-slate-400">{blk.port}/udp</td>
                  <td className="py-2.5 text-orange-300 font-sans">{blk.reason}</td>
                  <td className="py-2.5 text-slate-400">{blk.timestamp}</td>
                  <td className="py-2.5 pr-2 text-right">
                    <span className="px-2 py-0.5 rounded bg-red-950/80 text-red-400 border border-red-800/60 font-semibold text-[10px]">
                      DROPPED
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};
