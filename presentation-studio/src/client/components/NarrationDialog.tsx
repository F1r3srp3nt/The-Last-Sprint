import { useEffect, useMemo, useRef, useState } from 'react';
import type { ProviderStatus } from '../../shared/apiTypes';
import { narrationStatus, narrationText } from '../../shared/narration';
import type { NarrationApi } from '../narration';
import { useStudio } from '../state';
import { ErrorBox } from './Inspector';
import { Modal } from './Modal';

export function NarrationDialog({ status, narration, onClose, onOpenSetup }: { status: ProviderStatus | null; narration: NarrationApi; onClose: () => void; onOpenSetup: () => void }) {
  const { project } = useStudio();
  const [query, setQuery] = useState('');
  const [scope, setScope] = useState<'pending' | 'all'>('pending');
  const [confirming, setConfirming] = useState(false);
  const [playing, setPlaying] = useState<string | null>(null);
  const audio = useRef<HTMLAudioElement | null>(null);
  const configured = Boolean(status?.elevenlabs.configured);

  useEffect(() => {
    if (configured && narration.voices === null) void narration.loadVoices();
  }, [configured, narration]);
  useEffect(() => () => audio.current?.pause(), []);

  const voices = useMemo(() => {
    const q = query.trim().toLowerCase();
    return (narration.voices ?? []).filter((v) => !q || `${v.name} ${v.category} ${v.description} ${Object.values(v.labels).join(' ')}`.toLowerCase().includes(q));
  }, [narration.voices, query]);

  const targets = project.slides.filter((s) => {
    if (!narrationText(s)) return false;
    const st = narrationStatus(s);
    return scope === 'all' || st === 'none' || st === 'outdated';
  });
  const chars = targets.reduce((n, s) => n + narrationText(s).length, 0);
  const credits = status?.elevenlabs.credits;

  function preview(url: string | null, id: string) {
    audio.current?.pause();
    if (!url || playing === id) {
      setPlaying(null);
      return;
    }
    const a = new Audio(url);
    a.onended = () => setPlaying(null);
    void a.play();
    audio.current = a;
    setPlaying(id);
  }

  return (
    <Modal title="Narration" onClose={onClose} wide>
      {!configured ? (
        <div className="notice">
          ElevenLabs is not configured, so narration is off. Everything else works without it.{' '}
          <button className="link" onClick={onOpenSetup}>
            Open setup
          </button>
        </div>
      ) : (
        <div className="narration-dialog">
          <section>
            <h3>1 · Voice</h3>
            <p className="muted small">
              Voice previews are ElevenLabs sample clips and do not use credits. Narration uses model <code>{status?.elevenlabs.ttsModel}</code>.
            </p>
            <div className="row gap-s">
              <input className="grow" placeholder="Search voices (name, accent, style)…" value={query} onChange={(e) => setQuery(e.target.value)} aria-label="Search voices" />
              <button className="btn small ghost" onClick={() => narration.loadVoices()}>
                Refresh
              </button>
            </div>
            {narration.voicesError && <ErrorBox err={narration.voicesError} onRetry={() => narration.loadVoices()} />}
            {narration.voices === null && !narration.voicesError && <p className="muted small">Loading voices…</p>}
            {narration.voices && narration.voices.length === 0 && <p className="muted small">No voices found on this account. Add voices from the ElevenLabs Voice Library.</p>}
            <ul className="voice-list" data-testid="voice-list">
              {voices.map((v) => (
                <li key={v.voiceId} className={project.narration.voiceId === v.voiceId ? 'selected' : ''}>
                  <button className="btn icon" onClick={() => preview(v.previewUrl, v.voiceId)} disabled={!v.previewUrl} aria-label={`Preview ${v.name}`} title={v.previewUrl ? 'Play sample' : 'No sample available'}>
                    {playing === v.voiceId ? '■' : '▶'}
                  </button>
                  <div className="grow">
                    <b>{v.name}</b> <span className="muted small">{v.category}</span>
                    <div className="muted small">{[...Object.values(v.labels), v.description].filter(Boolean).join(' · ').slice(0, 140)}</div>
                  </div>
                  <button className={`btn small ${project.narration.voiceId === v.voiceId ? 'primary' : ''}`} onClick={() => narration.chooseVoice(v)}>
                    {project.narration.voiceId === v.voiceId ? 'Selected' : 'Use'}
                  </button>
                </li>
              ))}
            </ul>
          </section>

          <section>
            <h3>2 · Generate audio for the deck</h3>
            <div className="segmented" role="radiogroup" aria-label="Which slides">
              <button role="radio" aria-checked={scope === 'pending'} className={scope === 'pending' ? 'on' : ''} onClick={() => setScope('pending')}>
                Missing or outdated only
              </button>
              <button role="radio" aria-checked={scope === 'all'} className={scope === 'all' ? 'on' : ''} onClick={() => setScope('all')}>
                All slides with notes
              </button>
            </div>
            <p className="small">
              {targets.length} slide(s), {chars.toLocaleString()} characters of speaker notes.
              {credits && ` Your plan has used ${credits.used.toLocaleString()} of ${credits.limit.toLocaleString()} characters this period.`}
            </p>
            {narration.deck.running ? (
              <div className="progress">
                <div className="bar">
                  <div style={{ width: `${(narration.deck.done / Math.max(1, narration.deck.total)) * 100}%` }} />
                </div>
                <p className="small">
                  {narration.deck.done} / {narration.deck.total}
                </p>
                <button className="btn small ghost" onClick={narration.stopDeck}>
                  Stop after current slide
                </button>
              </div>
            ) : confirming ? (
              <div className="confirm-inline">
                <p className="small">
                  Send {chars.toLocaleString()} characters to ElevenLabs as <b>{project.narration.voiceName}</b>? This uses ElevenLabs credits.
                </p>
                <div className="row gap-s">
                  <button
                    className="btn primary"
                    onClick={() => {
                      setConfirming(false);
                      void narration.narrateSlides(targets.map((s) => s.id));
                    }}
                    data-testid="confirm-narrate-deck"
                  >
                    Generate {targets.length} audio file(s)
                  </button>
                  <button className="btn ghost" onClick={() => setConfirming(false)}>
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <button className="btn" disabled={!project.narration.voiceId || targets.length === 0} onClick={() => setConfirming(true)} data-testid="narrate-deck">
                {project.narration.voiceId ? `Narrate ${targets.length} slide(s)…` : 'Choose a voice first'}
              </button>
            )}
            {narration.deck.stoppedReason && <div className="alert error">Stopped: {narration.deck.stoppedReason}</div>}
            {!narration.deck.running && narration.deck.failed.length > 0 && (
              <div className="alert warn">
                {narration.deck.failed.length} slide(s) failed. Open a slide to see its error and retry it.
              </div>
            )}
            <p className="muted small">Audio failures never block editing or PowerPoint export.</p>
          </section>
        </div>
      )}
    </Modal>
  );
}
