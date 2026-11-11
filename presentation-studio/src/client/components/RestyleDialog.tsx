import { useMemo, useState } from 'react';
import { THEME_IDS, type LayoutId, type Project, type ThemeId } from '../../shared/model';
import { applyRestyle, describeChange, planRestyle } from '../../shared/restyle';
import { THEMES } from '../../shared/themes';
import { Modal } from './Modal';
import { SlideCanvas } from './SlideCanvas';
import { ThemeSwatch } from './ThemeSwatch';

/** What "Undo restyle" puts back. */
export interface RestyleUndo {
  themeId: ThemeId;
  layouts: Record<string, LayoutId>;
}

/**
 * Restyles the current deck without any AI call: a theme and, optionally, layouts chosen from each
 * slide's own content. Text, speaker notes, images and narration are not changed.
 */
export function RestyleDialog({
  project,
  onApply,
  onClose,
}: {
  project: Project;
  onApply: (themeId: ThemeId, changes: ReturnType<typeof planRestyle>, undo: RestyleUndo) => void;
  onClose: () => void;
}) {
  const [themeId, setThemeId] = useState<ThemeId>(project.themeId);
  const [useLayouts, setUseLayouts] = useState(true);
  const changes = useMemo(() => planRestyle(project.slides), [project.slides]);
  const preview: Project = useMemo(
    () => ({ ...project, themeId, slides: useLayouts ? applyRestyle(project.slides, changes) : project.slides }),
    [project, themeId, useLayouts, changes],
  );
  const nothingToDo = themeId === project.themeId && (!useLayouts || changes.length === 0);

  function apply() {
    const undo: RestyleUndo = { themeId: project.themeId, layouts: Object.fromEntries(project.slides.map((s) => [s.id, s.layout])) };
    onApply(themeId, useLayouts ? changes : [], undo);
  }

  return (
    <Modal title="Restyle deck" onClose={onClose} wide>
      <p className="muted small">
        No AI is used and nothing is sent anywhere. Text, speaker notes, images and narration stay exactly as they are; only the theme and, if you choose,
        layouts that show the same text better are changed.
      </p>
      <div className="field">
        <span>Theme</span>
        <div className="theme-picker" role="radiogroup" aria-label="Deck theme">
          {THEME_IDS.map((id) => (
            <button
              key={id}
              role="radio"
              aria-checked={themeId === id}
              className={`theme-option ${themeId === id ? 'selected' : ''}`}
              onClick={() => setThemeId(id)}
              data-testid={`restyle-theme-${id}`}
            >
              <ThemeSwatch themeId={id} />
              <span>{THEMES[id].name}</span>
            </button>
          ))}
        </div>
        <span className="muted small">{THEMES[themeId].description}</span>
      </div>
      <label className="check">
        <input type="checkbox" checked={useLayouts} onChange={(e) => setUseLayouts(e.target.checked)} data-testid="restyle-layouts" />
        <span>Choose layouts from each slide's content ({changes.length === 0 ? 'all slides already fit' : `${changes.length} slide${changes.length === 1 ? '' : 's'} change`})</span>
      </label>
      {useLayouts && changes.length > 0 && (
        <ul className="small muted restyle-changes" data-testid="restyle-changes">
          {changes.map((c) => (
            <li key={c.slideId}>{describeChange(c)}</li>
          ))}
        </ul>
      )}
      <div className="restyle-preview" aria-label="Preview">
        {preview.slides.slice(0, 3).map((s) => (
          <SlideCanvas key={s.id} project={preview} slide={s} className="restyle-thumb" />
        ))}
      </div>
      <div className="row gap-s" style={{ justifyContent: 'flex-end', marginTop: 12 }}>
        <button className="btn ghost" onClick={onClose}>
          Cancel
        </button>
        <button className="btn primary" onClick={apply} disabled={nothingToDo} data-testid="restyle-apply">
          Apply
        </button>
      </div>
    </Modal>
  );
}
