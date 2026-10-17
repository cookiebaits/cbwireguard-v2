import React, { useState } from 'react';
import { Wifi, Plus, QrCode, Download, Trash2, Power, Edit2, Search, Check, X, Lock, ShieldCheck, Cpu } from 'lucide-react';
import { Peer } from '../types';

interface PeersTabProps {
  peers: Peer[];
  onSelectPeerForQr: (peer: Peer) => void;
  onOpenAddPeer: () => void;
  onRefresh: () => void;
  isRealSystemData?: boolean;
}

export const PeersTab: React.FC<PeersTabProps> = ({
  peers,
  onSelectPeerForQr,
  onOpenAddPeer,
  onRefresh,
  isRealSystemData = false,
}) => {
  const [searchTerm, setSearchTerm] = useState('');
  const [filter, setFilter] = useState<'all' | 'online' | 'idle' | 'disabled'>('all');
  const [editingPeer, setEditingPeer] = useState<Peer | null>(null);
  const [deleteConfirmId, setDeleteConfirmId] = useState<string | null>(null);
  const [editName, setEditName] = useState('');
  const [editAllowedIps, setEditAllowedIps] = useState('');
  const [editDns, setEditDns] = useState('');
  const [editMtu, setEditMtu] = useState<number>(1420);

  const formatBytes = (bytes: number) => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  };

  const handleTogglePeer = async (peer: Peer) => {
    try {
      await fetch(`/api/clients/${peer.id}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'x-cookie-auth-token': localStorage.getItem('cookie_wg_auth_token') || '',
        },
        body: JSON.stringify({ enabled: !peer.enabled }),
      });
      onRefresh();
    } catch (e) {
      console.error(e);
    }
  };

  const handleDeletePeer = async (id: string) => {
    try {
      await fetch(`/api/clients/${id}`, {
        method: 'DELETE',
        headers: {
          'x-cookie-auth-token': localStorage.getItem('cookie_wg_auth_token') || '',
        },
      });
      setDeleteConfirmId(null);
      onRefresh();
    } catch (e) {
      console.error(e);
    }
  };

  const startEdit = (peer: Peer) => {
    setEditingPeer(peer);
    setEditName(peer.name);
    setEditAllowedIps(peer.allowedIps);
    setEditDns(peer.dns);
    setEditMtu(peer.mtu);
  };

  const saveEdit = async () => {
    if (!editingPeer) return;
    try {
      await fetch(`/api/clients/${editingPeer.id}`, {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          'x-cookie-auth-token': localStorage.getItem('cookie_wg_auth_token') || '',
        },
        body: JSON.stringify({
          name: editName,
          allowedIps: editAllowedIps,
          dns: editDns,
          mtu: editMtu,
        }),
      });
      setEditingPeer(null);
      onRefresh();
    } catch (e) {
      console.error(e);
    }
  };

  const filteredPeers = peers.filter(p => {
    const matchesSearch = p.name.toLowerCase().includes(searchTerm.toLowerCase()) || p.ip.includes(searchTerm);
    if (!matchesSearch) return false;
    if (filter === 'online') return p.enabled && p.isOnline;
    if (filter === 'idle') return p.enabled && !p.isOnline;
    if (filter === 'disabled') return !p.enabled;
    return true;
  });

  return (
    <div className="space-y-6">
      {/* Zero Plain-Text & Live Kernel Status Banner */}
      <div className="bg-gradient-to-r from-[#0f172a] via-[#151f38] to-[#0f172a] border border-slate-800 rounded-2xl p-4 sm:p-5 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="p-2.5 rounded-xl bg-purple-500/10 text-purple-400 border border-purple-500/20 shrink-0">
            <Lock className="w-5 h-5" />
          </div>
          <div>
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-xs font-bold text-white">Zero Plain-Text Architecture</span>
              <span className="text-[10px] px-2 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 font-semibold">
                Curve25519 Masked
              </span>
              {isRealSystemData ? (
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-blue-500/10 text-blue-400 border border-blue-500/20 font-semibold flex items-center gap-1">
                  <Cpu className="w-3 h-3 text-blue-400" />
                  Live Linux wg0 Kernel Socket
                </span>
              ) : (
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-purple-500/10 text-purple-300 border border-purple-500/20 font-semibold">
                  Secure Host Sync
                </span>
              )}
            </div>
            <p className="text-[11px] text-slate-400 mt-0.5">
              Client private keys and sensitive tokens are strictly masked in the interface. Configs and QR codes are compiled on-demand in-memory.
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2 shrink-0 text-xs font-mono text-slate-400">
          <span>Subnet: <strong className="text-emerald-400">10.18.0.0/24</strong></span>
        </div>
      </div>

      {/* Top Action Bar */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-[#0f172a] border border-slate-800 p-4 rounded-2xl">
        <div className="flex items-center gap-3 flex-1 max-w-md">
          <div className="relative w-full">
            <Search className="w-4 h-4 text-slate-400 absolute left-3.5 top-1/2 -translate-y-1/2" />
            <input
              type="text"
              value={searchTerm}
              onChange={e => setSearchTerm(e.target.value)}
              placeholder="Search peer by name or IP (e.g. 10.18.0.2)..."
              className="w-full pl-9 pr-4 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-slate-200 placeholder-slate-500 focus:outline-none focus:border-emerald-500 transition"
            />
          </div>
        </div>

        <div className="flex items-center gap-2 overflow-x-auto">
          <div className="bg-[#070b14] p-1 rounded-xl border border-slate-800 flex items-center gap-1 text-xs">
            <button
              onClick={() => setFilter('all')}
              className={`px-3 py-1 rounded-lg transition ${filter === 'all' ? 'bg-slate-800 text-white font-medium' : 'text-slate-400 hover:text-slate-200'}`}
            >
              All ({peers.length})
            </button>
            <button
              onClick={() => setFilter('online')}
              className={`px-3 py-1 rounded-lg transition ${filter === 'online' ? 'bg-emerald-950/60 text-emerald-300 font-medium' : 'text-slate-400 hover:text-slate-200'}`}
            >
              Online ({peers.filter(p => p.enabled && p.isOnline).length})
            </button>
            <button
              onClick={() => setFilter('idle')}
              className={`px-3 py-1 rounded-lg transition ${filter === 'idle' ? 'bg-slate-800 text-white font-medium' : 'text-slate-400 hover:text-slate-200'}`}
            >
              Idle ({peers.filter(p => p.enabled && !p.isOnline).length})
            </button>
          </div>

          <button
            onClick={onOpenAddPeer}
            className="flex items-center gap-1.5 px-3.5 py-2 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold shadow-md shadow-purple-950 transition whitespace-nowrap"
          >
            <Plus className="w-4 h-4" />
            Add New Peer
          </button>
        </div>
      </div>

      {/* Peer Cards Table */}
      <div className="grid grid-cols-1 gap-4">
        {filteredPeers.length === 0 ? (
          <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-12 text-center text-slate-400">
            <Wifi className="w-10 h-10 mx-auto text-slate-600 mb-3" />
            <p className="text-sm font-medium">No WireGuard peers found matching your criteria.</p>
            <button
              onClick={onOpenAddPeer}
              className="mt-4 px-4 py-2 rounded-xl bg-purple-600 text-white text-xs font-semibold hover:bg-purple-500 transition"
            >
              Add First Peer
            </button>
          </div>
        ) : (
          filteredPeers.map(peer => (
            <div
              key={peer.id}
              className={`bg-[#0f172a] border rounded-2xl p-5 shadow-lg transition ${
                peer.enabled
                  ? 'border-slate-800 hover:border-slate-700'
                  : 'border-slate-800/60 opacity-60 bg-[#0b101d]'
              }`}
            >
              <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
                {/* Left Info */}
                <div className="flex items-start gap-4">
                  <div className={`p-3 rounded-2xl border shrink-0 ${
                    !peer.enabled
                      ? 'bg-slate-800/60 text-slate-500 border-slate-700'
                      : peer.isOnline
                      ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/30'
                      : 'bg-slate-800 text-slate-400 border-slate-700'
                  }`}>
                    <Wifi className="w-5 h-5" />
                  </div>

                  <div className="space-y-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      <h3 className="text-base font-bold text-white">{peer.name}</h3>
                      <span className="font-mono text-xs px-2 py-0.5 rounded bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 font-semibold">
                        {peer.ip}
                      </span>
                      <span className={`text-[11px] font-medium px-2 py-0.5 rounded-full border ${
                        !peer.enabled
                          ? 'bg-red-950/40 text-red-400 border-red-800/40'
                          : peer.isOnline
                          ? 'bg-emerald-500/20 text-emerald-400 border-emerald-500/30'
                          : 'bg-slate-800 text-slate-400 border-slate-700'
                      }`}>
                        {!peer.enabled ? 'Disabled' : peer.isOnline ? 'Online' : 'Idle'}
                      </span>
                      <span className="text-[10px] font-mono text-slate-500">
                        Pub: {peer.publicKey.slice(0, 8)}...
                      </span>
                    </div>

                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 gap-y-1 text-xs text-slate-400 pt-1 font-mono">
                      <div>
                        <span className="text-slate-500 font-sans">Endpoint:</span>{' '}
                        <span className="text-slate-300">{peer.endpoint || 'Awaiting connection'}</span>
                      </div>
                      <div>
                        <span className="text-slate-500 font-sans">Last Handshake:</span>{' '}
                        <span className="text-slate-300">{peer.lastHandshake}</span>
                      </div>
                      <div>
                        <span className="text-slate-500 font-sans">Transfer:</span>{' '}
                        <span className="text-emerald-400">↓ {formatBytes(peer.transferRx)}</span>{' '}
                        <span className="text-blue-400">↑ {formatBytes(peer.transferTx)}</span>
                      </div>
                      <div>
                        <span className="text-slate-500 font-sans">Scope:</span>{' '}
                        <span className="text-purple-300">{peer.allowedIps}</span>
                      </div>
                    </div>
                  </div>
                </div>

                {/* Right Actions */}
                <div className="flex items-center gap-2 shrink-0 self-end md:self-center">
                  <button
                    onClick={() => onSelectPeerForQr(peer)}
                    className="flex items-center gap-1.5 px-3 py-2 rounded-xl bg-emerald-500/10 hover:bg-emerald-500/20 text-emerald-400 text-xs font-semibold border border-emerald-500/30 transition shadow-sm"
                    title="View mobile QR Code"
                  >
                    <QrCode className="w-4 h-4" />
                    <span>Show QR</span>
                  </button>

                  <a
                    href={`/api/clients/${peer.id}/config`}
                    download={`${peer.name}.conf`}
                    className="flex items-center gap-1.5 px-3 py-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-medium border border-slate-700 transition"
                    title="Download client configuration file"
                  >
                    <Download className="w-4 h-4" />
                    <span className="hidden lg:inline">.conf</span>
                  </a>

                  <button
                    onClick={() => startEdit(peer)}
                    className="p-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 border border-slate-700 transition"
                    title="Edit peer configuration"
                  >
                    <Edit2 className="w-4 h-4" />
                  </button>

                  <button
                    onClick={() => handleTogglePeer(peer)}
                    className={`p-2 rounded-xl border transition ${
                      peer.enabled
                        ? 'bg-slate-800 hover:bg-slate-700 text-emerald-400 border-slate-700'
                        : 'bg-red-950/40 hover:bg-red-900/40 text-red-400 border-red-800/40'
                    }`}
                    title={peer.enabled ? 'Pause peer' : 'Enable peer'}
                  >
                    <Power className="w-4 h-4" />
                  </button>

                  {deleteConfirmId === peer.id ? (
                    <div className="flex items-center gap-1 bg-red-950/80 p-1 rounded-xl border border-red-800">
                      <button
                        onClick={() => handleDeletePeer(peer.id)}
                        className="px-2 py-1 bg-red-600 hover:bg-red-500 text-white rounded text-xs font-bold"
                      >
                        Confirm
                      </button>
                      <button
                        onClick={() => setDeleteConfirmId(null)}
                        className="p-1 text-slate-400 hover:text-white"
                      >
                        <X className="w-3.5 h-3.5" />
                      </button>
                    </div>
                  ) : (
                    <button
                      onClick={() => setDeleteConfirmId(peer.id)}
                      className="p-2 rounded-xl bg-slate-800 hover:bg-red-950/60 text-slate-400 hover:text-red-400 border border-slate-700 hover:border-red-800/40 transition"
                      title="Revoke peer"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))
        )}
      </div>

      {/* Edit Peer Modal */}
      {editingPeer && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-200">
          <div className="bg-[#0f172a] border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl space-y-4">
            <div className="flex items-center justify-between border-b border-slate-800 pb-3">
              <h3 className="text-base font-bold text-white">Edit Peer: {editingPeer.name}</h3>
              <button onClick={() => setEditingPeer(null)} className="text-slate-400 hover:text-white">
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="space-y-3">
              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase tracking-wider mb-1">
                  Device Name
                </label>
                <input
                  type="text"
                  value={editName}
                  onChange={e => setEditName(e.target.value)}
                  className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase tracking-wider mb-1">
                  Allowed IPs (Split Tunneling)
                </label>
                <input
                  type="text"
                  value={editAllowedIps}
                  onChange={e => setEditAllowedIps(e.target.value)}
                  className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white font-mono"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase tracking-wider mb-1">
                  DNS Resolvers
                </label>
                <input
                  type="text"
                  value={editDns}
                  onChange={e => setEditDns(e.target.value)}
                  className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white font-mono"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase tracking-wider mb-1">
                  MTU
                </label>
                <input
                  type="number"
                  value={editMtu}
                  onChange={e => setEditMtu(parseInt(e.target.value, 10))}
                  className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white font-mono"
                />
              </div>
            </div>

            <div className="flex justify-end gap-2 pt-3 border-t border-slate-800">
              <button
                onClick={() => setEditingPeer(null)}
                className="px-4 py-2 rounded-xl text-xs text-slate-400 hover:text-white"
              >
                Cancel
              </button>
              <button
                onClick={saveEdit}
                className="px-4 py-2 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold"
              >
                Save Changes
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
