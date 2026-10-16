import React, { useState, useEffect } from 'react';
import { Terminal, Trash2, Copy, Check, Filter, Play, Pause } from 'lucide-react';
import { LogEntry } from '../types';

export const LogsTab: React.FC = () => {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [filter, setFilter] = useState<'all' | 'info' | 'warn' | 'error' | 'shield'>('all');
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [copied, setCopied] = useState(false);

  const fetchLogs = async () => {
    try {
      const res = await fetch('/api/logs');
      const data = await res.json();
      setLogs(data.logs);
    } catch (e) {
      console.error(e);
    }
  };

  useEffect(() => {
    fetchLogs();
    if (!autoRefresh) return;
    const interval = setInterval(fetchLogs, 4000);
    return () => clearInterval(interval);
  }, [autoRefresh]);

  const handleClear = async () => {
    try {
      await fetch('/api/logs/clear', { method: 'POST' });
      setLogs([]);
    } catch (e) {
      console.error(e);
    }
  };

  const handleCopy = () => {
    const text = logs.map(l => `[${l.timestamp}] [${l.service}] [${l.level.toUpperCase()}] ${l.message}`).join('\n');
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const filteredLogs = logs.filter(l => (filter === 'all' ? true : l.level === filter));

  const getLevelColor = (level: string) => {
    switch (level) {
      case 'shield': return 'text-purple-400 bg-purple-950/40 border-purple-800/40';
      case 'warn': return 'text-amber-400 bg-amber-950/40 border-amber-800/40';
      case 'error': return 'text-red-400 bg-red-950/40 border-red-800/40';
      default: return 'text-emerald-400 bg-emerald-950/40 border-emerald-800/40';
    }
  };

  return (
    <div className="space-y-6">
      {/* Top Controls */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-[#0f172a] border border-slate-800 p-4 rounded-2xl">
        <div className="flex items-center gap-3">
          <div className="p-2 rounded-xl bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">
            <Terminal className="w-5 h-5" />
          </div>
          <div>
            <h2 className="text-sm font-bold text-white flex items-center gap-2">
              WireGuard Kernel & Service Logs
              <span className="text-[10px] font-mono px-2 py-0.5 rounded bg-slate-800 text-slate-300">
                journalctl -u wg-quick@wg0
              </span>
            </h2>
            <p className="text-xs text-slate-400">Live operational diagnostics, packet filtering, and handshake telemetry</p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* Level Filter */}
          <div className="flex items-center bg-[#070b14] p-1 rounded-xl border border-slate-800 text-xs">
            {(['all', 'info', 'warn', 'error', 'shield'] as const).map(lvl => (
              <button
                key={lvl}
                onClick={() => setFilter(lvl)}
                className={`px-2.5 py-1 rounded-lg uppercase tracking-wider text-[10px] font-bold transition ${
                  filter === lvl ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                {lvl}
              </button>
            ))}
          </div>

          <button
            onClick={() => setAutoRefresh(!autoRefresh)}
            className={`p-2 rounded-xl border text-xs font-semibold flex items-center gap-1 transition ${
              autoRefresh
                ? 'bg-emerald-950/40 border-emerald-800/40 text-emerald-300'
                : 'bg-slate-800 border-slate-700 text-slate-400'
            }`}
            title={autoRefresh ? 'Pause auto stream' : 'Resume auto stream'}
          >
            {autoRefresh ? <Pause className="w-3.5 h-3.5" /> : <Play className="w-3.5 h-3.5" />}
          </button>

          <button
            onClick={handleCopy}
            className="p-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 border border-slate-700 transition"
            title="Copy logs"
          >
            {copied ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
          </button>

          <button
            onClick={handleClear}
            className="p-2 rounded-xl bg-slate-800 hover:bg-red-950/60 text-slate-400 hover:text-red-400 border border-slate-700 transition"
            title="Clear buffer"
          >
            <Trash2 className="w-3.5 h-3.5" />
          </button>
        </div>
      </div>

      {/* Terminal Display */}
      <div className="bg-[#050811] border border-slate-800/90 rounded-2xl p-4 sm:p-6 shadow-2xl font-mono text-xs overflow-hidden">
        <div className="flex items-center justify-between border-b border-slate-800/60 pb-3 mb-4 text-[11px] text-slate-500">
          <div className="flex items-center gap-2">
            <span className="w-3 h-3 rounded-full bg-red-500/80 inline-block"></span>
            <span className="w-3 h-3 rounded-full bg-amber-500/80 inline-block"></span>
            <span className="w-3 h-3 rounded-full bg-emerald-500/80 inline-block"></span>
            <span className="ml-2 font-semibold text-slate-400">root@easy-wireguard:~# journalctl -u wg-quick@wg0 -f</span>
          </div>
          <span>{filteredLogs.length} events logged</span>
        </div>

        <div className="space-y-2 max-h-[500px] overflow-y-auto leading-relaxed">
          {filteredLogs.length === 0 ? (
            <div className="text-slate-500 py-8 text-center font-sans">No log entries matching current filter.</div>
          ) : (
            filteredLogs.map(l => (
              <div key={l.id} className="flex flex-col sm:flex-row sm:items-start gap-2 py-1 hover:bg-slate-900/40 rounded px-1.5 transition">
                <span className="text-slate-500 shrink-0 text-[11px]">
                  {new Date(l.timestamp).toLocaleTimeString()}
                </span>
                <span className={`px-1.5 py-0.2 rounded text-[10px] font-bold border shrink-0 ${getLevelColor(l.level)}`}>
                  {l.service}
                </span>
                <span className={`break-all ${l.level === 'shield' ? 'text-purple-300' : l.level === 'error' ? 'text-red-300' : 'text-slate-300'}`}>
                  {l.message}
                </span>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
};
