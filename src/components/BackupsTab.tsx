import React, { useState, useEffect } from 'react';
import { ShieldCheck, Plus, Trash2, RotateCcw, Key, Lock, FileArchive, Download, Check, AlertCircle } from 'lucide-react';
import { BackupItem } from '../types';

export const BackupsTab: React.FC = () => {
  const [backups, setBackups] = useState<BackupItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [createPassword, setCreatePassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [restoreId, setRestoreId] = useState<string | null>(null);
  const [restorePassword, setRestorePassword] = useState('');
  const [creating, setCreating] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  const fetchBackups = async () => {
    try {
      const res = await fetch('/api/backups');
      const data = await res.json();
      setBackups(data.backups);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchBackups();
  }, []);

  const handleCreateBackup = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!createPassword) {
      setMessage({ type: 'error', text: 'Please choose an encryption password.' });
      return;
    }
    if (createPassword !== confirmPassword) {
      setMessage({ type: 'error', text: 'Encryption passwords do not match.' });
      return;
    }

    setCreating(true);
    setMessage(null);

    try {
      const res = await fetch('/api/backups', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: createPassword }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to create backup');

      setMessage({ type: 'success', text: `Encrypted archive ${data.backup.filename} created successfully.` });
      setCreatePassword('');
      setConfirmPassword('');
      fetchBackups();
    } catch (err: any) {
      setMessage({ type: 'error', text: err.message });
    } finally {
      setCreating(false);
    }
  };

  const handleRestoreBackup = async () => {
    if (!restoreId || !restorePassword) return;
    setRestoring(true);
    setMessage(null);

    try {
      const res = await fetch(`/api/backups/${restoreId}/restore`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: restorePassword }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to restore backup');

      setMessage({ type: 'success', text: data.message });
      setRestoreId(null);
      setRestorePassword('');
    } catch (err: any) {
      setMessage({ type: 'error', text: err.message });
    } finally {
      setRestoring(false);
    }
  };

  const handleDeleteBackup = async (id: string) => {
    try {
      await fetch(`/api/backups/${id}`, { method: 'DELETE' });
      fetchBackups();
    } catch (e) {
      console.error(e);
    }
  };

  return (
    <div className="space-y-6">
      {/* Top Banner */}
      <div className="bg-[#0f172a] border border-slate-800 rounded-3xl p-6 sm:p-8 shadow-xl">
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-6">
          <div className="flex items-start gap-4">
            <div className="p-3.5 rounded-2xl bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">
              <Lock className="w-8 h-8" />
            </div>
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="text-xl font-bold text-white">AES-256 Encrypted Backup Vault</h2>
                <span className="text-xs px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 font-semibold">
                  PBKDF2 Salted
                </span>
              </div>
              <p className="text-xs sm:text-sm text-slate-300 mt-1 max-w-2xl leading-relaxed">
                Complete server configurations, private cryptographic keys, and peer credentials are archived into an OpenSSL AES-256-CBC encrypted .tar.gz.enc payload. No plain-text keys are stored on disk.
              </p>
            </div>
          </div>
        </div>
      </div>

      {message && (
        <div className={`p-4 rounded-xl flex items-center gap-2 text-xs font-medium border ${
          message.type === 'success'
            ? 'bg-emerald-950/60 border-emerald-800/80 text-emerald-300'
            : 'bg-red-950/60 border-red-800/80 text-red-300'
        }`}>
          {message.type === 'success' ? <Check className="w-4 h-4 text-emerald-400" /> : <AlertCircle className="w-4 h-4 text-red-400" />}
          <span>{message.text}</span>
        </div>
      )}

      {/* Main Grid: Create Backup & Backup Archives */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Create Backup Box */}
        <div className="bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
          <h3 className="text-sm font-bold text-white flex items-center gap-2">
            <Key className="w-4 h-4 text-emerald-400" />
            Create Encrypted Archive
          </h3>
          <p className="text-xs text-slate-400">
            Choose a strong passphrase to encrypt current server keys and all active peer records.
          </p>

          <form onSubmit={handleCreateBackup} className="space-y-3 pt-1">
            <div>
              <label className="block text-xs font-semibold text-slate-400 uppercase tracking-wider mb-1">
                Encryption Password
              </label>
              <input
                type="password"
                value={createPassword}
                onChange={e => setCreatePassword(e.target.value)}
                placeholder="Enter passphrase..."
                className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white focus:border-emerald-500"
                required
              />
            </div>
            <div>
              <label className="block text-xs font-semibold text-slate-400 uppercase tracking-wider mb-1">
                Confirm Password
              </label>
              <input
                type="password"
                value={confirmPassword}
                onChange={e => setConfirmPassword(e.target.value)}
                placeholder="Re-type passphrase..."
                className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white focus:border-emerald-500"
                required
              />
            </div>

            <button
              type="submit"
              disabled={creating}
              className="w-full py-2.5 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-bold transition shadow-md shadow-emerald-950 flex items-center justify-center gap-2 disabled:opacity-50"
            >
              <Lock className="w-4 h-4" />
              <span>{creating ? 'Encrypting Archive...' : 'Create Encrypted Backup'}</span>
            </button>
          </form>
        </div>

        {/* Existing Backups List */}
        <div className="lg:col-span-2 bg-[#0f172a] border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
          <h3 className="text-sm font-bold text-white flex items-center gap-2">
            <FileArchive className="w-4 h-4 text-purple-400" />
            Existing Server Archives ({backups.length})
          </h3>

          <div className="space-y-3">
            {backups.length === 0 ? (
              <div className="p-8 text-center text-xs text-slate-400 border border-dashed border-slate-800 rounded-xl">
                No backup archives found. Create one using the form on the left.
              </div>
            ) : (
              backups.map(b => (
                <div
                  key={b.id}
                  className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-xl bg-[#070b14] border border-slate-800 hover:border-slate-700 transition gap-4"
                >
                  <div className="flex items-start gap-3">
                    <div className="p-2 rounded-xl bg-purple-500/10 text-purple-400 border border-purple-500/20 shrink-0">
                      <FileArchive className="w-4 h-4" />
                    </div>
                    <div>
                      <div className="text-xs font-bold text-slate-200 font-mono break-all">{b.filename}</div>
                      <div className="flex flex-wrap items-center gap-2 text-[11px] text-slate-400 mt-1 font-mono">
                        <span className="text-emerald-400 font-semibold">{b.sizeFormatted}</span>
                        <span>•</span>
                        <span>{new Date(b.createdAt).toLocaleString()}</span>
                        <span>•</span>
                        <span>{b.clientCount} peers included</span>
                        <span>•</span>
                        <span className="text-purple-400">AES-256</span>
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2 shrink-0 self-end sm:self-center">
                    <button
                      onClick={() => setRestoreId(b.id)}
                      className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-purple-600/20 hover:bg-purple-600/30 text-purple-300 text-xs font-medium border border-purple-500/30 transition"
                    >
                      <RotateCcw className="w-3.5 h-3.5" />
                      Restore
                    </button>
                    <button
                      onClick={() => handleDeleteBackup(b.id)}
                      className="p-1.5 rounded-lg bg-slate-800 hover:bg-red-950/60 text-slate-400 hover:text-red-400 border border-slate-700 transition"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>

      {/* Restore Password Prompt Modal */}
      {restoreId && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-200">
          <div className="bg-[#0f172a] border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl space-y-4">
            <h3 className="text-base font-bold text-white flex items-center gap-2">
              <Key className="w-5 h-5 text-emerald-400" />
              Decryption Password Required
            </h3>
            <p className="text-xs text-slate-300">
              Enter the OpenSSL master passphrase to decrypt and restore server configurations.
            </p>

            <input
              type="password"
              value={restorePassword}
              onChange={e => setRestorePassword(e.target.value)}
              placeholder="Enter master password..."
              className="w-full px-3 py-2 rounded-xl bg-[#070b14] border border-slate-800 text-xs text-white"
              autoFocus
            />

            <div className="flex justify-end gap-2 pt-2 border-t border-slate-800">
              <button
                onClick={() => setRestoreId(null)}
                className="px-4 py-2 rounded-xl text-xs text-slate-400 hover:text-white"
              >
                Cancel
              </button>
              <button
                onClick={handleRestoreBackup}
                disabled={restoring}
                className="px-4 py-2 rounded-xl bg-purple-600 hover:bg-purple-500 text-white text-xs font-semibold"
              >
                {restoring ? 'Decrypting...' : 'Decrypt & Restore'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
