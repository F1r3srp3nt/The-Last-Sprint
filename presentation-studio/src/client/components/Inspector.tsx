import { useState } from 'react';
import type { ProviderStatus } from '../../shared/apiTypes';
import { defaultPlacement, IMAGE_LAYOUTS, LAYOUT_IDS, LAYOUT_LABELS, type LayoutId, type Slide } from '../../shared/model';
import { narrationStatus, narrationText } from '../../shared/narration';
import { LAYOUT_FIELDS } from '../../shared/render';
import { describeError } from '../api';
import type { ErrInfo, GenerationApi } from '../generation';
import { blobUrl } from '../images';
import type { NarrationApi } from '../narration';
import { useStudio } from '../state';
import { OriginBadge } from './Editor';

export function Inspector({
  slide,
  index,
  status,
  gen,
  narration,
  onOpenNarration,
}: {
  slide: Slide;
  index: number;
  status: ProviderStatus | null;
  gen: GenerationApi;
  narration: NarrationApi;
  onOpenNarration: () => void;
}) {
  const { project, store, updateSlide, toast } = useStudio();
  const set = (fn: (s: Slide) => void) => updateSlide(slide.id, fn);
  const hasFrame = IMAGE_LAYOUTS.has(slide.layout);

  return (
    <aside className="inspector" aria-label="Slide properties">
      <div className="insp-head">
        <h2>Slide {index + 1}</h2>
        <OriginBadge origin={slide.origin} />
      </div>

      {slide.flags.length > 0 && (
        <section className="insp-section flags">
          <h3>Flagged for your attention</h3>
          <ul>
            {slide.flags.map((f, i) => (
              <li key={i}>
                <span>{f}</span>
                <button className="btn icon tiny" aria-label="Dismiss flag" onClick={() => set((s) => void s.flags.splice(i, 1))}>
                  ✕
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="insp-section">
        <label className="field">
          <span>Layout</span>
          <select
            value={slide.layout}
            data-testid="layout-select"
            onChange={(e) => {
              const layout = e.target.value as LayoutId;
              set((s) => {
                s.layout = layout;
                if (s.image && layout === 'fullImage') s.image.mode = 'fill';
              });
            }}
          >
            {LAYOUT_IDS.map((l) => (
              <option key={l} value={l}>
                {LAYOUT_LABELS[l]}
              </option>
            ))}
          </select>
        </label>
        {LAYOUT_FIELDS[slide.layout].map(({ field, label, multiline }) => (
          <label className="field" key={field}>
            <span>{label}</span>
            {multiline ? (
              <textarea rows={field === 'body' || field.endsWith('Body') ? 5 : 2} value={slide[field] as string} onChange={(e) => set((s) => void ((s[field] as string) = e.target.value))} data-testid={`field-${field}`} />
            ) : (
              <input value={slide[field] as string} onChange={(e) => set((s) => void ((s[field] as string) = e.target.value))} data-testid={`field-${field}`} />
            )}
          </label>
        ))}
      </section>

      {hasFrame ? (
        <section className="insp-section">
          <h3>Image</h3>
          {project.assets.length === 0 ? (
            <p className="muted small">No images in the project. Add some on the Images step.</p>
          ) : (
            <div className="asset-picker" role="radiogroup" aria-label="Image for this slide">
              <button role="radio" aria-checked={!slide.image} className={`asset-choice none ${!slide.image ? 'selected' : ''}`} onClick={() => set((s) => void (s.image = null))}>
                None
              </button>
              {project.assets.map((a) => (
                <button
                  key={a.id}
                  role="radio"
                  aria-checked={slide.image?.assetId === a.id}
                  className={`asset-choice ${slide.image?.assetId === a.id ? 'selected' : ''}`}
                  title={a.caption || a.name}
                  onClick={() => set((s) => void (s.image = s.image ? { ...s.image, assetId: a.id } : defaultPlacement(a.id, s.layout)))}
                >
                  <img src={blobUrl(store.get(a.id))} alt={a.caption || a.name} />
                </button>
              ))}
            </div>
          )}
          {slide.image && (
            <>
              <div className="segmented" role="radiogroup" aria-label="Image placement">
                {(['fit', 'fill'] as const).map((m) => (
                  <button key={m} role="radio" aria-checked={slide.image!.mode === m} className={slide.image!.mode === m ? 'on' : ''} onClick={() => set((s) => void (s.image!.mode = m))}>
                    {m === 'fit' ? 'Fit (show whole image)' : 'Fill (crop to frame)'}
                  </button>
                ))}
              </div>
              {slide.image.mode === 'fill' && (
                <div className="crop-controls">
                  <Range label="Zoom" min={1} max={3} step={0.05} value={slide.image.zoom} format={(v) => `${v.toFixed(2)}×`} onChange={(v) => set((s) => void (s.image!.zoom = v))} />
                  <Range label="Crop position — horizontal" min={0} max={1} step={0.01} value={slide.image.focusX} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set((s) => void (s.image!.focusX = v))} />
                  <Range label="Crop position — vertical" min={0} max={1} step={0.01} value={slide.image.focusY} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => set((s) => void (s.image!.focusY = v))} />
                  <button className="btn small ghost" onClick={() => set((s) => void Object.assign(s.image!, { zoom: 1, focusX: 0.5, focusY: 0.5 }))}>
                    Reset crop
                  </button>
                  <p className="muted small">The crop is exported as a PowerPoint crop, so it can still be adjusted in PowerPoint.</p>
                </div>
              )}
            </>
          )}
        </section>
      ) : (
        slide.image && <p className="muted small insp-section">This layout has no image frame. The image choice is kept if you switch back.</p>
      )}

      <section className="insp-section">
        <label className="field">
          <span>Speaker notes</span>
          <textarea rows={6} value={slide.notes} onChange={(e) => set((s) => void (s.notes = e.target.value))} data-testid="field-notes" placeholder="What the presenter says. Also used for narration." />
        </label>
        <span className="muted small">{slide.notes.trim().length} characters</span>
      </section>

      <NarrationSection slide={slide} status={status} narration={narration} onOpenNarration={onOpenNarration} />

      <RegenerateSection slide={slide} status={status} gen={gen} onDone={(notices) => toast('success', 'Slide rewritten. Other slides were not changed.', notices.join(' '))} />
    </aside>
  );
}

function Range({ label, value, min, max, step, onChange, format }: { label: string; value: number; min: number; max: number; step: number; onChange: (v: number) => void; format: (v: number) => string }) {
  return (
    <label className="range">
      <span>
        {label} <b>{format(value)}</b>
      </span>
      <input type="range" min={min} max={max} step={step} value={value} onChange={(e) => onChange(Number(e.target.value))} />
    </label>
  );
}

function NarrationSection({ slide, status, narration, onOpenNarration }: { slide: Slide; status: ProviderStatus | null; narration: NarrationApi; onOpenNarration: () => void }) {
  const { project } = useStudio();
  const [confirming, setConfirming] = useState(false);
  const st = narrationStatus(slide);
  const busy = narration.busy.has(slide.id);
  const err = narration.errors[slide.id];
  const chars = narrationText(slide).length;
  const audio = narration.audioFor(slide.narration?.audioId);
  const configured = Boolean(status?.elevenlabs.configured);

  return (
    <section className="insp-section narration" aria-label="Narration">
      <div className="row between">
        <h3>Narration</h3>
        <span className={`status-chip ${st}`} data-testid="narration-status">
          {{ none: 'No audio', 'no-notes': 'No notes', ready: 'Up to date', outdated: 'Outdated' }[st]}
        </span>
      </div>
      {!configured ? (
        <p className="muted small">ElevenLabs is not configured. Narration is optional; editing and export work without it.</p>
      ) : (
        <>
          {st === 'outdated' && <p className="small warn-text">The speaker notes changed after this audio was made. Regenerate to match.</p>}
          {audio && <audio controls src={blobUrl(audio)} className="audio-inline" data-testid="slide-audio" />}
          {slide.narration && (
            <p className="muted small">
              {slide.narration.voiceName} · {slide.narration.modelId} · {slide.narration.characters} chars
            </p>
          )}
          {!project.narration.voiceId ? (
            <button className="btn small" onClick={onOpenNarration}>
              Choose a voice…
            </button>
          ) : chars === 0 ? (
            <p className="muted small">Write speaker notes to narrate this slide.</p>
          ) : confirming ? (
            <div className="confirm-inline">
              <p className="small">
                Send {chars} characters of speaker notes to ElevenLabs as <b>{project.narration.voiceName}</b>? This uses ElevenLabs credits.
              </p>
              <div className="row gap-s">
                <button
                  className="btn small primary"
                  data-testid="confirm-narrate"
                  onClick={async () => {
                    setConfirming(false);
                    await narration.narrateSlide(slide.id);
                  }}
                >
                  Generate audio
                </button>
                <button className="btn small ghost" onClick={() => setConfirming(false)}>
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <div className="row gap-s wrap">
              <button className="btn small" disabled={busy} onClick={() => setConfirming(true)} data-testid="narrate-slide">
                {busy ? 'Generating…' : slide.narration ? 'Regenerate narration' : 'Generate narration'}
              </button>
              {slide.narration && !busy && (
                <button className="btn small ghost" onClick={() => narration.removeNarration(slide.id)}>
                  Remove audio
                </button>
              )}
              <button className="btn small ghost" onClick={onOpenNarration}>
                Voice: {project.narration.voiceName}
              </button>
            </div>
          )}
          {err && <ErrorBox err={err} onRetry={err.retryable ? () => narration.narrateSlide(slide.id) : undefined} />}
        </>
      )}
    </section>
  );
}

function RegenerateSection({ slide, status, gen, onDone }: { slide: Slide; status: ProviderStatus | null; gen: GenerationApi; onDone: (notices: string[]) => void }) {
  const [instruction, setInstruction] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<ErrInfo | null>(null);
  if (!status?.generation.configured) {
    return (
      <section className="insp-section">
        <h3>Rewrite with AI</h3>
        <p className="muted small">Unavailable: no AI provider is configured. Edit the fields above by hand.</p>
      </section>
    );
  }
  const run = async () => {
    setBusy(true);
    setErr(null);
    try {
      const notices = await gen.regenerateSlide(slide.id, instruction);
      onDone(notices ?? []);
      setInstruction('');
    } catch (e) {
      setErr(describeError(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="insp-section">
      <h3>Rewrite this slide with AI</h3>
      <label className="field">
        <span>What should change? (optional)</span>
        <textarea rows={2} value={instruction} onChange={(e) => setInstruction(e.target.value)} placeholder="e.g. Shorter bullets, more formal" />
      </label>
      <p className="muted small">Sends the brief, this slide and its image to Anthropic. Replaces only this slide's text; other slides stay as they are.</p>
      <button className="btn small" disabled={busy} onClick={run} data-testid="regenerate-slide">
        {busy ? 'Rewriting…' : 'Regenerate slide'}
      </button>
      {err && <ErrorBox err={err} onRetry={err.retryable ? run : undefined} />}
    </section>
  );
}

export function ErrorBox({ err, onRetry }: { err: ErrInfo; onRetry?: () => void }) {
  return (
    <div className="alert error" role="alert">
      <b>{err.message}</b> {err.hint}
      {onRetry && (
        <div>
          <button className="btn small" onClick={onRetry}>
            Retry
          </button>
        </div>
      )}
    </div>
  );
}
