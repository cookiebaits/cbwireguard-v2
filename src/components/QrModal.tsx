import React, { useState, useEffect } from 'react';
import { X, Download, Copy, Check, QrCode, Shield, Smartphone } from 'lucide-react';
import { Peer } from '../types';

interface QrModalProps {
  peer: Peer | null;
  onClose: () => void;
}

export const QrModal: React.FC<QrModalProps> = ({ peer, onClose }) => {
  const [qrDataUrl, setQrDataUrl] = useState<string>('');
  const [rawConfig, setRawConfig] = useState<string>('');
  const [copied, setCopied] = useState<boolean>(false);
  const [loading, setLoading] = useState<boolean>(true);

  useEffect(() => {
    if (!peer) return;
    setLoading(true);
    fetch(`/api/clients/${peer.id}/qr`)
      .then(res => res.json())
      .then(data => {
        setQrDataUrl(data.dataUrl);
        setRawConfig(data.rawConfig);
        setLoading(false);
      })
      .catch(err => {
        console.error('Failed to load QR code:', err);
        setLoading(false);
      });
  }, [peer]);

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
    a.download = `${peer.name}.conf`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-200">
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl max-w-2xl w-full p-6 shadow-2xl overflow-hidden relative">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-slate-800/80 pb-4 mb-5">
          <div className="flex items-center gap-3">
            <div className="p-2.5 rounded-xl bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">
              <QrCode className="w-5 h-5" />
            </div>
            <div>
              <h2 className="text-lg font-bold text-slate-100 flex items-center gap-2">
                WireGuard Client Configuration
                <span className="text-xs px-2 py-0.5 rounded-full bg-emerald-500/20 text-emerald-400 border border-emerald-500/30">
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

        {/* Content Body */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 items-center">
          {/* QR Code Container */}
          <div className="flex flex-col items-center justify-center bg-[#070b14] border border-slate-800/80 rounded-xl p-6 text-center">
            {loading ? (
              <div className="w-56 h-56 flex items-center justify-center">
                <div className="w-8 h-8 border-2 border-emerald-500 border-t-transparent rounded-full animate-spin"></div>
              </div>
            ) : qrDataUrl ? (
              <div className="p-3 bg-white rounded-xl shadow-lg border border-slate-200">
                <img
                  src={qrDataUrl}
                  alt={`WireGuard QR for ${peer.name}`}
                  className="w-52 h-52 object-contain"
                />
              </div>
            ) : (
              <div className="text-red-400 text-sm">Failed to generate QR code</div>
            )}
            <div className="flex items-center gap-1.5 mt-4 text-xs text-slate-400">
              <Smartphone className="w-4 h-4 text-emerald-400" />
              <span>Scan directly with iOS / Android WireGuard app</span>
            </div>
          </div>

          {/* Config Details */}
          <div className="flex flex-col h-full justify-between space-y-4">
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Configuration File</span>
                <span className="text-xs text-slate-400 font-mono">MTU: {peer.mtu} | Keepalive: 25s</span>
              </div>
              <pre className="p-3 bg-[#070b14] border border-slate-800 rounded-lg text-xs font-mono text-slate-300 max-h-48 overflow-y-auto leading-relaxed select-all">
                {rawConfig || 'Generating...'}
              </pre>
            </div>

            <div className="space-y-2 pt-2">
              <div className="grid grid-cols-2 gap-2">
                <button
                  onClick={handleCopy}
                  className="flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-medium border border-slate-700 transition"
                >
                  {copied ? <Check className="w-4 h-4 text-emerald-400" /> : <Copy className="w-4 h-4" />}
                  {copied ? 'Copied Config!' : 'Copy Config'}
                </button>
                <button
                  onClick={handleDownload}
                  className="flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-medium shadow-md shadow-emerald-950 transition"
                >
                  <Download className="w-4 h-4" />
                  Download .conf
                </button>
              </div>
              <div className="flex items-center gap-1.5 text-[11px] text-slate-400 px-1">
                <Shield className="w-3.5 h-3.5 text-purple-400 shrink-0" />
                <span>Stealth split-tunneling AllowedIPs applied to eliminate streaming detection.</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
