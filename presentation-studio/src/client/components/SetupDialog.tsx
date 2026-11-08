import { useState } from 'react';
import type { ProviderStatus } from '../../shared/apiTypes';
import { api, describeError } from '../api';
import type { ErrInfo } from '../generation';
import { ErrorBox } from './Inspector';
import { Modal } from './Modal';

function Chip({ state, yes, no, unknown }: { state: boolean | null; yes: string; no: string; unknown?: string }) {
  const cls = state === true ? 'ok' : state === false ? 'bad' : 'idle';
  return <span className={`status-chip ${cls}`}>{state === true ? yes : state === false ? no : unknown ?? 'Not checked'}</span>;
}

export function SetupDialog({ status, onStatus, onClose }: { status: ProviderStatus | null; onStatus: (s: ProviderStatus) => void; onClose: () => void }) {
  const [busy, setBusy] = useState<'gen' | 'el' | null>(null);
  const [err, setErr] = useState<ErrInfo | null>(null);

  const verify = async (which: 'gen' | 'el') => {
    setBusy(which);
    setErr(null);
    try {
      onStatus(which === 'gen' ? await api.verifyGeneration() : await api.verifyElevenLabs());
    } catch (e) {
      setErr(describeError(e));
    } finally {
      setBusy(null);
    }
  };
  const g = status?.generation;
  const el = status?.elevenlabs;

  return (
    <Modal title="Setup & providers" onClose={onClose} wide>
      {!status && <div className="alert error">Cannot reach the local server. Start it with <code>npm run dev</code> in <code>presentation-studio/</code>.</div>}
      {err && <ErrorBox err={err} />}
      <div className="setup-grid">
        <section className="card">
          <div className="card-head">
            <h3>Slide generation · Anthropic</h3>
          </div>
          <div className="status-rows">
            <div>
              Key configured <Chip state={g ? g.configured : null} yes="Yes" no="No" />
            </div>
            <div>
              Connection verified <Chip state={g?.configured ? g.verified : null} yes="Verified" no="Failed" unknown={g?.configured ? 'Not checked' : '—'} />
            </div>
            {g?.model && (
              <div>
                Model <code>{g.model}</code>
              </div>
            )}
          </div>
          {g?.lastError && <div className="alert error small">{g.lastError}</div>}
          <button className="btn small" disabled={!g?.configured || busy !== null} onClick={() => verify('gen')}>
            {busy === 'gen' ? 'Checking…' : 'Verify connection'}
          </button>
          <p className="muted small">Verifying looks up the model and does not generate anything.</p>
          <h4>Set up</h4>
          <ol className="small">
            <li>
              Create an API key in the Claude Console:{' '}
              <a href="https://platform.claude.com/settings/keys" target="_blank" rel="noreferrer">
                platform.claude.com/settings/keys
              </a>
              .
            </li>
            <li>
              Put it in <code>presentation-studio/.env</code> as <code>ANTHROPIC_API_KEY=…</code> (copy <code>.env.example</code>).
            </li>
            <li>Restart the server, then click <b>Verify connection</b>.</li>
          </ol>
          <p className="muted small">
            When you generate, your brief and downscaled copies of your images go to Anthropic. API usage is billed to that key. Without a key, template mode, editing and
            export still work.
          </p>
        </section>

        <section className="card">
          <div className="card-head">
            <h3>Voice · ElevenLabs</h3>
            <span className="pill small">optional</span>
          </div>
          <div className="status-rows">
            <div>
              Key configured <Chip state={el ? el.configured : null} yes="Yes" no="No" />
            </div>
            <div>
              Connection verified <Chip state={el?.configured ? el.verified : null} yes="Verified" no="Failed" unknown={el?.configured ? 'Not checked' : '—'} />
            </div>
            {el && (
              <div className="block">
                Models: <code>{el.sttModel}</code> speech-to-text · <code>{el.ttsModel}</code> narration
              </div>
            )}
            {el?.credits && (
              <div>
                Credits used {el.credits.used.toLocaleString()} / {el.credits.limit.toLocaleString()} ({el.credits.tier})
                {el.credits.resetsAt && <span className="muted"> · resets {new Date(el.credits.resetsAt).toLocaleDateString()}</span>}
              </div>
            )}
          </div>
          {el?.checks && el.checks.length > 0 && (
            <ul className="checks small">
              {el.checks.map((c, i) => (
                <li key={i} className={c.ok === null ? 'untested' : c.ok ? 'ok' : 'bad'}>
                  {c.ok === null ? '○' : c.ok ? '✓' : '✕'} {c.name} — <span className="muted">{c.detail}</span>
                </li>
              ))}
            </ul>
          )}
          {el?.lastError && !el.checks.length && <div className="alert error small">{el.lastError}</div>}
          <button className="btn small" disabled={!el?.configured || busy !== null} onClick={() => verify('el')} data-testid="verify-elevenlabs">
            {busy === 'el' ? 'Checking…' : 'Verify connection'}
          </button>
          <p className="muted small">Verifying lists voices and reads your credit balance; it does not use credits.</p>
          <h4>Set up</h4>
          <ol className="small">
            <li>
              Sign in at{' '}
              <a href="https://elevenlabs.io/app" target="_blank" rel="noreferrer">
                elevenlabs.io
              </a>{' '}
              and open{' '}
              <a href="https://elevenlabs.io/app/settings/api-keys" target="_blank" rel="noreferrer">
                Settings → API keys
              </a>
              . Create a key.
            </li>
            <li>
              If you restrict the key, allow <b>Text to Speech</b>, <b>Speech to Text</b> and reading <b>Voices</b>. Reading <b>User</b> is optional (it lets the app show your
              credit balance). Consider setting a credit limit on the key.
            </li>
            <li>
              Put it in <code>presentation-studio/.env</code> as <code>ELEVENLABS_API_KEY=…</code> and restart the server. The key stays on the server: it is never sent to
              the browser, saved in projects or exports, or logged.
            </li>
            <li>
              Click <b>Verify connection</b>. Then pick a voice under <b>Narration</b>. To use other voices, add them to <i>My Voices</i> from the{' '}
              <a href="https://elevenlabs.io/app/voice-library" target="_blank" rel="noreferrer">
                Voice Library
              </a>
              .
            </li>
          </ol>
          <p className="muted small">
            <b>Credits:</b> speech-to-text (spoken brief) and text-to-speech (narration) both use ElevenLabs credits. The app always asks before sending audio or text.
            Docs:{' '}
            <a href="https://elevenlabs.io/docs/api-reference/authentication" target="_blank" rel="noreferrer">
              authentication
            </a>
            ,{' '}
            <a href="https://elevenlabs.io/docs/overview/models" target="_blank" rel="noreferrer">
              models
            </a>
            .
          </p>
        </section>
      </div>
    </Modal>
  );
}
