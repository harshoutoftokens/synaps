'use client';

import { useEffect, useState } from 'react';
import { KeyRound } from 'lucide-react';
import { isValidApiToken, subscribeTokenRequests, type TokenRequest } from '@/lib/api';

/**
 * Modal shown when the server answers 401 (API token auth enabled on the backend).
 * Requests that hit the 401 wait on it and are retried once a token is saved.
 */
export function TokenPrompt() {
  const [request, setRequest] = useState<TokenRequest | null>(null);
  const [value, setValue] = useState('');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => subscribeTokenRequests(setRequest), []);

  useEffect(() => {
    setValue('');
    setError(null);
  }, [request]);

  if (!request) return null;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const token = value.trim();
    if (!token) {
      setError('Enter the token configured on the server (SYNAPS_API_TOKEN).');
      return;
    }
    if (!isValidApiToken(token)) {
      setError('Tokens can’t contain spaces, quotes, commas, semicolons or backslashes.');
      return;
    }
    request.submit(token);
  };

  return (
    <div
      className="fixed inset-0 z-[200] flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="token-prompt-title"
      onKeyDown={(e) => {
        if (e.key === 'Escape') request.submit(null);
      }}
    >
      <form onSubmit={submit} className="glass-card w-full max-w-sm" style={{ background: 'var(--glass-bg-elevated)' }}>
        <div className="flex items-center gap-3 mb-3">
          <div className="w-9 h-9 rounded-xl bg-[var(--accent-muted)] flex items-center justify-center shrink-0">
            <KeyRound size={18} className="text-[var(--accent)]" />
          </div>
          <h2 id="token-prompt-title" className="text-[14px] font-semibold text-[var(--text-primary)]">
            API token required
          </h2>
        </div>
        <p className="text-[12px] text-[var(--text-secondary)] mb-4 leading-relaxed">
          {request.rejected
            ? 'The server rejected the saved token. Enter the current one to continue.'
            : 'This Synaps server requires an access token. It is stored in a cookie in this browser only.'}
        </p>
        <input
          type="password"
          autoFocus
          autoComplete="off"
          spellCheck={false}
          value={value}
          onChange={(e) => {
            setValue(e.target.value);
            setError(null);
          }}
          placeholder="API token"
          aria-label="API token"
          className="glass-input mb-2"
        />
        {error && <p className="text-[11px] text-red-400 mb-2">{error}</p>}
        <div className="flex gap-2 mt-3">
          <button
            type="button"
            onClick={() => request.submit(null)}
            className="flex-1 px-4 py-2.5 rounded-xl text-[13px] font-medium text-[var(--text-secondary)] bg-[var(--glass-bg)] hover:bg-[var(--glass-bg-hover)] transition-all border border-[var(--glass-border)]"
          >
            Cancel
          </button>
          <button type="submit" className="btn-accent flex-1 justify-center">
            Save
          </button>
        </div>
      </form>
    </div>
  );
}
