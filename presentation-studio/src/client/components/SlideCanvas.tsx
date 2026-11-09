/**
 * Draws a RenderedSlide with absolutely positioned HTML. Positions are
 * percentages of the slide and font sizes are in points scaled to the
 * container width (container query units), so the preview uses exactly the
 * measurements the PowerPoint export uses.
 */
import { useLayoutEffect, useMemo, useRef } from 'react';
import type { Project, Slide } from '../../shared/model';
import { renderSlide, SLIDE_H, SLIDE_W, type RenderedSlide, type ShapeElement, type SlideElement } from '../../shared/render';
import { getTheme } from '../../shared/themes';
import { blobUrl } from '../images';
import { useStudio } from '../state';

const pct = (v: number, total: number) => `${(v / total) * 100}%`;
const pt = (v: number) => `calc(${v} * var(--pt))`;
/** Inches to the preview's point unit (1 in = 72 pt). */
const inch = (v: number) => pt(v * 72);
/** PptxGenJS transparency (0 opaque … 100 invisible) as a CSS colour. */
function rgba(hex: string, transparency = 0): string {
  const n = parseInt(hex, 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${(100 - transparency) / 100})`;
}

/** Native PowerPoint shapes, drawn with the same geometry (hexagon: corners cut at a quarter of the shorter side, as in PowerPoint's preset). */
function Shape({ el }: { el: ShapeElement }) {
  const box = { left: pct(el.x, SLIDE_W), top: pct(el.y, SLIDE_H), width: pct(el.w, SLIDE_W), height: pct(el.h, SLIDE_H) };
  const stroke = el.line ? rgba(el.line.color, el.line.transparency) : 'transparent';
  if (el.shape === 'line') {
    const width = el.line?.width ?? 1;
    const horizontal = el.h === 0;
    return (
      <div
        className="sc-shape"
        style={{
          left: pct(el.x, SLIDE_W),
          top: pct(el.y, SLIDE_H),
          width: horizontal ? pct(el.w, SLIDE_W) : pt(width),
          height: horizontal ? pt(width) : pct(el.h, SLIDE_H),
          transform: horizontal ? 'translateY(-50%)' : 'translateX(-50%)',
          background: stroke,
        }}
      />
    );
  }
  if (el.shape === 'hexagon') {
    const W = el.w * 100;
    const H = el.h * 100;
    const a = Math.min(W, H) * 0.25;
    return (
      <svg className="sc-shape" style={box} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden>
        <polygon
          points={`${a},0 ${W - a},0 ${W},${H / 2} ${W - a},${H} ${a},${H} 0,${H / 2}`}
          fill={el.fill ? rgba(el.fill, el.fillTransparency) : 'none'}
          stroke={stroke}
          style={{ strokeWidth: el.line ? pt(el.line.width) : 0 }}
          vectorEffect="non-scaling-stroke"
        />
      </svg>
    );
  }
  return (
    <div
      className="sc-shape"
      style={{
        ...box,
        background: el.fill ? rgba(el.fill, el.fillTransparency) : 'transparent',
        boxShadow: el.line ? `inset 0 0 0 ${pt(el.line.width)} ${stroke}` : undefined,
        borderRadius: el.shape === 'ellipse' ? '50%' : el.shape === 'roundRect' ? inch(el.radius) : 0,
      }}
    />
  );
}

function Element({ el, urls, showPlaceholders }: { el: SlideElement; urls: Map<string, string | undefined>; showPlaceholders: boolean }) {
  switch (el.kind) {
    case 'shape':
      return <Shape el={el} />;
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
            letterSpacing: el.charSpacing ? pt(el.charSpacing) : undefined,
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
  const index = project.slides.findIndex((s) => s.id === slide.id);
  const total = project.slides.length;
  return useMemo(
    () => renderSlide(slide, getTheme(project.themeId), project.assets, index >= 0 ? { index, total } : undefined),
    [slide, project.themeId, project.assets, index, total],
  );
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
