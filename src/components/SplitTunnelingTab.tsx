import React, { useState, useEffect } from 'react';
import { Split, Plus, Trash2, CheckCircle2, Tv, Bot, Landmark, Globe, Shield, Cloud, ShoppingBag } from 'lucide-react';
import { SplitService } from '../types';

export const SplitTunnelingTab: React.FC = () => {
  const [services, setServices] = useState<SplitService[]>([]);
  const [customDomains, setCustomDomains] = useState<string[]>([]);
  const [newDomain, setNewDomain] = useState('');
  const [loading, setLoading] = useState(true);

  const fetchData = async () => {
    try {
      const res = await fetch('/api/split-tunneling');
      const data = await res.json();
      setServices(data.services);
      setCustomDomains(data.customDomains);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchData();
  }, []);

  const handleToggleService = async (id: string, currentEnabled: boolean) => {
    try {
      await fetch('/api/split-tunneling/toggle-service', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, enabled: !currentEnabled }),
      });
      fetchData();
    } catch (e) {
      console.error(e);
    }
  };

  const handleAddCustom = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newDomain.trim()) return;
    try {
      await fetch('/api/split-tunneling/custom-domain', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain: newDomain.trim() }),
      });
      setNewDomain('');
      fetchData();
    } catch (e) {
      console.error(e);
    }
  };

  const handleDeleteCustom = async (domain: string) => {
    try {
      await fetch('/api/split-tunneling/custom-domain', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain }),
      });
      fetchData();
    } catch (e) {
      console.error(e);
    }
  };

  const getCategoryIcon = (cat: string, id?: string) => {
    if (id === 'cloudflare') return <Cloud className="w-4 h-4 text-amber-400" />;
    switch (cat) {
      case 'shopping': return <ShoppingBag className="w-4 h-4 text-orange-400" />;
      case 'streaming': return <Tv className="w-4 h-4 text-emerald-400" />;
      case 'ai': return <Bot className="w-4 h-4 text-purple-400" />;
      case 'banking': return <Landmark className="w-4 h-4 text-amber-400" />;
      default: return <Globe className="w-4 h-4 text-blue-400" />;
    }
  };

  return (
    <div className="space-y-6">
      {/* Banner */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-3xl p-6 sm:p-8 shadow-xl">
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-6">
          <div className="flex items-start gap-4">
            <div className="p-3.5 rounded-2xl bg-purple-500/10 text-purple-400 border border-purple-500/20">
              <Split className="w-8 h-8" />
            </div>
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="text-xl font-bold text-white">Domain-Based Split Tunneling</h2>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 font-semibold">
                  Stealth Routing Active
                </span>
              </div>
              <p className="text-xs sm:text-sm text-slate-300 mt-1 max-w-2xl leading-relaxed">
                Exclude popular streaming services and sensitive banking sites from the VPN tunnel. Traffic to these domains routes through the client's direct ISP, completely avoiding "VPN Detected" or "Forbidden Country" lockouts while securing all other web traffic.
              </p>
            </div>
          </div>
        </div>
      </div>

      {/* Services Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {services.map(svc => (
          <div
            key={svc.id}
            className={`p-5 rounded-2xl border transition relative overflow-hidden ${
              svc.id === 'cloudflare'
                ? svc.enabled
                  ? 'bg-gradient-to-br from-[#0c1427] to-[#131c36] border-amber-500/50 shadow-lg shadow-amber-950/20'
                  : 'bg-[#0b101e] border-slate-800/80 opacity-70'
                : svc.enabled
                ? 'bg-[#0f172a] border-purple-500/40 shadow-lg shadow-purple-950/20'
                : 'bg-[#0b101e] border-slate-800/80 opacity-70'
            }`}
          >
            {svc.id === 'cloudflare' && (
              <span className="absolute top-2 right-14 text-[9px] font-bold px-2 py-0.5 rounded-full bg-amber-500/20 text-amber-300 border border-amber-500/40 uppercase tracking-wider">
                Anti-Flag Shield
              </span>
            )}
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-2.5">
                <div className={`p-2 rounded-xl ${svc.id === 'cloudflare' ? 'bg-amber-500/10' : 'bg-slate-800'}`}>
                  {getCategoryIcon(svc.category, svc.id)}
                </div>
                <div>
                  <h3 className="text-sm font-bold text-white">{svc.name}</h3>
                  <span className="text-[11px] text-slate-400 font-mono">{svc.domain}</span>
                </div>
              </div>

              <button
                onClick={() => handleToggleService(svc.id, svc.enabled)}
                className={`w-11 h-6 flex items-center rounded-full p-1 transition ${
                  svc.enabled
                    ? svc.id === 'cloudflare'
                      ? 'bg-amber-500 justify-end'
                      : 'bg-purple-600 justify-end'
                    : 'bg-slate-700 justify-start'
                }`}
              >
                <div className="bg-white w-4 h-4 rounded-full shadow-md" />
              </button>
            </div>

            <div className="text-[11px] text-slate-400">
              <span className="text-slate-500">Includes subdomains:</span>
              <div className="flex flex-wrap gap-1 mt-1.5 font-mono">
                {svc.subdomains.slice(0, 3).map(sub => (
                  <span key={sub} className="px-1.5 py-0.5 rounded bg-[#070b14] border border-slate-800 text-[10px] text-slate-300">
                    {sub}
                  </span>
                ))}
                {svc.subdomains.length > 3 && (
                  <span className="px-1.5 py-0.5 rounded bg-[#070b14] text-[10px] text-purple-400">
                    +{svc.subdomains.length - 3} more
                  </span>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* Custom Domains Section */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
        <h3 className="text-sm font-bold text-white flex items-center gap-2">
          <Globe className="w-4 h-4 text-emerald-400" />
          Custom Split Tunneling Domains
        </h3>
        <p className="text-xs text-slate-400">
          Add any internal corporate domain, local Plex server, or streaming service to exclude it dynamically.
        </p>

        <form onSubmit={handleAddCustom} className="flex gap-2 max-w-lg">
          <input
            type="text"
            value={newDomain}
            onChange={e => setNewDomain(e.target.value)}
            placeholder="e.g. streaming.example.com, work.intranet"
            className="flex-1 px-3.5 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white focus:border-purple-500 font-mono"
          />
          <button
            type="submit"
            className="px-4 py-2 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold flex items-center gap-1.5 transition"
          >
            <Plus className="w-4 h-4" />
            Add Domain
          </button>
        </form>

        <div className="flex flex-wrap gap-2 pt-2">
          {customDomains.map(d => (
            <div
              key={d}
              className="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-slate-200 font-mono"
            >
              <span>{d}</span>
              <button
                onClick={() => handleDeleteCustom(d)}
                className="text-slate-500 hover:text-red-400 transition"
              >
                <Trash2 className="w-3.5 h-3.5" />
              </button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
