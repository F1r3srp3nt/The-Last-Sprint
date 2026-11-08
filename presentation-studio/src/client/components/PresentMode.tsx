import { useCallback, useEffect, useRef, useState } from 'react';
import { narrationStatus } from '../../shared/narration';
import { blobUrl } from '../images';
import { useStudio } from '../state';
import { SlideCanvas } from './SlideCanvas';

export function PresentMode({ startIndex, onExit }: { startIndex: number; onExit: () => void }) {
  const { project, store } = useStudio();
  const [index, setIndex] = useState(Math.max(0, Math.min(startIndex, project.slides.length - 1)));
  const [withAudio, setWithAudio] = useState(false);
  const [autoAdvance, setAutoAdvance] = useState(false);
  const [paused, setPaused] = useState(false);
  const audio = useRef<HTMLAudioElement>(null);
  const root = useRef<HTMLDivElement>(null);
  const slide = project.slides[index];
  const hasAnyAudio = project.slides.some((s) => s.narration);
  const audioBlob = slide?.narration ? store.get(slide.narration.audioId) : undefined;
  const audioUrl = blobUrl(audioBlob);

  const go = useCallback((d: number) => setIndex((i) => Math.max(0, Math.min(project.slides.length - 1, i + d))), [project.slides.length]);

  useEffect(() => {
    root.current?.focus();
    const el = root.current;
    if (el?.requestFullscreen) el.requestFullscreen().catch(() => undefined);
    return () => {
      if (document.fullscreenElement) document.exitFullscreen().catch(() => undefined);
    };
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (['ArrowRight', 'PageDown', ' '].includes(e.key)) go(1);
      else if (['ArrowLeft', 'PageUp'].includes(e.key)) go(-1);
      else if (e.key === 'Escape') onExit();
      else if (e.key.toLowerCase() === 'p') setPaused((p) => !p);
      else return;
      e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [go, onExit]);

  // Play the current slide's narration when narration is on; stop it when the slide changes.
  useEffect(() => {
    const a = audio.current;
    if (!a) return;
    a.pause();
    if (withAudio && audioUrl && !paused) {
      a.currentTime = 0;
      void a.play().catch(() => setPaused(true));
    }
  }, [index, withAudio, audioUrl]);

  useEffect(() => {
    const a = audio.current;
    if (!a || !withAudio || !audioUrl) return;
    if (paused) a.pause();
    else void a.play().catch(() => undefined);
  }, [paused, withAudio, audioUrl]);

  if (!slide) return null;
  const st = narrationStatus(slide);

  return (
    <div className="present" ref={root} tabIndex={-1} role="dialog" aria-label="Presentation mode">
      <div className="present-stage" onClick={() => go(1)}>
        <SlideCanvas project={project} slide={slide} className="present-canvas" />
      </div>
      <audio ref={audio} src={audioUrl} onEnded={() => autoAdvance && index < project.slides.length - 1 && go(1)} />
      <div className="present-bar">
        <button className="btn icon" onClick={() => go(-1)} disabled={index === 0} aria-label="Previous slide">
          ←
        </button>
        <span className="mono">
          {index + 1} / {project.slides.length}
        </span>
        <button className="btn icon" onClick={() => go(1)} disabled={index === project.slides.length - 1} aria-label="Next slide">
          →
        </button>
        {hasAnyAudio && (
          <>
            <label className="check">
              <input type="checkbox" checked={withAudio} onChange={(e) => { setWithAudio(e.target.checked); setPaused(false); }} />
              <span>Play narration</span>
            </label>
            {withAudio && (
              <>
                <button className="btn small" onClick={() => setPaused((p) => !p)} disabled={!audioUrl}>
                  {paused ? '▶ Resume' : '❚❚ Pause'}
                </button>
                <label className="check">
                  <input type="checkbox" checked={autoAdvance} onChange={(e) => setAutoAdvance(e.target.checked)} />
                  <span>Advance when audio ends</span>
                </label>
                <span className="muted small">{!audioUrl ? 'No narration for this slide' : st === 'outdated' ? 'Narration is outdated' : ''}</span>
              </>
            )}
          </>
        )}
        <span className="spacer" />
        <span className="muted small">← → to navigate · P pause · Esc exit</span>
        <button className="btn small" onClick={onExit}>
          Exit
        </button>
      </div>
    </div>
  );
}
