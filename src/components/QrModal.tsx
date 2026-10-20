import React, { useState, useEffect } from 'react';
import { X, Download, Copy, Check, QrCode, Shield, Smartphone, Cloud, CheckCircle2 } from 'lucide-react';
import { Peer } from '../types';

interface QrModalProps {
  peer: Peer | null;
  onClose: () => void;
  initialAntiFlag?: boolean;
}

export const QrModal: React.FC<QrModalProps> = ({ peer, onClose, initialAntiFlag = true }) => {
  const [profileType, setProfileType] = useState<'antiFlag' | 'standard'>(initialAntiFlag ? 'antiFlag' : 'standard');
  const [qrDataUrl, setQrDataUrl] = useState<string>('');
  const [rawConfig, setRawConfig] = useState<string>('');
  const [filename, setFilename] = useState<string>('');
  const [copied, setCopied] = useState<boolean>(false);
  const [loading, setLoading] = useState<boolean>(true);

  useEffect(() => {
    if (!peer) return;
    setLoading(true);
    const isAnti = profileType === 'antiFlag';
    fetch(`/api/clients/${peer.id}/qr?antiFlag=${isAnti}`)
      .then(res => res.json())
      .then(data => {
        setQrDataUrl(data.dataUrl);
        setRawConfig(data.rawConfig);
        setFilename(data.filename || (isAnti ? `${peer.name}-cloudflare-shield.conf` : `${peer.name}.conf`));
        setLoading(false);
      })
      .catch(err => {
        console.error('Failed to load QR code:', err);
        setLoading(false);
      });
  }, [peer, profileType]);

  if (!peer) return null;

  const handleCopy = () => {
    navigator.clipboard.writeText(rawConfig);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleDownload = () => {
    const blob = new Blob([rawConfig], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename || (profileType === 'antiFlag' ? `${peer.name}-cloudflare-shield.conf` : `${peer.name}.conf`);
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-200">
      <div className="bg-[#0f172a] border border-slate-800 rounded-3xl max-w-2xl w-full p-5 sm:p-6 shadow-2xl overflow-hidden relative">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-slate-800/80 pb-4 mb-4">
          <div className="flex items-center gap-3">
            <div className="p-2.5 rounded-2xl bg-amber-500/10 text-amber-400 border border-amber-500/20">
              <QrCode className="w-5 h-5" />
            </div>
            <div>
              <h2 className="text-base sm:text-lg font-bold text-slate-100 flex items-center gap-2 flex-wrap">
                WireGuard Client Profile
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 font-semibold">
                  {peer.name}
                </span>
              </h2>
              <p className="text-xs text-slate-400">Assigned Internal IP: <span className="font-mono text-emerald-300 font-semibold">{peer.ip}</span></p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 text-slate-400 hover:text-white rounded-lg hover:bg-slate-800 transition"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Profile Mode Selector Tabs */}
        <div className="grid grid-cols-2 gap-2 mb-4 p-1 bg-[#070b14] rounded-2xl border border-slate-800">
          <button
            type="button"
            onClick={() => setProfileType('antiFlag')}
            className={`flex flex-col items-center justify-center py-2 px-3 rounded-xl transition text-left text-xs ${
              profileType === 'antiFlag'
                ? 'bg-gradient-to-r from-amber-600 to-orange-600 text-white font-bold shadow-md shadow-amber-950'
                : 'text-slate-400 hover:text-slate-200 hover:bg-slate-800/50'
            }`}
          >
            <div className="flex items-center gap-1.5 font-bold">
              <Cloud className="w-3.5 h-3.5" />
              <span>Cloudflare Anti-Flag (Residential Direct)</span>
            </div>
            <span className={`text-[10px] mt-0.5 ${profileType === 'antiFlag' ? 'text-amber-100' : 'text-slate-500'}`}>
              Recommended • Zero Turnstile Captchas
            </span>
          </button>

          <button
            type="button"
            onClick={() => setProfileType('standard')}
            className={`flex flex-col items-center justify-center py-2 px-3 rounded-xl transition text-left text-xs ${
              profileType === 'standard'
                ? 'bg-slate-800 text-white font-bold shadow-md'
                : 'text-slate-400 hover:text-slate-200 hover:bg-slate-800/50'
            }`}
          >
            <div className="flex items-center gap-1.5 font-bold">
              <Shield className="w-3.5 h-3.5" />
              <span>Standard Full Tunnel</span>
            </div>
            <span className={`text-[10px] mt-0.5 ${profileType === 'standard' ? 'text-slate-300' : 'text-slate-500'}`}>
              0.0.0.0/0 • 100% via WireGuard VPS
            </span>
          </button>
        </div>

        {/* Mode Explanation Notice */}
        {profileType === 'antiFlag' ? (
          <div className="flex items-start gap-2 p-2.5 mb-4 rounded-xl bg-amber-500/10 border border-amber-500/25 text-amber-200 text-xs">
            <CheckCircle2 className="w-4 h-4 shrink-0 text-amber-400 mt-0.5" />
            <div className="leading-relaxed">
              <strong className="text-white">Cloudflare WAF & ISP Masking Active:</strong> Encrypts all internet traffic via VPS, but routes Cloudflare WAF, Turnstile, and CDN subnets through your home ISP. Completely stops Datacenter ASN blocks and Turnstile loops!
            </div>
          </div>
        ) : (
          <div className="flex items-start gap-2 p-2.5 mb-4 rounded-xl bg-slate-800/60 border border-slate-700/60 text-slate-300 text-xs">
            <Shield className="w-4 h-4 shrink-0 text-slate-400 mt-0.5" />
            <div className="leading-relaxed">
              <strong className="text-white">Standard Full Tunnel (0.0.0.0/0):</strong> All traffic routes through VPS. Cloudflare-protected sites will inspect your VPS datacenter ASN.
            </div>
          </div>
        )}

        {/* Content Body */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-5 items-center">
          {/* QR Code Container */}
          <div className="flex flex-col items-center justify-center bg-[#070b14] border border-slate-800/80 rounded-2xl p-5 text-center">
            {loading ? (
              <div className="w-48 h-48 sm:w-52 sm:h-52 flex items-center justify-center">
                <div className="w-8 h-8 border-2 border-amber-500 border-t-transparent rounded-full animate-spin"></div>
              </div>
            ) : qrDataUrl ? (
              <div className="p-3 bg-white rounded-2xl shadow-lg border border-slate-200">
                <img
                  src={qrDataUrl}
                  alt={`WireGuard QR for ${peer.name}`}
                  className="w-44 h-44 sm:w-48 sm:h-48 object-contain"
                />
              </div>
            ) : (
              <div className="text-red-400 text-sm">Failed to generate QR code</div>
            )}
            <div className="flex items-center gap-1.5 mt-3 text-xs text-slate-400">
              <Smartphone className="w-4 h-4 text-emerald-400" />
              <span>Scan directly with iOS / Android WireGuard app</span>
            </div>
          </div>

          {/* Config Details */}
          <div className="flex flex-col h-full justify-between space-y-3">
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">
                  {profileType === 'antiFlag' ? 'Cloudflare Anti-Flag .conf' : 'Standard .conf'}
                </span>
                <span className="text-[11px] text-slate-400 font-mono">MTU: {peer.mtu}</span>
              </div>
              <pre className="p-3 bg-[#070b14] border border-slate-800 rounded-xl text-[11px] font-mono text-slate-300 max-h-40 overflow-y-auto leading-relaxed select-all">
                {rawConfig || 'Generating...'}
              </pre>
            </div>

            <div className="space-y-2 pt-1">
              <div className="grid grid-cols-2 gap-2">
                <button
                  type="button"
                  onClick={handleCopy}
                  className="flex items-center justify-center gap-1.5 px-3 py-2.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-semibold border border-slate-700 transition"
                >
                  {copied ? <Check className="w-4 h-4 text-emerald-400" /> : <Copy className="w-4 h-4" />}
                  {copied ? 'Copied Config!' : 'Copy Config'}
                </button>
                <button
                  type="button"
                  onClick={handleDownload}
                  className={`flex items-center justify-center gap-1.5 px-3 py-2.5 rounded-xl text-white text-xs font-bold transition shadow-md ${
                    profileType === 'antiFlag'
                      ? 'bg-gradient-to-r from-amber-600 to-orange-600 hover:from-amber-500 hover:to-orange-500 shadow-amber-950'
                      : 'bg-emerald-600 hover:bg-emerald-500 shadow-emerald-950'
                  }`}
                >
                  <Download className="w-4 h-4" />
                  <span>Download .conf</span>
                </button>
              </div>
              <div className="text-[11px] text-slate-400 text-center font-mono truncate">
                File: {filename || (profileType === 'antiFlag' ? `${peer.name}-cloudflare-shield.conf` : `${peer.name}.conf`)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
