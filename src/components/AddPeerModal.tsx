import React, { useState } from 'react';
import { X, Plus, ShieldCheck, Zap, HardDrive, Cloud } from 'lucide-react';

interface AddPeerModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdded: () => void;
  defaultMtu: number;
  defaultDns: string;
  defaultAllowedIps: string;
}

const CF_BYPASS_CIDRS = "224.0.0.0/3, 208.0.0.0/4, 200.0.0.0/5, 192.0.0.0/6, 196.0.0.0/7, 199.0.0.0/8, 198.128.0.0/9, 198.64.0.0/10, 198.0.0.0/11, 198.48.0.0/12, 198.32.0.0/13, 198.44.0.0/14, 198.42.0.0/15, 198.40.0.0/16, 198.41.0.0/17, 128.0.0.0/3, 176.0.0.0/4, 164.0.0.0/6, 160.0.0.0/7, 163.0.0.0/8, 162.0.0.0/9, 162.192.0.0/10, 162.160.0.0/11, 162.128.0.0/12, 162.144.0.0/13, 162.152.0.0/14, 162.156.0.0/15, 168.0.0.0/6, 174.0.0.0/7, 173.0.0.0/8, 172.128.0.0/9, 172.0.0.0/10, 172.96.0.0/11, 172.80.0.0/12, 172.72.0.0/13, 0.0.0.0/2, 64.0.0.0/3, 112.0.0.0/4, 96.0.0.0/5, 108.0.0.0/6, 106.0.0.0/7, 105.0.0.0/8, 104.128.0.0/9, 104.64.0.0/10, 104.32.0.0/11, 104.0.0.0/12";

export const AddPeerModal: React.FC<AddPeerModalProps> = ({
  isOpen,
  onClose,
  onAdded,
  defaultMtu,
  defaultDns,
  defaultAllowedIps,
}) => {
  const [name, setName] = useState('');
  const [allowedIpsPreset, setAllowedIpsPreset] = useState<'full' | 'cloudflare' | 'stealth' | 'custom'>('full');
  const [customAllowedIps, setCustomAllowedIps] = useState('0.0.0.0/1, 128.0.0.0/1');
  const [dnsPreset, setDnsPreset] = useState<'cloudflare' | 'adguard' | 'quad9' | 'custom'>('cloudflare');
  const [customDns, setCustomDns] = useState(defaultDns);
  const [mtu, setMtu] = useState(defaultMtu);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      setError('Please provide a client name (alphanumeric and dashes only).');
      return;
    }

    setSubmitting(true);
    setError(null);

    let finalAllowedIps = defaultAllowedIps;
    if (allowedIpsPreset === 'full') finalAllowedIps = '0.0.0.0/0, ::/0';
    else if (allowedIpsPreset === 'cloudflare') finalAllowedIps = CF_BYPASS_CIDRS;
    else if (allowedIpsPreset === 'stealth') finalAllowedIps = '0.0.0.0/1, 128.0.0.0/1';
    else finalAllowedIps = customAllowedIps;

    let finalDns = defaultDns;
    if (dnsPreset === 'adguard') finalDns = '94.140.14.49, 9.9.9.9, 94.140.14.59';
    else if (dnsPreset === 'quad9') finalDns = '9.9.9.9, 149.112.112.112';
    else if (dnsPreset === 'cloudflare') finalDns = '1.1.1.1, 1.0.0.1';
    else finalDns = customDns;

    try {
      const res = await fetch('/api/clients', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: name.trim(),
          allowedIps: finalAllowedIps,
          dns: finalDns,
          mtu,
        }),
      });

      if (!res.ok) {
        const err = await res.json();
        throw new Error(err.error || 'Failed to add client');
      }

      onAdded();
      onClose();
      setName('');
    } catch (err: any) {
      setError(err.message || 'An unexpected error occurred.');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-200">
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl max-w-lg w-full p-6 shadow-2xl relative">
        <div className="flex items-center justify-between border-b border-slate-800/80 pb-4 mb-5">
          <div className="flex items-center gap-3">
            <div className="p-2 rounded-xl bg-purple-500/10 text-purple-400 border border-purple-500/20">
              <Plus className="w-5 h-5" />
            </div>
            <div>
              <h2 className="text-lg font-bold text-slate-100">Add New WireGuard Peer</h2>
              <p className="text-xs text-slate-400">Instantly injected into running server with zero packet drop</p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 text-slate-400 hover:text-white rounded-lg hover:bg-slate-800 transition"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {error && (
          <div className="p-3 mb-4 rounded-lg bg-red-950/60 border border-red-800/60 text-red-300 text-xs">
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
              Device / Client Name
            </label>
            <input
              type="text"
              value={name}
              onChange={e => setName(e.target.value)}
              placeholder="e.g. MacBook-Pro, Work-Phone, Travel-iPad"
              className="w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-slate-100 placeholder-slate-500 text-sm focus:outline-none focus:border-emerald-500 transition"
              autoFocus
              required
            />
            <p className="text-[11px] text-slate-500 mt-1">Alphanumeric, hyphens and underscores only.</p>
          </div>

          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
              Allowed IPs (Tunnel Scope)
            </label>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-2 mb-2">
              <button
                type="button"
                onClick={() => setAllowedIpsPreset('full')}
                className={`p-2.5 text-xs font-medium rounded-xl border text-left transition ${
                  allowedIpsPreset === 'full'
                    ? 'bg-emerald-950/50 border-emerald-500 text-emerald-300 shadow-sm'
                    : 'bg-[#070b14] border-slate-800 text-slate-400 hover:text-slate-200'
                }`}
              >
                <div className="font-bold flex items-center gap-1.5">
                  <HardDrive className="w-3.5 h-3.5 text-emerald-400" />
                  Full Tunnel
                </div>
                <div className="text-[10px] text-emerald-400/80 mt-0.5">Standard (0.0.0.0/0, ::/0)</div>
              </button>
              <button
                type="button"
                onClick={() => setAllowedIpsPreset('cloudflare')}
                className={`p-2.5 text-xs font-medium rounded-xl border text-left transition ${
                  allowedIpsPreset === 'cloudflare'
                    ? 'bg-amber-950/50 border-amber-500 text-amber-300 shadow-sm'
                    : 'bg-[#070b14] border-slate-800 text-slate-400 hover:text-slate-200'
                }`}
              >
                <div className="font-bold flex items-center gap-1.5">
                  <Cloud className="w-3.5 h-3.5 text-amber-400" />
                  Anti-Flag Direct
                </div>
                <div className="text-[10px] text-amber-400/80 mt-0.5">Cloudflare Turnstile Split</div>
              </button>
              <button
                type="button"
                onClick={() => setAllowedIpsPreset('stealth')}
                className={`p-2.5 text-xs font-medium rounded-xl border text-left transition ${
                  allowedIpsPreset === 'stealth'
                    ? 'bg-purple-950/50 border-purple-500 text-purple-300'
                    : 'bg-[#070b14] border-slate-800 text-slate-400 hover:text-slate-200'
                }`}
              >
                <div className="font-bold flex items-center gap-1.5">
                  <ShieldCheck className="w-3.5 h-3.5 text-purple-400" />
                  Dual /1 Split
                </div>
                <div className="text-[10px] text-slate-400 font-mono mt-0.5">0.0.0.0/1, 128/1</div>
              </button>
            </div>
            {allowedIpsPreset === 'custom' && (
              <input
                type="text"
                value={customAllowedIps}
                onChange={e => setCustomAllowedIps(e.target.value)}
                className="w-full px-3 py-2 rounded-lg bg-[#070b14] border border-slate-800 text-slate-100 text-xs font-mono"
              />
            )}
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
                DNS Cluster
              </label>
              <select
                value={dnsPreset}
                onChange={e => setDnsPreset(e.target.value as any)}
                className="w-full px-3 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-slate-200 text-xs focus:outline-none focus:border-emerald-500"
              >
                <option value="adguard">AdGuard Ad-Block & Privacy</option>
                <option value="quad9">Quad9 Secure (9.9.9.9)</option>
                <option value="cloudflare">Cloudflare 1.1.1.1</option>
                <option value="custom">Custom DNS...</option>
              </select>
            </div>

            <div>
              <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
                Client MTU
              </label>
              <input
                type="number"
                value={mtu}
                onChange={e => setMtu(parseInt(e.target.value, 10))}
                className="w-full px-3 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-slate-200 text-xs font-mono focus:outline-none focus:border-emerald-500"
                min={1200}
                max={1500}
              />
              <span className="text-[10px] text-emerald-400 font-medium">1420 = Optimized for anti-detection</span>
            </div>
          </div>

          <div className="flex justify-end gap-2.5 pt-4 border-t border-slate-800">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2.5 rounded-xl text-xs font-medium text-slate-400 hover:text-white hover:bg-slate-800 transition"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="flex items-center gap-2 px-5 py-2.5 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold shadow-lg shadow-purple-950 transition disabled:opacity-50"
            >
              <Zap className="w-4 h-4" />
              {submitting ? 'Generating Keys...' : 'Generate & Deploy Peer'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
