import { useCallback, useEffect, useRef, useState } from 'react';
import type { ProviderStatus } from '../shared/apiTypes';
import { renderSlide } from '../shared/render';
import { getTheme } from '../shared/themes';
import { slugify } from '../shared/util';
import { exportPptxBytes } from '../export/pptx';
import { buildNarrationZip } from '../export/narrationZip';
import { loadProject, PROJECT_EXTENSION, saveProject } from '../project/projectFile';
import { emptyProject, type Project } from '../shared/model';
import { narrationStatus } from '../shared/narration';
import { api } from './api';
import { downloadBytes, imageForPptx } from './images';
import { useGeneration } from './generation';
import { useNarration } from './narration';
import { useStudio } from './state';
import { BriefStep } from './components/BriefStep';
import { Editor } from './components/Editor';
import { NarrationDialog } from './components/NarrationDialog';
import { PresentMode } from './components/PresentMode';
import { SetupDialog } from './components/SetupDialog';
import { SourcesStep } from './components/SourcesStep';

type Step = 'sources' | 'brief' | 'editor';
const STEPS: { id: Step; label: string }[] = [
  { id: 'sources', label: 'Images' },
  { id: 'brief', label: 'Brief' },
  { id: 'editor', label: 'Edit' },
];

export function App() {
  const studio = useStudio();
  const { project, store, update, replaceAll, markSaved, dirty, toast, toasts, dismissToast, selectedId } = studio;
  const [step, setStep] = useState<Step>('sources');
  const [status, setStatus] = useState<ProviderStatus | null>(null);
  const [setupOpen, setSetupOpen] = useState(false);
  const [narrationOpen, setNarrationOpen] = useState(false);
  const [presenting, setPresenting] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const openInput = useRef<HTMLInputElement>(null);
  const gen = useGeneration();
  const narration = useNarration();

  const refreshStatus = useCallback(async () => {
    try {
      setStatus(await api.status());
    } catch {
      setStatus(null);
    }
  }, []);
  useEffect(() => {
    void refreshStatus();
  }, [refreshStatus]);

  useEffect(() => {
    const onUnload = (e: BeforeUnloadEvent) => {
      if (dirty) e.preventDefault();
    };
    window.addEventListener('beforeunload', onUnload);
    return () => window.removeEventListener('beforeunload', onUnload);
  }, [dirty]);

  async function onSave() {
    setBusy('save');
    try {
      const bytes = await saveProject(project, store);
      downloadBytes(bytes, `${slugify(project.title)}${PROJECT_EXTENSION}`, 'application/zip');
      markSaved();
      toast('success', 'Project saved. It contains your images, slides and narration audio.');
    } catch (e) {
      toast('error', `Could not save: ${(e as Error).message}`);
    } finally {
      setBusy(null);
    }
  }

  async function onOpen(file: File) {
    if (dirty && !confirm('Open another project? Unsaved changes in this one will be lost.')) return;
    setBusy('open');
    try {
      const loaded = await loadProject(file);
      replaceAll(loaded.project, loaded.store);
      setStep(loaded.project.slides.length ? 'editor' : 'sources');
      toast('success', `Opened "${loaded.project.title}".`, loaded.warnings.join(' '));
    } catch (e) {
      toast('error', (e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  function newProject() {
    if (dirty && !confirm('Start a new project? Unsaved changes will be lost.')) return;
    replaceAll(emptyProject(), new Map());
    setStep('sources');
  }

  async function pptxBytes(p: Project) {
    return exportPptxBytes(p, async (id) => {
      const asset = p.assets.find((a) => a.id === id);
      const blob = store.get(id);
      return asset && blob ? imageForPptx(asset, blob) : null;
    });
  }

  function overflowSummary(): string[] {
    const theme = getTheme(project.themeId);
    return project.slides.flatMap((s, i) => renderSlide(s, theme, project.assets).warnings.filter((w) => w.level === 'warning').map((w) => `Slide ${i + 1}: ${w.message}`));
  }

  async function onExport(kind: 'pptx' | 'zip') {
    setExportOpen(false);
    const problems = overflowSummary();
    if (problems.length && !confirm(`Some text does not fit and may overflow in PowerPoint:\n\n${problems.slice(0, 8).join('\n')}\n\nExport anyway?`)) return;
    if (kind === 'zip') {
      const outdated = project.slides.filter((s) => narrationStatus(s) === 'outdated').length;
      if (outdated && !confirm(`${outdated} slide(s) have outdated narration (the notes changed). Export anyway? The mapping file marks them as outdated.`)) return;
    }
    setBusy('export');
    try {
      const bytes = await pptxBytes(project);
      if (kind === 'pptx') {
        downloadBytes(bytes, `${slugify(project.title)}.pptx`, 'application/vnd.openxmlformats-officedocument.presentationml.presentation');
      } else {
        downloadBytes(await buildNarrationZip(project, bytes, store), `${slugify(project.title)}-with-narration.zip`, 'application/zip');
      }
      toast('success', kind === 'pptx' ? 'PowerPoint exported.' : 'PowerPoint and narration exported.');
    } catch (e) {
      toast('error', `Export failed: ${(e as Error).message}`);
    } finally {
      setBusy(null);
    }
  }

  const hasNarration = project.slides.some((s) => s.narration);
  const startIndex = Math.max(0, project.slides.findIndex((s) => s.id === selectedId));
  const genReady = status?.generation.configured;
  const elReady = status?.elevenlabs.configured;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="logo" aria-hidden>
            ◆
          </span>
          <div>
            <div className="brand-name">Presentation Studio</div>
            <div className="brand-sub">Oslo Sprint</div>
          </div>
        </div>
        <input className="title-input" value={project.title} onChange={(e) => update((d) => void (d.title = e.target.value))} aria-label="Presentation title" data-testid="project-title" />
        <nav className="steps" aria-label="Steps">
          {STEPS.map((s, i) => (
            <button key={s.id} className={`step-tab ${step === s.id ? 'active' : ''}`} onClick={() => setStep(s.id)} aria-current={step === s.id ? 'step' : undefined} data-testid={`step-${s.id}`}>
              <span className="step-no">{i + 1}</span>
              {s.label}
            </button>
          ))}
        </nav>
        <div className="actions">
          <button className="provider-pill" onClick={() => setSetupOpen(true)} title="Providers: grey = not configured, amber = configured but not verified, green = verified, red = check failed" data-testid="open-setup">
            <span className={`dot ${genReady ? (status?.generation.verified === true ? 'ok' : status?.generation.verified === false ? 'bad' : 'idle') : 'off'}`} /> AI
            <span className={`dot ${elReady ? (status?.elevenlabs.verified === true ? 'ok' : status?.elevenlabs.verified === false ? 'bad' : 'idle') : 'off'}`} /> Voice
          </button>
          <button className="btn ghost small" onClick={newProject}>
            New
          </button>
          <button className="btn ghost small" onClick={() => openInput.current?.click()} disabled={busy !== null} data-testid="open-project">
            Open…
          </button>
          <input ref={openInput} type="file" accept={`${PROJECT_EXTENSION},application/zip`} hidden data-testid="open-input" onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void onOpen(f); }} />
          <button className="btn small" onClick={onSave} disabled={busy !== null} data-testid="save-project">
            {busy === 'save' ? 'Saving…' : `Save${dirty ? ' •' : ''}`}
          </button>
          <button className="btn small" onClick={() => setNarrationOpen(true)} disabled={project.slides.length === 0}>
            Narration
          </button>
          <button className="btn small" onClick={() => setPresenting(true)} disabled={project.slides.length === 0} data-testid="present">
            ▶ Present
          </button>
          <div className="add-wrap">
            <button className="btn small primary" onClick={() => setExportOpen((o) => !o)} disabled={project.slides.length === 0 || busy !== null} aria-expanded={exportOpen} data-testid="export">
              {busy === 'export' ? 'Exporting…' : 'Export ▾'}
            </button>
            {exportOpen && (
              <div className="menu right" role="menu">
                <button role="menuitem" onClick={() => onExport('pptx')} data-testid="export-pptx">
                  PowerPoint (.pptx)
                  <span className="muted small">Editable text, images and speaker notes</span>
                </button>
                {hasNarration && (
                  <button role="menuitem" onClick={() => onExport('zip')} data-testid="export-zip">
                    PowerPoint + narration (.zip)
                    <span className="muted small">.pptx, numbered MP3 files and a slide-to-audio mapping</span>
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      </header>

      {status === null && (
        <div className="banner error">
          The local server is not reachable. Editing and export still work in this tab; generation and voice features need the server (<code>npm run dev</code>).
        </div>
      )}

      <div className="content">
        {step === 'sources' && <SourcesStep onNext={() => setStep('brief')} />}
        {step === 'brief' && <BriefStep status={status} gen={gen} onOpenSetup={() => setSetupOpen(true)} onDone={() => setStep('editor')} />}
        {step === 'editor' && <Editor status={status} gen={gen} narration={narration} onOpenNarration={() => setNarrationOpen(true)} onGoBrief={() => setStep('brief')} />}
      </div>

      {setupOpen && <SetupDialog status={status} onStatus={setStatus} onClose={() => { setSetupOpen(false); void refreshStatus(); }} />}
      {narrationOpen && <NarrationDialog status={status} narration={narration} onClose={() => setNarrationOpen(false)} onOpenSetup={() => { setNarrationOpen(false); setSetupOpen(true); }} />}
      {presenting && <PresentMode startIndex={startIndex} onExit={() => setPresenting(false)} />}

      <div className="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.kind}`} role={t.kind === 'error' ? 'alert' : 'status'}>
            <div>
              <b>{t.message}</b>
              {t.hint && <div className="small">{t.hint}</div>}
            </div>
            <button className="btn icon tiny" onClick={() => dismissToast(t.id)} aria-label="Dismiss">
              ✕
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
