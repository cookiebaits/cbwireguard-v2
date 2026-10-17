import React, { useState } from 'react';
import { ShieldAlert, Key, Check, Lock, Globe, Wifi, AlertTriangle, ArrowRight } from 'lucide-react';
import { AuthSecurityState } from '../types';

interface SecurityGatekeeperModalProps {
  authState: AuthSecurityState;
  onUnlocked: () => void;
  onClose?: () => void;
  isDrawer?: boolean;
}

export const SecurityGatekeeperModal: React.FC<SecurityGatekeeperModalProps> = ({
  authState,
  onUnlocked,
  onClose,
  isDrawer = false,
}) => {
  const [passkey, setPasskey] = useState('');
  const [whitelistMyIp, setWhitelistMyIp] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  const handleUnlock = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!passkey.trim()) return;

    setLoading(true);
    setError(null);

    try {
      const res = await fetch('/api/auth/unlock', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passkey: passkey.trim(), whitelistMyIp }),
      });

      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Invalid Master Security Passkey');

      // Store auth token in localStorage
      localStorage.setItem('cookie_wg_auth_token', data.token);
      setSuccess(true);
      setTimeout(() => {
        onUnlocked();
        if (onClose) onClose();
      }, 800);
    } catch (err: any) {
      setError(err.message || 'Authentication failed');
    } finally {
      setLoading(false);
    }
  };

  const containerClasses = isDrawer
    ? 'fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in'
    : 'fixed inset-0 z-50 flex items-center justify-center p-4 bg-[#090d16]/95 backdrop-blur-md animate-in fade-in';

  return (
    <div className={containerClasses}>
      <div className="bg-[#0f172a] border border-slate-800 rounded-3xl max-w-lg w-full p-6 sm:p-8 shadow-2xl relative overflow-hidden">
        {/* Top Header */}
        <div className="flex items-start gap-4 mb-6">
          <div className="p-3.5 rounded-2xl bg-amber-500/10 text-amber-400 border border-amber-500/20 shrink-0">
            <Lock className="w-8 h-8" />
          </div>
          <div>
            <div className="flex items-center gap-2 flex-wrap">
              <h2 className="text-lg sm:text-xl font-black text-white">WireGuard VPN Connection Required</h2>
              <span className="text-[10px] font-mono px-2 py-0.5 rounded bg-red-950/60 text-red-400 border border-red-800/60 font-semibold">
                RESTRICTED
              </span>
            </div>
            <p className="text-xs text-slate-300 mt-1 leading-relaxed">
              For maximum security, this management console is strictly isolated. You must either be connected to the WireGuard tunnel or authorize your IP address.
            </p>
          </div>
        </div>

        {/* Status Callout */}
        <div className="p-4 rounded-2xl bg-[#070b14] border border-slate-800 space-y-2 mb-6 text-xs">
          <div className="flex items-center justify-between">
            <span className="text-slate-400">Your Current IP:</span>
            <span className="font-mono text-slate-200 font-bold">{authState.clientIp || 'Detecting...'}</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-slate-400">Required WireGuard Subnet:</span>
            <span className="font-mono text-emerald-400 font-bold">10.18.0.0/24 (e.g. 10.18.0.2)</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-slate-400">Tunnel Status:</span>
            <span className="flex items-center gap-1.5 text-amber-400 font-semibold">
              <span className="w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span>
              {authState.isVpnConnected ? 'Connected via Tunnel' : 'External Non-Tunnel Route'}
            </span>
          </div>
        </div>

        {/* Access Instructions */}
        <div className="space-y-3 mb-6">
          <div className="p-3 rounded-xl bg-slate-900/60 border border-slate-800/80 text-xs text-slate-300 space-y-1">
            <div className="font-bold text-white flex items-center gap-1.5">
              <Wifi className="w-3.5 h-3.5 text-emerald-400" />
              Method 1 (Automatic): Connect via WireGuard
            </div>
            <p className="text-[11px] text-slate-400 pl-5">
              Turn on your WireGuard client on your laptop or phone. Once connected, browse directly to <code className="text-emerald-400 font-mono">http://10.18.0.1:{authState.webPort || 51821}</code>.
            </p>
          </div>

          <div className="p-3 rounded-xl bg-slate-900/60 border border-slate-800/80 text-xs text-slate-300 space-y-1">
            <div className="font-bold text-white flex items-center gap-1.5">
              <Key className="w-3.5 h-3.5 text-purple-400" />
              Method 2: Master Passkey Emergency Unlock
            </div>
            <p className="text-[11px] text-slate-400 pl-5">
              Enter the master security passkey output in your VPS terminal during installation (<code className="text-purple-300 font-mono">/etc/wireguard/admin.key</code>).
            </p>
          </div>
        </div>

        {error && (
          <div className="p-3 mb-4 rounded-xl bg-red-950/60 border border-red-800/60 text-red-300 text-xs flex items-center gap-2">
            <AlertTriangle className="w-4 h-4 shrink-0 text-red-400" />
            <span>{error}</span>
          </div>
        )}

        {success && (
          <div className="p-3 mb-4 rounded-xl bg-emerald-950/60 border border-emerald-800/60 text-emerald-300 text-xs flex items-center gap-2">
            <Check className="w-4 h-4 shrink-0 text-emerald-400" />
            <span>Authenticated successfully! Redirecting...</span>
          </div>
        )}

        <form onSubmit={handleUnlock} className="space-y-4">
          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
              Admin Master Security Passkey
            </label>
            <input
              type="password"
              value={passkey}
              onChange={e => setPasskey(e.target.value)}
              placeholder="Paste passkey from /etc/wireguard/admin.key..."
              className="w-full px-3.5 py-2.5 rounded-xl bg-[#070b14] border border-slate-800 text-slate-100 text-xs font-mono focus:border-purple-500"
              autoFocus
            />
          </div>

          <div className="flex items-center justify-between text-xs">
            <label className="flex items-center gap-2 text-slate-300 cursor-pointer">
              <input
                type="checkbox"
                checked={whitelistMyIp}
                onChange={e => setWhitelistMyIp(e.target.checked)}
                className="rounded border-slate-700 bg-slate-800 text-purple-600 focus:ring-0"
              />
              <span>Whitelist this IP ({authState.clientIp || 'Current'})</span>
            </label>
          </div>

          <div className="flex items-center justify-end gap-2 pt-2">
            {onClose && (
              <button
                type="button"
                onClick={onClose}
                className="px-4 py-2.5 rounded-xl text-xs text-slate-400 hover:text-white"
              >
                Close
              </button>
            )}
            <button
              type="submit"
              disabled={loading || success}
              className="flex items-center gap-2 px-6 py-2.5 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-bold shadow-lg shadow-purple-950 transition disabled:opacity-50"
            >
              <span>{loading ? 'Authenticating...' : 'Unlock & Authorize'}</span>
              <ArrowRight className="w-3.5 h-3.5" />
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
