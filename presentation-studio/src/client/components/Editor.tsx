import { useCallback, useEffect, useMemo, useState } from 'react';
import type { ProviderStatus } from '../../shared/apiTypes';
import { LAYOUT_IDS, LAYOUT_LABELS, newSlide, type LayoutId, type Slide } from '../../shared/model';
import { narrationStatus } from '../../shared/narration';
import { renderSlide } from '../../shared/render';
import { getTheme } from '../../shared/themes';
import { newId } from '../../shared/util';
import type { GenerationApi } from '../generation';
import type { NarrationApi } from '../narration';
import { useStudio } from '../state';
import { Inspector } from './Inspector';
import { SlideCanvas } from './SlideCanvas';

const ORIGIN_LABEL: Record<Slide['origin'], string> = { ai: 'AI draft', template: 'Template', manual: 'Manual' };

export function OriginBadge({ origin }: { origin: Slide['origin'] }) {
  return <span className={`origin-badge ${origin}`}>{ORIGIN_LABEL[origin]}</span>;
}

export function Editor({ status, gen, narration, onOpenNarration, onGoBrief }: { status: ProviderStatus | null; gen: GenerationApi; narration: NarrationApi; onOpenNarration: () => void; onGoBrief: () => void }) {
  const { project, update, selectedId, select } = useStudio();
  const [dragId, setDragId] = useState<string | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [domOverflow, setDomOverflow] = useState<string[]>([]);
  const selected = project.slides.find((s) => s.id === selectedId) ?? project.slides[0] ?? null;
  const theme = getTheme(project.themeId);
  const warningsById = useMemo(() => {
    const m = new Map<string, number>();
    for (const s of project.slides) m.set(s.id, renderSlide(s, theme, project.assets).warnings.filter((w) => w.level === 'warning').length);
    return m;
  }, [project.slides, project.assets, theme]);

  useEffect(() => {
    if (!selectedId && project.slides[0]) select(project.slides[0].id);
  }, [selectedId, project.slides, select]);

  const onDomOverflow = useCallback((roles: string[]) => setDomOverflow((prev) => (prev.join() === roles.join() ? prev : roles)), []);

  function move(id: string, to: number) {
    update((d) => {
      const from = d.slides.findIndex((s) => s.id === id);
      if (from < 0 || to < 0 || to >= d.slides.length || from === to) return;
      const [s] = d.slides.splice(from, 1);
      d.slides.splice(to, 0, s);
    });
  }
  function duplicate(id: string) {
    const copyId = newId('slide');
    update((d) => {
      const i = d.slides.findIndex((s) => s.id === id);
      if (i < 0) return;
      // Narration audio is not shared between slides; the copy starts without it.
      const copy = { ...structuredClone(d.slides[i]), id: copyId, narration: null };
      d.slides.splice(i + 1, 0, copy);
    });
    select(copyId);
  }
  function remove(id: string) {
    const i = project.slides.findIndex((s) => s.id === id);
    if (!confirm(`Delete slide ${i + 1}?`)) return;
    update((d) => {
      d.slides = d.slides.filter((s) => s.id !== id);
    });
    const next = project.slides[i + 1] ?? project.slides[i - 1];
    select(next && next.id !== id ? next.id : null);
  }
  function add(layout: LayoutId) {
    const id = newId('slide');
    update((d) => {
      const i = selected ? d.slides.findIndex((s) => s.id === selected.id) + 1 : d.slides.length;
      d.slides.splice(i, 0, newSlide(id, layout, 'manual', { title: layout === 'closing' ? 'Thank you' : 'New slide' }));
    });
    select(id);
    setAddOpen(false);
  }

  if (project.slides.length === 0) {
    return (
      <section className="step empty-editor">
        <div className="card center">
          <h2>No slides yet</h2>
          <p className="muted">Write a brief and generate a deck, or start with an empty slide.</p>
          <div className="row gap-s center">
            <button className="btn primary" onClick={onGoBrief}>
              Go to brief
            </button>
            <button className="btn" onClick={() => add('title')} data-testid="add-first-slide">
              Add a blank title slide
            </button>
          </div>
        </div>
      </section>
    );
  }

  const index = selected ? project.slides.findIndex((s) => s.id === selected.id) : -1;
  const rendered = selected ? renderSlide(selected, theme, project.assets) : null;

  return (
    <div className="editor">
      <aside className="slide-list" aria-label="Slides">
        <div className="list-head">
          <span className="muted small">{project.slides.length} slides</span>
          <div className="add-wrap">
            <button className="btn small primary" onClick={() => setAddOpen((o) => !o)} aria-expanded={addOpen} data-testid="add-slide">
              + Add slide
            </button>
            {addOpen && (
              <div className="menu" role="menu">
                {LAYOUT_IDS.map((l) => (
                  <button key={l} role="menuitem" onClick={() => add(l)}>
                    {LAYOUT_LABELS[l]}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
        {project.generation.mode === 'template' && (
          <div className="mode-banner template small">Template mode — arranged from your brief without AI.</div>
        )}
        <ol>
          {project.slides.map((s, i) => {
            const ns = narrationStatus(s);
            const warn = warningsById.get(s.id) ?? 0;
            return (
              <li
                key={s.id}
                className={`thumb-item ${s.id === selected?.id ? 'selected' : ''} ${dragId === s.id ? 'dragging' : ''}`}
                draggable
                onDragStart={() => setDragId(s.id)}
                onDragEnd={() => setDragId(null)}
                onDragOver={(e) => e.preventDefault()}
                onDrop={(e) => {
                  e.preventDefault();
                  if (dragId) move(dragId, i);
                  setDragId(null);
                }}
                data-testid="slide-thumb"
              >
                <button className="thumb-select" onClick={() => select(s.id)} aria-label={`Slide ${i + 1}: ${s.title || 'untitled'}`} aria-current={s.id === selected?.id}>
                  <span className="thumb-no">{i + 1}</span>
                  <SlideCanvas project={project} slide={s} className="thumb-canvas" />
                </button>
                <div className="thumb-meta">
                  <OriginBadge origin={s.origin} />
                  {warn > 0 && (
                    <span className="mini warn" title="Text does not fit">
                      ⚠ {warn}
                    </span>
                  )}
                  {s.flags.length > 0 && (
                    <span className="mini flag" title="Missing information flagged">
                      ? {s.flags.length}
                    </span>
                  )}
                  {ns === 'ready' && <span className="mini ok" title="Narration ready">♪</span>}
                  {ns === 'outdated' && <span className="mini warn" title="Narration outdated">♪!</span>}
                  <span className="spacer" />
                  <button className="btn icon tiny" onClick={() => move(s.id, i - 1)} disabled={i === 0} aria-label={`Move slide ${i + 1} up`} title="Move up">
                    ↑
                  </button>
                  <button className="btn icon tiny" onClick={() => move(s.id, i + 1)} disabled={i === project.slides.length - 1} aria-label={`Move slide ${i + 1} down`} title="Move down">
                    ↓
                  </button>
                  <button className="btn icon tiny" onClick={() => duplicate(s.id)} aria-label={`Duplicate slide ${i + 1}`} title="Duplicate">
                    ⧉
                  </button>
                  <button className="btn icon tiny danger" onClick={() => remove(s.id)} aria-label={`Delete slide ${i + 1}`} title="Delete">
                    ✕
                  </button>
                </div>
              </li>
            );
          })}
        </ol>
      </aside>

      <main className="stage" aria-label="Slide preview">
        {selected && rendered && (
          <>
            <div className="stage-head">
              <span className="muted small">
                Slide {index + 1} of {project.slides.length} · {LAYOUT_LABELS[selected.layout]} · 16:9 · preview uses the same layout as the PowerPoint export
              </span>
            </div>
            <div className="stage-canvas">
              <SlideCanvas key={selected.id} project={project} slide={selected} showPlaceholders onDomOverflow={onDomOverflow} className="main-canvas" />
            </div>
            <div className="stage-warnings" aria-live="polite">
              {rendered.warnings.map((w, i) => (
                <div key={i} className={`alert ${w.level === 'warning' ? 'warn' : 'info'}`} data-testid={w.level === 'warning' ? 'overflow-warning' : undefined}>
                  {w.message}
                </div>
              ))}
              {domOverflow.length > 0 && !rendered.warnings.some((w) => w.level === 'warning') && (
                <div className="alert warn">Some text is taller than its box in this browser's preview ({domOverflow.join(', ')}). Shorten it to be safe.</div>
              )}
            </div>
          </>
        )}
      </main>

      {selected && <Inspector key={selected.id} slide={selected} index={index} status={status} gen={gen} narration={narration} onOpenNarration={onOpenNarration} />}
    </div>
  );
}
