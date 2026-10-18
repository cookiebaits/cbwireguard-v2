import React, { useState, useEffect } from 'react';
import { Settings as SettingsIcon, Save, Check, RefreshCw, Shield, Network } from 'lucide-react';
import { ServerState } from '../types';

interface SettingsTabProps {
  server: ServerState | null;
  onRefresh: () => void;
}

export const SettingsTab: React.FC<SettingsTabProps> = ({ server, onRefresh }) => {
  const [mtu, setMtu] = useState<number>(1420);
  const [dns, setDns] = useState<string>('');
  const [allowedIps, setAllowedIps] = useState<string>('');
  const [listenPort, setListenPort] = useState<number>(51820);
  const [publicIp, setPublicIp] = useState<string>('');
  const [dokployBridge, setDokployBridge] = useState<boolean>(false);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (server) {
      setMtu(server.defaultMtu);
      setDns(server.defaultDns);
      setAllowedIps(server.defaultAllowedIps);
      setListenPort(server.listenPort);
      setPublicIp(server.publicIp);
      setDokployBridge(server.dokployBridge);
    }
  }, [server]);

  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const sensitivePorts = [20, 21, 22, 23, 25, 53, 67, 68, 80, 110, 143, 443, 8080, 8443, 3306, 5432, 6379, 27017];
  const isSensitivePort = sensitivePorts.includes(listenPort);

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg(null);

    if (isSensitivePort) {
      setErrorMsg(`Port ${listenPort} is a sensitive service port (conflicts with web/system services like 80/443). Please choose a safe stealth port.`);
      return;
    }

    setSaving(true);
    setSaved(false);

    try {
      const res = await fetch('/api/settings', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          defaultMtu: mtu,
          defaultDns: dns,
          defaultAllowedIps: allowedIps,
          listenPort,
          publicIp,
          dokployBridge,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        throw new Error(data.error || 'Failed to update settings');
      }
      setSaved(true);
      setTimeout(() => setSaved(false), 2500);
      onRefresh();
    } catch (e: any) {
      setErrorMsg(e.message || 'Error saving settings');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-6 max-w-4xl">
      <div className="bg-[#0f172a] border border-slate-800 rounded-3xl p-6 sm:p-8 shadow-xl">
        <div className="flex items-start gap-4">
          <div className="p-3.5 rounded-2xl bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">
            <SettingsIcon className="w-8 h-8" />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Global Server & Client Defaults</h2>
            <p className="text-xs sm:text-sm text-slate-300 mt-1 leading-relaxed">
              These settings dictate the parameters injected into <code className="text-emerald-400 font-mono">/root/easy_wireguard/settings.conf</code> and auto-assigned to all newly generated client configurations.
            </p>
          </div>
        </div>
      </div>

      <form onSubmit={handleSave} className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-6">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          {/* MTU */}
          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-2">
              Default Client MTU
            </label>
            <input
              type="number"
              value={mtu}
              onChange={e => setMtu(parseInt(e.target.value, 10))}
              min={1280}
              max={1500}
              className="w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs font-mono text-white focus:border-emerald-500"
              required
            />
            <p className="text-[11px] text-slate-400 mt-1.5">
              1420 is the default sweet-spot to prevent packet fragmentation across PPPoE and carrier tunnels while evading MTU-fingerprinting.
            </p>
          </div>

          {/* Listen Port */}
          <div>
            <div className="flex items-center justify-between mb-2">
              <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider">
                WireGuard Listen Port (UDP)
              </label>
              <span className="text-[10px] px-2 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 font-mono">
                Safe Stealth Ports
              </span>
            </div>
            <input
              type="number"
              value={listenPort}
              onChange={e => setListenPort(parseInt(e.target.value, 10))}
              min={1024}
              max={65535}
              className={`w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border text-xs font-mono text-white ${
                isSensitivePort ? 'border-red-500 focus:border-red-500' : 'border-slate-800 focus:border-emerald-500'
              }`}
              required
            />
            {isSensitivePort ? (
              <p className="text-[11px] text-red-400 mt-1.5 flex items-center gap-1 font-medium">
                ⚠️ Port {listenPort} is a sensitive service port (conflicts with web/system services like 80/443). Please choose a stealth port below.
              </p>
            ) : (
              <p className="text-[11px] text-slate-400 mt-1.5">
                Recommended: <span className="text-emerald-400 font-mono">4500</span> (IPsec NAT-T), <span className="text-emerald-400 font-mono">3478</span> (STUN/WebRTC), or <span className="text-emerald-400 font-mono">51820</span>. Avoids sensitive ports 80/443.
              </p>
            )}

            <div className="flex items-center gap-1.5 mt-2 flex-wrap">
              <span className="text-[10px] text-slate-400">Stealth Presets:</span>
              {[
                { port: 4500, label: '4500 (IPsec NAT-T)' },
                { port: 3478, label: '3478 (WebRTC STUN)' },
                { port: 51820, label: '51820 (WG Default)' },
                { port: 41194, label: '41194 (Tunnel Cloak)' },
              ].map(preset => (
                <button
                  key={preset.port}
                  type="button"
                  onClick={() => setListenPort(preset.port)}
                  className={`text-[10px] px-2 py-0.5 rounded-lg border font-mono transition ${
                    listenPort === preset.port
                      ? 'bg-emerald-600/20 text-emerald-300 border-emerald-500/40'
                      : 'bg-slate-900 text-slate-400 border-slate-800 hover:text-slate-200'
                  }`}
                >
                  {preset.label}
                </button>
              ))}
            </div>
          </div>

          {/* DNS Resolvers */}
          <div className="md:col-span-2">
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-2">
              Default DNS Servers (Comma Separated)
            </label>
            <input
              type="text"
              value={dns}
              onChange={e => setDns(e.target.value)}
              className="w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs font-mono text-white focus:border-emerald-500"
              required
            />
            <p className="text-[11px] text-slate-400 mt-1.5">
              Default: <span className="text-emerald-400 font-mono">94.140.14.49, 9.9.9.9, 94.140.14.59</span> (AdGuard Privacy + Quad9 Uncensored).
            </p>
          </div>

          {/* Allowed IPs Default */}
          <div className="md:col-span-2">
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-2">
              Default Allowed IPs Scope
            </label>
            <input
              type="text"
              value={allowedIps}
              onChange={e => setAllowedIps(e.target.value)}
              className="w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs font-mono text-white focus:border-emerald-500"
              required
            />
            <p className="text-[11px] text-slate-400 mt-1.5">
              Default: <span className="text-purple-400 font-mono">0.0.0.0/1, 128.0.0.0/1</span>. Overrides default gateway routes without clobbering existing local network interface defaults.
            </p>
          </div>

          {/* Server Public IP Override */}
          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-2">
              Server External Public IP / Domain
            </label>
            <input
              type="text"
              value={publicIp}
              onChange={e => setPublicIp(e.target.value)}
              className="w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-xs font-mono text-white focus:border-emerald-500"
              required
            />
            <p className="text-[11px] text-slate-400 mt-1.5">
              Endpoint address encoded in all client QR codes and .conf files.
            </p>
          </div>

          {/* Dokploy Traefik Bridge */}
          <div className="flex items-center justify-between p-4 rounded-xl bg-[#070b14] border border-slate-800">
            <div>
              <div className="text-xs font-bold text-slate-200">Dokploy / Traefik Proxy Bridge</div>
              <div className="text-[11px] text-slate-400">Routes UDP traffic via proxy bridge if standard ports are in use.</div>
            </div>
            <button
              type="button"
              onClick={() => setDokployBridge(!dokployBridge)}
              className={`w-11 h-6 flex items-center rounded-full p-1 transition ${dokployBridge ? 'bg-purple-600 justify-end' : 'bg-slate-700 justify-start'}`}
            >
              <div className="bg-white w-4 h-4 rounded-full shadow-md" />
            </button>
          </div>
        </div>

        {errorMsg && (
          <div className="p-3.5 rounded-xl bg-red-950/40 border border-red-500/30 text-xs text-red-300 flex items-center gap-2">
            <span>⚠️</span>
            <span>{errorMsg}</span>
          </div>
        )}

        <div className="flex items-center justify-between pt-4 border-t border-slate-800">
          <span className="text-xs text-slate-400 font-mono">
            {saved ? <span className="text-emerald-400 flex items-center gap-1"><Check className="w-4 h-4" /> Changes saved to settings.conf</span> : 'Ready to save'}
          </span>
          <button
            type="submit"
            disabled={saving}
            className="flex items-center gap-2 px-6 py-2.5 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-bold shadow-lg shadow-emerald-950 transition disabled:opacity-50"
          >
            <Save className="w-4 h-4" />
            {saving ? 'Saving...' : 'Save Settings'}
          </button>
        </div>
      </form>
    </div>
  );
};
