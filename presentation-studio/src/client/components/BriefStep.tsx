import type { ProviderStatus } from '../../shared/apiTypes';
import { buildTemplateDeck } from '../../shared/deckBuild';
import { THEME_IDS } from '../../shared/model';
import { THEMES } from '../../shared/themes';
import { newId } from '../../shared/util';
import type { GenerationApi } from '../generation';
import { useStudio } from '../state';
import { SpokenBrief } from './SpokenBrief';
import { ThemeSwatch } from './ThemeSwatch';

export function BriefStep({
  status,
  gen,
  onOpenSetup,
  onDone,
}: {
  status: ProviderStatus | null;
  gen: GenerationApi;
  onOpenSetup: () => void;
  onDone: () => void;
}) {
  const { project, update, select, toast } = useStudio();
  const b = project.brief;
  const set = <K extends keyof typeof b>(k: K, v: (typeof b)[K]) =>
    update((d) => {
      d.brief[k] = v;
    });
  const aiReady = Boolean(status?.generation.configured);
  const running = ['preparing', 'outline', 'slides'].includes(gen.state.phase);
  const canGenerate = (b.topic.trim() || b.brief.trim()).length > 0;

  const confirmReplace = () =>
    project.slides.length === 0 || confirm(`This replaces the ${project.slides.length} slide(s) in the editor. Images stay in the project. Continue?`);

  function buildTemplate() {
    if (!confirmReplace()) return;
    const slides = buildTemplateDeck(b, project.assets, () => newId('slide'));
    update((d) => {
      d.slides = slides;
      d.title = b.topic.trim() || d.title;
      d.generation = { mode: 'template', provider: null, model: null, generatedAt: new Date().toISOString(), missingInfo: [] };
    });
    select(slides[0]?.id ?? null);
    toast('info', `Template deck with ${slides.length} slides created. No AI was used.`);
    onDone();
  }

  async function generate() {
    if (!confirmReplace()) return;
    await gen.start();
  }

  const jobs = gen.state.jobs;
  const done = jobs.filter((j) => j.status === 'done').length;
  const failed = jobs.filter((j) => j.status === 'error');

  return (
    <section className="step step-brief" aria-labelledby="brief-h">
      <header className="step-head">
        <div>
          <h2 id="brief-h">2 · Brief</h2>
          <p className="muted">Describe the presentation. The generator uses only what you write here and what your images show.</p>
        </div>
      </header>

      <div className="brief-grid">
        <div className="card">
          <label className="field">
            <span>Topic / working title</span>
            <input value={b.topic} onChange={(e) => set('topic', e.target.value)} placeholder="e.g. Fjordlight bike-share pilot" data-testid="topic" />
          </label>
          <label className="field">
            <span>Brief and key points</span>
            <textarea
              value={b.brief}
              onChange={(e) => set('brief', e.target.value)}
              rows={9}
              placeholder={'What is the presentation about? List the key points, one per line.\nInclude any facts or figures you want used — the generator will not invent them.'}
              data-testid="brief"
            />
          </label>
          <div className="grid-2">
            <label className="field">
              <span>Audience</span>
              <input value={b.audience} onChange={(e) => set('audience', e.target.value)} placeholder="e.g. City council transport committee" />
            </label>
            <label className="field">
              <span>Language</span>
              <input value={b.language} onChange={(e) => set('language', e.target.value)} list="languages" />
              <datalist id="languages">
                {['English', 'Norwegian (Bokmål)', 'Swedish', 'Danish', 'German', 'French', 'Spanish'].map((l) => (
                  <option key={l} value={l} />
                ))}
              </datalist>
            </label>
            <label className="field">
              <span>Number of slides</span>
              <input type="number" min={1} max={30} value={b.slideCount} onChange={(e) => set('slideCount', Math.max(1, Math.min(30, Number(e.target.value) || 1)))} data-testid="slide-count" />
            </label>
            <label className="field">
              <span>Tone</span>
              <input value={b.tone} onChange={(e) => set('tone', e.target.value)} list="tones" />
              <datalist id="tones">
                {['Clear and confident', 'Formal', 'Friendly', 'Inspiring', 'Technical', 'Concise'].map((t) => (
                  <option key={t} value={t} />
                ))}
              </datalist>
            </label>
          </div>
          <label className="check">
            <input type="checkbox" checked={b.includeNotes} onChange={(e) => set('includeNotes', e.target.checked)} />
            <span>Write speaker notes (needed for narration)</span>
          </label>
          <div className="field">
            <span>Deck style</span>
            <div className="theme-picker" role="radiogroup" aria-label="Deck theme">
              {THEME_IDS.map((id) => (
                <button
                  key={id}
                  role="radio"
                  aria-checked={project.themeId === id}
                  className={`theme-option ${project.themeId === id ? 'selected' : ''}`}
                  onClick={() => update((d) => void (d.themeId = id))}
                >
                  <ThemeSwatch themeId={id} />
                  <span>{THEMES[id].name}</span>
                </button>
              ))}
            </div>
          </div>
        </div>

        <div className="stack">
          <SpokenBrief
            available={Boolean(status?.elevenlabs.configured)}
            verified={status?.elevenlabs.verified ?? null}
            onOpenSetup={onOpenSetup}
            onUse={(text, mode) => {
              update((d) => {
                d.brief.brief = mode === 'replace' || !d.brief.brief.trim() ? text : `${d.brief.brief.trim()}\n${text}`;
              });
              toast('success', 'Transcript added to the brief. Review it before generating.');
            }}
          />

          <div className="card generate">
            <div className="card-head">
              <h3>Create the deck</h3>
            </div>
            {aiReady ? (
              <div className="notice" data-testid="data-notice">
                <b>Before you generate:</b> your brief and {project.assets.length} image{project.assets.length === 1 ? '' : 's'} (downscaled copies) will be sent to{' '}
                <b>Anthropic</b> ({status?.generation.model}) to plan and write the slides. Text inside images is treated as source material, not as instructions. The
                generator is told not to invent facts and to flag missing information instead.
              </div>
            ) : (
              <div className="notice muted">
                No AI provider is configured on the server, so AI generation is unavailable.{' '}
                <button className="link" onClick={onOpenSetup}>
                  Setup
                </button>
                . Template mode below works without AI.
              </div>
            )}
            <div className="row gap-s wrap">
              <button className="btn primary" disabled={!aiReady || running || !canGenerate} onClick={generate} data-testid="generate-ai">
                {running ? 'Generating…' : 'Send to Anthropic and generate'}
              </button>
              <button className="btn" disabled={running || !canGenerate} onClick={buildTemplate} data-testid="generate-template">
                Build from template (no AI)
              </button>
            </div>
            {!canGenerate && <p className="muted small">Add a topic or a brief first.</p>}
            <p className="muted small">
              Template mode only arranges your own text and images into slides and labels every slide <span className="origin-badge template">Template</span>. It never
              writes new content.
            </p>

            {gen.state.phase !== 'idle' && (
              <div className="progress" aria-live="polite" data-testid="progress">
                <ol className="progress-steps">
                  <li className={stepClass(gen.state.phase, 'preparing')}>Prepare images</li>
                  <li className={stepClass(gen.state.phase, 'outline')}>Plan outline</li>
                  <li className={stepClass(gen.state.phase, 'slides')}>
                    Write slides {jobs.length > 0 && `(${done}/${jobs.length})`}
                  </li>
                </ol>
                {jobs.length > 0 && (
                  <div className="bar">
                    <div style={{ width: `${(done / jobs.length) * 100}%` }} />
                  </div>
                )}
                {jobs.length > 0 && (
                  <ul className="jobs">
                    {jobs.map((j) => (
                      <li key={j.slideId} className={`job ${j.status}`}>
                        <span className="job-dot" aria-hidden />
                        <span>
                          {j.index + 1}. {j.title || 'Untitled'}
                        </span>
                        {j.status === 'error' && (
                          <>
                            <span className="small err">{j.error?.message}</span>
                            <button className="btn small" onClick={() => gen.retrySlide(j.slideId)}>
                              Retry
                            </button>
                          </>
                        )}
                      </li>
                    ))}
                  </ul>
                )}
                {gen.state.phase === 'error' && gen.state.error && (
                  <div className="alert error" role="alert">
                    <b>{gen.state.error.message}</b> {gen.state.error.hint}
                    {gen.state.error.details?.length ? <ul>{gen.state.error.details.map((d, i) => <li key={i}>{d}</li>)}</ul> : null}
                    <div className="row gap-s">
                      <button className="btn small" onClick={generate}>
                        Retry
                      </button>
                      <button className="btn small ghost" onClick={buildTemplate}>
                        Use template mode instead
                      </button>
                    </div>
                  </div>
                )}
                {gen.state.notices.length > 0 && (
                  <ul className="notices small muted">
                    {gen.state.notices.map((n, i) => (
                      <li key={i}>{n}</li>
                    ))}
                  </ul>
                )}
                <div className="row gap-s">
                  {running && (
                    <button className="btn small ghost" onClick={gen.cancel}>
                      Stop
                    </button>
                  )}
                  {failed.length > 1 && !running && (
                    <button className="btn small" onClick={gen.retryFailed}>
                      Retry {failed.length} failed slides
                    </button>
                  )}
                  {(gen.state.phase === 'done' || gen.state.phase === 'slides' || gen.state.phase === 'cancelled') && (
                    <button className="btn small primary" onClick={onDone}>
                      Open editor →
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}

const ORDER = ['preparing', 'outline', 'slides', 'done'];
function stepClass(phase: string, step: string) {
  const p = ORDER.indexOf(phase === 'cancelled' || phase === 'error' ? 'x' : phase);
  const s = ORDER.indexOf(step);
  if (phase === 'done' || p > s) return 'done';
  if (p === s) return 'active';
  return '';
}
