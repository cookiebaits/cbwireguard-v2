import React, { useState, useEffect } from 'react';
import { Header } from './components/Header';
import { OverviewTab } from './components/OverviewTab';
import { PeersTab } from './components/PeersTab';
import { GeoShieldTab } from './components/GeoShieldTab';
import { SplitTunnelingTab } from './components/SplitTunnelingTab';
import { BackupsTab } from './components/BackupsTab';
import { LogsTab } from './components/LogsTab';
import { DeployScriptTab } from './components/DeployScriptTab';
import { SettingsTab } from './components/SettingsTab';
import { QrModal } from './components/QrModal';
import { AddPeerModal } from './components/AddPeerModal';
import { ServerState, Peer, GeoShieldState, LogEntry } from './types';

export default function App() {
  const [activeTab, setActiveTab] = useState('overview');
  const [server, setServer] = useState<ServerState | null>(null);
  const [peers, setPeers] = useState<Peer[]>([]);
  const [geoShield, setGeoShield] = useState<GeoShieldState | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [selectedPeerForQr, setSelectedPeerForQr] = useState<Peer | null>(null);
  const [isAddPeerOpen, setIsAddPeerOpen] = useState(false);

  const fetchServer = async () => {
    try {
      const res = await fetch('/api/server');
      const data = await res.json();
      setServer(data);
    } catch (e) {
      console.error(e);
    }
  };

  const fetchPeers = async () => {
    try {
      const res = await fetch('/api/clients');
      const data = await res.json();
      setPeers(data.clients);
    } catch (e) {
      console.error(e);
    }
  };

  const fetchGeoShield = async () => {
    try {
      const res = await fetch('/api/geo-shield');
      const data = await res.json();
      setGeoShield(data);
    } catch (e) {
      console.error(e);
    }
  };

  const fetchLogs = async () => {
    try {
      const res = await fetch('/api/logs');
      const data = await res.json();
      setLogs(data.logs);
    } catch (e) {
      console.error(e);
    }
  };

  const refreshAll = () => {
    fetchServer();
    fetchPeers();
    fetchGeoShield();
    fetchLogs();
  };

  useEffect(() => {
    refreshAll();
    const interval = setInterval(() => {
      fetchServer();
      fetchPeers();
    }, 5000);
    return () => clearInterval(interval);
  }, []);

  const handleServerAction = async (action: string) => {
    try {
      await fetch('/api/server/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action }),
      });
      refreshAll();
    } catch (e) {
      console.error(e);
    }
  };

  return (
    <div className="min-h-screen bg-[#090d16] text-slate-100 flex flex-col selection:bg-purple-500 selection:text-white">
      {/* Top Header */}
      <Header
        server={server}
        onRefresh={refreshAll}
        onServerAction={handleServerAction}
        onOpenAddPeer={() => setIsAddPeerOpen(true)}
        activeTab={activeTab}
        setActiveTab={setActiveTab}
      />

      {/* Main Content Area */}
      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-6 sm:py-8">
        {activeTab === 'overview' && (
          <OverviewTab
            server={server}
            peers={peers}
            geoShield={geoShield}
            logs={logs}
            onSelectPeerForQr={p => setSelectedPeerForQr(p)}
            onOpenAddPeer={() => setIsAddPeerOpen(true)}
            onNavigateToTab={tab => setActiveTab(tab)}
          />
        )}

        {activeTab === 'peers' && (
          <PeersTab
            peers={peers}
            onSelectPeerForQr={p => setSelectedPeerForQr(p)}
            onOpenAddPeer={() => setIsAddPeerOpen(true)}
            onRefresh={refreshAll}
          />
        )}

        {activeTab === 'shield' && (
          <GeoShieldTab
            geoShield={geoShield}
            onRefresh={refreshAll}
          />
        )}

        {activeTab === 'tunnel' && (
          <SplitTunnelingTab />
        )}

        {activeTab === 'backups' && (
          <BackupsTab />
        )}

        {activeTab === 'logs' && (
          <LogsTab />
        )}

        {activeTab === 'deploy' && (
          <DeployScriptTab server={server} />
        )}

        {activeTab === 'settings' && (
          <SettingsTab server={server} onRefresh={refreshAll} />
        )}
      </main>

      {/* Footer */}
      <footer className="border-t border-slate-800/60 py-6 text-center text-xs text-slate-500 font-mono">
        <div className="max-w-7xl mx-auto px-4 flex flex-col sm:flex-row items-center justify-between gap-2">
          <span>Cookie's Easy WireGuard Server Suite • Hyper-Secured & Optimized</span>
          <span className="flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-emerald-400"></span>
            Host: Linux Kernel WireGuard
          </span>
        </div>
      </footer>

      {/* QR Code Modal */}
      <QrModal
        peer={selectedPeerForQr}
        onClose={() => setSelectedPeerForQr(null)}
      />

      {/* Add Peer Modal */}
      <AddPeerModal
        isOpen={isAddPeerOpen}
        onClose={() => setIsAddPeerOpen(false)}
        onAdded={refreshAll}
        defaultMtu={server?.defaultMtu || 1420}
        defaultDns={server?.defaultDns || '94.140.14.49, 9.9.9.9'}
        defaultAllowedIps={server?.defaultAllowedIps || '0.0.0.0/1, 128.0.0.0/1'}
      />
    </div>
  );
}
