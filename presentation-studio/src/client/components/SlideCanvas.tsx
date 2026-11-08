/**
 * Draws a RenderedSlide with absolutely positioned HTML. Positions are
 * percentages of the slide and font sizes are in points scaled to the
 * container width (container query units), so the preview uses exactly the
 * measurements the PowerPoint export uses.
 */
import { useLayoutEffect, useMemo, useRef } from 'react';
import type { Project, Slide } from '../../shared/model';
import { renderSlide, SLIDE_H, SLIDE_W, type RenderedSlide, type SlideElement } from '../../shared/render';
import { getTheme } from '../../shared/themes';
import { blobUrl } from '../images';
import { useStudio } from '../state';

const pct = (v: number, total: number) => `${(v / total) * 100}%`;
const pt = (v: number) => `calc(${v} * var(--pt))`;

function Element({ el, urls, showPlaceholders }: { el: SlideElement; urls: Map<string, string | undefined>; showPlaceholders: boolean }) {
  switch (el.kind) {
    case 'rect':
      return (
        <div
          className="sc-rect"
          style={{ left: pct(el.x, SLIDE_W), top: pct(el.y, SLIDE_H), width: pct(el.w, SLIDE_W), height: pct(el.h, SLIDE_H), background: `#${el.color}`, opacity: (100 - el.transparency) / 100 }}
        />
      );
    case 'image': {
      const { frame, draw } = el.geometry;
      const url = urls.get(el.assetId);
      return (
        <div className="sc-frame" style={{ left: pct(frame.x, SLIDE_W), top: pct(frame.y, SLIDE_H), width: pct(frame.w, SLIDE_W), height: pct(frame.h, SLIDE_H) }}>
          {url && (
            <img
              src={url}
              alt={el.altText}
              draggable={false}
              style={{ left: pct(draw.x - frame.x, frame.w), top: pct(draw.y - frame.y, frame.h), width: pct(draw.w, frame.w), height: pct(draw.h, frame.h) }}
            />
          )}
        </div>
      );
    }
    case 'imagePlaceholder':
      return showPlaceholders ? (
        <div className="sc-placeholder" style={{ left: pct(el.x, SLIDE_W), top: pct(el.y, SLIDE_H), width: pct(el.w, SLIDE_W), height: pct(el.h, SLIDE_H) }}>
          <span>No image · not exported</span>
        </div>
      ) : null;
    case 'text':
      return (
        <div
          className={`sc-text valign-${el.valign}`}
          data-role={el.role}
          style={{
            left: pct(el.x, SLIDE_W),
            top: pct(el.y, SLIDE_H),
            width: pct(el.w, SLIDE_W),
            height: pct(el.h, SLIDE_H),
            fontFamily: el.font.css,
            fontSize: pt(el.fontSize),
            color: `#${el.color}`,
            fontWeight: el.bold ? 700 : 400,
            fontStyle: el.italic ? 'italic' : 'normal',
            textAlign: el.align,
            lineHeight: el.lineHeight,
          }}
        >
          <div className="sc-text-inner">
            {el.paragraphs.map((p, i) => (
              <p key={i} className={el.bullets ? 'bullet' : undefined} style={{ marginBottom: i < el.paragraphs.length - 1 ? pt(el.paraSpacePt) : 0 }}>
                {p}
              </p>
            ))}
          </div>
        </div>
      );
  }
}

export function useRenderedSlide(project: Project, slide: Slide): RenderedSlide {
  return useMemo(() => renderSlide(slide, getTheme(project.themeId), project.assets), [slide, project.themeId, project.assets]);
}

export function SlideCanvas({
  project,
  slide,
  showPlaceholders = false,
  onDomOverflow,
  className,
}: {
  project: Project;
  slide: Slide;
  showPlaceholders?: boolean;
  /** Reports text boxes whose rendered text is taller than the box (a second check on top of the shared estimate). */
  onDomOverflow?: (roles: string[]) => void;
  className?: string;
}) {
  const { store, storeVersion } = useStudio();
  const rendered = useRenderedSlide(project, slide);
  const urls = useMemo(() => {
    const m = new Map<string, string | undefined>();
    for (const el of rendered.elements) if (el.kind === 'image') m.set(el.assetId, blobUrl(store.get(el.assetId)));
    return m;
    // storeVersion: re-resolve when binaries change
  }, [rendered, store, storeVersion]);
  const ref = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    if (!onDomOverflow || !ref.current) return;
    const check = () => {
      const roles: string[] = [];
      ref.current?.querySelectorAll<HTMLElement>('.sc-text').forEach((box) => {
        const inner = box.firstElementChild as HTMLElement | null;
        if (inner && inner.scrollHeight > box.clientHeight + 2) roles.push(box.dataset.role ?? 'text');
      });
      onDomOverflow(roles);
    };
    check();
    const ro = new ResizeObserver(check);
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, [rendered, onDomOverflow]);

  return (
    <div ref={ref} className={`slide-canvas ${className ?? ''}`} style={{ background: `#${rendered.background}` }} data-slide-id={slide.id}>
      {rendered.elements.map((el) => (
        <Element key={el.id} el={el} urls={urls} showPlaceholders={showPlaceholders} />
      ))}
    </div>
  );
}
