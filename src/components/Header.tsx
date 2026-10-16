import React from 'react';
import { Shield, Play, Square, RotateCw, Plus, Terminal, Activity, Wifi } from 'lucide-react';
import { ServerState } from '../types';

interface HeaderProps {
  server: ServerState | null;
  onRefresh: () => void;
  onServerAction: (action: string) => void;
  onOpenAddPeer: () => void;
  activeTab: string;
  setActiveTab: (tab: string) => void;
}

export const Header: React.FC<HeaderProps> = ({
  server,
  onServerAction,
  onOpenAddPeer,
  activeTab,
  setActiveTab,
}) => {
  const isRunning = server?.status === 'running';

  const formatUptime = (seconds: number) => {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h ${mins}m`;
    if (hours > 0) return `${hours}h ${mins}m`;
    return `${mins}m`;
  };

  return (
    <header className="border-b border-slate-800 bg-[#090d16]/95 backdrop-blur-md sticky top-0 z-40">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex items-center justify-between py-3.5">
          {/* Logo & Identity */}
          <div className="flex items-center gap-3.5">
            <div className="relative">
              <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-emerald-500 to-purple-600 flex items-center justify-center shadow-lg shadow-emerald-950/40 border border-emerald-400/30">
                <span className="text-xl select-none">🍪</span>
              </div>
              <div className={`absolute -bottom-0.5 -right-0.5 w-3.5 h-3.5 rounded-full border-2 border-[#090d16] ${
                isRunning ? 'bg-emerald-500 animate-pulse' : 'bg-red-500'
              }`} />
            </div>

            <div>
              <div className="flex items-center gap-2">
                <h1 className="font-extrabold text-base sm:text-lg tracking-tight text-white flex items-center gap-1.5">
                  Cookie's Easy WireGuard
                </h1>
                <span className="text-[10px] uppercase font-bold tracking-wider px-2 py-0.5 rounded-md bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">
                  v2.6 Enterprise
                </span>
              </div>
              <p className="text-xs text-slate-400 hidden sm:flex items-center gap-2 font-mono">
                <span className="flex items-center gap-1">
                  <Wifi className="w-3 h-3 text-emerald-400" />
                  {server?.publicIp || '198.51.100.42'}:{server?.listenPort || 51820}
                </span>
                <span className="text-slate-600">•</span>
                <span className="text-slate-400">wg0 subnet: {server?.internalSubnet || '10.18.0.1/24'}</span>
                {server?.uptimeSeconds !== undefined && (
                  <>
                    <span className="text-slate-600">•</span>
                    <span className="text-emerald-400">Up {formatUptime(server.uptimeSeconds)}</span>
                  </>
                )}
              </p>
            </div>
          </div>

          {/* Quick Actions */}
          <div className="flex items-center gap-2 sm:gap-2.5">
            {isRunning ? (
              <button
                onClick={() => onServerAction('restart')}
                title="Graceful restart WireGuard"
                className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-medium border border-slate-700/80 transition"
              >
                <RotateCw className="w-3.5 h-3.5 text-slate-400" />
                <span className="hidden md:inline">Restart</span>
              </button>
            ) : null}

            {isRunning ? (
              <button
                onClick={() => onServerAction('stop')}
                className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-red-950/40 hover:bg-red-900/50 text-red-300 text-xs font-medium border border-red-800/40 transition"
              >
                <Square className="w-3.5 h-3.5 fill-red-400 text-red-400" />
                <span className="hidden sm:inline">Stop</span>
              </button>
            ) : (
              <button
                onClick={() => onServerAction('start')}
                className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold shadow-md shadow-emerald-950 transition"
              >
                <Play className="w-3.5 h-3.5 fill-white text-white" />
                <span>Start Server</span>
              </button>
            )}

            <button
              onClick={onOpenAddPeer}
              className="flex items-center gap-1.5 px-3.5 py-1.5 rounded-lg bg-gradient-to-r from-purple-600 to-indigo-600 hover:from-purple-500 hover:to-indigo-500 text-white text-xs font-semibold shadow-md shadow-purple-950/50 transition"
            >
              <Plus className="w-4 h-4" />
              <span>Add Peer</span>
            </button>
          </div>
        </div>

        {/* Navigation Tabs */}
        <nav className="flex items-center gap-1 overflow-x-auto no-scrollbar pt-1 border-t border-slate-800/60 -mx-4 px-4 sm:mx-0 sm:px-0">
          {[
            { id: 'overview', label: 'Overview', icon: Activity },
            { id: 'peers', label: `Clients (${server?.activePeersCount || 0})`, icon: Wifi },
            { id: 'shield', label: 'Geo & Anti-VPN Shield', icon: Shield },
            { id: 'tunnel', label: 'Split Tunneling', icon: Terminal },
            { id: 'backups', label: 'Encrypted Backups', icon: Shield },
            { id: 'logs', label: 'Journalctl Logs', icon: Terminal },
            { id: 'deploy', label: 'VPS Installer Script', icon: Play },
            { id: 'settings', label: 'Settings', icon: RotateCw },
          ].map(tab => {
            const Icon = tab.icon;
            const isActive = activeTab === tab.id;
            return (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`flex items-center gap-2 px-3.5 py-2.5 text-xs font-medium border-b-2 whitespace-nowrap transition ${
                  isActive
                    ? 'border-emerald-400 text-emerald-400 bg-emerald-500/5'
                    : 'border-transparent text-slate-400 hover:text-slate-200 hover:border-slate-700'
                }`}
              >
                <Icon className={`w-3.5 h-3.5 ${isActive ? 'text-emerald-400' : 'text-slate-400'}`} />
                {tab.label}
              </button>
            );
          })}
        </nav>
      </div>
    </header>
  );
};
