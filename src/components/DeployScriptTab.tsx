import React, { useState, useEffect } from 'react';
import { Terminal, Copy, Check, Download, ExternalLink, ShieldCheck, Zap, Server } from 'lucide-react';
import { ServerState } from '../types';

interface DeployScriptTabProps {
  server: ServerState | null;
}

export const DeployScriptTab: React.FC<DeployScriptTabProps> = ({ server }) => {
  const [copiedOneLiner, setCopiedOneLiner] = useState(false);
  const [copiedScript, setCopiedScript] = useState(false);
  const [scriptText, setScriptText] = useState('');
  const [loading, setLoading] = useState(true);

  const oneLiner = 'curl -sSfL https://raw.githubusercontent.com/cookiebaits/cbwireguard/main/easy_wireguard.sh -o easy_wireguard.sh && chmod +x easy_wireguard.sh && sudo ./easy_wireguard.sh';

  useEffect(() => {
    fetch('/api/bash-script')
      .then(res => res.text())
      .then(text => {
        setScriptText(text);
        setLoading(false);
      })
      .catch(err => {
        console.error(err);
        setLoading(false);
      });
  }, []);

  const handleCopyOneLiner = () => {
    navigator.clipboard.writeText(oneLiner);
    setCopiedOneLiner(true);
    setTimeout(() => setCopiedOneLiner(false), 2000);
  };

  const handleCopyScript = () => {
    navigator.clipboard.writeText(scriptText);
    setCopiedScript(true);
    setTimeout(() => setCopiedScript(false), 2000);
  };

  const handleDownloadScript = () => {
    const blob = new Blob([scriptText], { type: 'text/x-shellscript' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'setup_wireguard.sh';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  return (
    <div className="space-y-6">
      {/* Hero Banner */}
      <div className="bg-gradient-to-r from-purple-950/40 via-[#0f172a] to-emerald-950/40 border border-slate-800 rounded-3xl p-6 sm:p-8 shadow-xl">
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-6">
          <div className="flex items-start gap-4">
            <div className="p-3.5 rounded-2xl bg-purple-500/10 text-purple-400 border border-purple-500/20">
              <Zap className="w-8 h-8" />
            </div>
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="text-xl font-bold text-white">One-Click Production Ubuntu VPS Installer</h2>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 font-semibold">
                  Ubuntu 20.04 / 22.04 / 24.04 LTS
                </span>
              </div>
              <p className="text-xs sm:text-sm text-slate-300 mt-1 max-w-2xl leading-relaxed">
                Deploy Cookie's WireGuard server directly onto any external VPS (DigitalOcean, Hetzner, Vultr, AWS, Linode). Runs non-interactively or with the interactive CLI menu, automatically applying BBR, FQ queuing, and Anti-VPN Geo Shielding.
              </p>
            </div>
          </div>
        </div>
      </div>

      {/* One-Liner Box */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Terminal className="w-4 h-4 text-emerald-400" />
            <span className="text-xs font-bold text-white uppercase tracking-wider">Quick Install Command (Root Shell)</span>
          </div>
          <button
            onClick={handleCopyOneLiner}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold shadow-md shadow-emerald-950 transition"
          >
            {copiedOneLiner ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
            <span>{copiedOneLiner ? 'Copied Command!' : 'Copy Command'}</span>
          </button>
        </div>

        <div className="p-4 rounded-xl bg-[#050811] border border-slate-800 text-emerald-400 font-mono text-xs overflow-x-auto select-all">
          {oneLiner}
        </div>
      </div>

      {/* Generated Script Viewer */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Server className="w-4 h-4 text-purple-400" />
            <span className="text-sm font-bold text-white">Generated Shell Script (`setup_wireguard.sh`)</span>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={handleCopyScript}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs border border-slate-700 transition"
            >
              {copiedScript ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
              <span>Copy Script</span>
            </button>
            <button
              onClick={handleDownloadScript}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold shadow-md shadow-purple-950 transition"
            >
              <Download className="w-3.5 h-3.5" />
              <span>Download .sh</span>
            </button>
          </div>
        </div>

        <pre className="p-4 rounded-xl bg-[#050811] border border-slate-800 text-slate-300 font-mono text-xs overflow-x-auto max-h-[420px] overflow-y-auto leading-relaxed select-all">
          {loading ? 'Compiling script...' : scriptText}
        </pre>
      </div>
    </div>
  );
};
