/**
 * Turns a Slide into positioned elements. The React preview and the PptxGenJS
 * export both draw exactly these elements, so they share every measurement.
 * Units: inches for positions, points for font sizes.
 *
 * Every piece of text is a separate, editable text element; graphics are
 * native shapes (rectangles, rounded rectangles, ellipses, hexagons, lines).
 * Nothing is rasterised and no image is generated: decoration is geometry.
 */
import type { Asset, Slide } from './model';
import type { DeckTheme, FontSpec } from './themes';
import { computeImageGeometry, type ImageGeometry, type Rect } from './imageGeometry';
import { fitText, toParagraphs, LINE_HEIGHT, PARA_SPACE } from './textFit';
import { parseItems, type SlideItem } from './items';
import { pad2, uniqueMessages } from './util';

export const SLIDE_W = 13.333;
export const SLIDE_H = 7.5;
/** Points across the slide width (13.333 in x 72). Used by the preview to scale fonts. */
export const SLIDE_W_PT = SLIDE_W * 72;

/** Side margin and content width shared by all compositions. */
const M = 0.75;
const CW = SLIDE_W - 2 * M;

export type TextRole =
  | 'kicker'
  | 'title'
  | 'body'
  | 'caption'
  | 'leftHeading'
  | 'leftBody'
  | 'rightHeading'
  | 'rightBody'
  | 'itemLabel'
  | 'itemDetail'
  | 'number'
  | 'footer';

export interface TextElement extends Rect {
  kind: 'text';
  id: string;
  role: TextRole;
  paragraphs: string[];
  bullets: boolean;
  font: FontSpec;
  fontSize: number;
  color: string;
  bold: boolean;
  italic: boolean;
  align: 'left' | 'center' | 'right';
  valign: 'top' | 'middle' | 'bottom';
  lineHeight: number;
  /** Space after each paragraph, in points. */
  paraSpacePt: number;
  /** Letter spacing in points (0 = normal). */
  charSpacing: number;
  overflow: boolean;
  shrunk: boolean;
}

export type ShapeKind = 'rect' | 'roundRect' | 'ellipse' | 'hexagon' | 'line';

export interface ShapeElement extends Rect {
  kind: 'shape';
  id: string;
  shape: ShapeKind;
  /** Fill colour, or null for an outline-only shape. Ignored for lines. */
  fill: string | null;
  /** 0 = opaque, 100 = invisible (PptxGenJS convention). */
  fillTransparency: number;
  /** Outline (or the line itself), or null for none. Width in points. */
  line: { color: string; width: number; transparency: number } | null;
  /** Corner radius in inches (roundRect only). */
  radius: number;
}

export interface ImageElement {
  kind: 'image';
  id: string;
  assetId: string;
  mode: 'fit' | 'fill';
  geometry: ImageGeometry;
  altText: string;
}

/** Shown in the editor preview only, never exported. */
export interface PlaceholderElement extends Rect {
  kind: 'imagePlaceholder';
  id: string;
}

export type SlideElement = TextElement | ShapeElement | ImageElement | PlaceholderElement;

export interface SlideWarning {
  level: 'info' | 'warning';
  message: string;
}

export interface RenderedSlide {
  background: string;
  elements: SlideElement[];
  warnings: SlideWarning[];
}

/** Position of the slide in the deck; used for the page marker of themes that show one. */
export interface RenderContext {
  index: number;
  total: number;
}

interface TextSpec extends Rect {
  role: TextRole;
  /** Unique part of the element id; defaults to the role. */
  key?: string;
  /** Name used in warnings; defaults to the role's label. */
  label?: string;
  text: string;
  size: number;
  min: number;
  font: 'heading' | 'body' | 'label';
  color: string;
  bold?: boolean;
  italic?: boolean;
  align?: TextElement['align'];
  valign?: TextElement['valign'];
  bullets?: boolean;
  upper?: boolean;
  spacing?: number;
}

const ROLE_LABEL: Record<TextRole, string> = {
  kicker: 'Eyebrow label',
  title: 'Title',
  body: 'Body',
  caption: 'Caption',
  leftHeading: 'Left heading',
  leftBody: 'Left text',
  rightHeading: 'Right heading',
  rightBody: 'Right text',
  itemLabel: 'Item',
  itemDetail: 'Item text',
  number: 'Number',
  footer: 'Footer',
};

export function renderSlide(slide: Slide, theme: DeckTheme, assets: Asset[], ctx?: RenderContext): RenderedSlide {
  const elements: SlideElement[] = [];
  const warnings: SlideWarning[] = [];
  let background = theme.background;
  const style = theme.style;
  const asset = slide.image ? assets.find((a) => a.id === slide.image!.assetId) ?? null : null;
  if (slide.image && !asset) {
    warnings.push({ level: 'warning', message: 'The selected image is no longer in the project.' });
  }
  const kicker = (slide.kicker ?? '').trim();

  // ---- primitives --------------------------------------------------------------------------
  /** Adds a text box; returns the height its text actually uses (inches), or 0 when empty. */
  const addText = (spec: TextSpec): number => {
    const raw = spec.upper ? spec.text.toLocaleUpperCase() : spec.text;
    const paragraphs = spec.role === 'title' || spec.role === 'kicker' ? [raw.replace(/\s*\n\s*/g, ' ').trim()].filter(Boolean) : toParagraphs(raw);
    if (paragraphs.length === 0) return 0;
    const font = spec.font === 'heading' ? theme.headingFont : spec.font === 'label' ? theme.labelFont : theme.bodyFont;
    const bullets = Boolean(spec.bullets) && paragraphs.length > 1;
    const charSpacing = spec.spacing ?? 0;
    const fit = fitText({
      paragraphs,
      boxW: spec.w,
      boxH: spec.h,
      fontSize: spec.size,
      minFontSize: spec.min,
      widthFactor: font.widthFactor,
      bold: spec.bold,
      bullets,
      charSpacing,
    });
    const name = spec.label ?? ROLE_LABEL[spec.role];
    if (fit.overflow) {
      warnings.push({ level: 'warning', message: `${name}: too much text. It does not fit even at ${spec.min} pt — shorten it or split the slide.` });
    } else if (fit.fontSize <= Math.round(spec.size * 0.75)) {
      warnings.push({ level: 'info', message: `${name}: dense text, reduced from ${spec.size} pt to ${fit.fontSize} pt to fit.` });
    }
    elements.push({
      kind: 'text',
      id: `${slide.id}-${spec.key ?? spec.role}`,
      role: spec.role,
      x: spec.x,
      y: spec.y,
      w: spec.w,
      h: spec.h,
      paragraphs,
      bullets,
      font,
      fontSize: fit.fontSize,
      color: spec.color,
      bold: Boolean(spec.bold),
      italic: Boolean(spec.italic),
      align: spec.align ?? 'left',
      valign: spec.valign ?? 'top',
      lineHeight: LINE_HEIGHT,
      paraSpacePt: Math.round(fit.fontSize * PARA_SPACE * 10) / 10,
      charSpacing,
      overflow: fit.overflow,
      shrunk: fit.shrunk,
    });
    return Math.min(spec.h, (fit.lineCount * fit.fontSize * LINE_HEIGHT + (paragraphs.length - 1) * fit.fontSize * PARA_SPACE) / 72);
  };
  /** Eyebrow label placed just above a bottom-aligned title that ends at `bottom` and uses `used` inches. */
  const kickerAbove = (x: number, w: number, bottom: number, used: number, align: TextElement['align'] = 'left') => {
    if (!kicker) return;
    addText({ role: 'kicker', text: kicker, x, y: bottom - used - 0.5, w, h: 0.36, size: 13, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking, align });
  };

  let shapeNo = 0;
  const shape = (s: ShapeKind, r: Rect, o: { fill?: string | null; fillT?: number; line?: string | null; lineW?: number; lineT?: number; radius?: number } = {}) => {
    elements.push({
      kind: 'shape',
      id: `${slide.id}-g${shapeNo++}`,
      shape: s,
      ...r,
      fill: s === 'line' ? null : o.fill ?? null,
      fillTransparency: o.fillT ?? 0,
      line: o.line ? { color: o.line, width: o.lineW ?? 1, transparency: o.lineT ?? 0 } : null,
      radius: o.radius ?? 0,
    });
  };
  const rect = (r: Rect, color: string, t = 0) => shape('rect', r, { fill: color, fillT: t });
  const hline = (x: number, y: number, w: number, color: string, width = 0.75, t = 0) => shape('line', { x, y, w, h: 0 }, { line: color, lineW: width, lineT: t });
  const vline = (x: number, y: number, h: number, color: string, width = 0.75, t = 0) => shape('line', { x, y, w: 0, h }, { line: color, lineW: width, lineT: t });
  const card = (r: Rect) =>
    shape(theme.radius > 0 ? 'roundRect' : 'rect', r, { fill: theme.cardFill, line: theme.cardLine, lineW: 0.75, radius: theme.radius });

  const addImage = (frame: Rect) => {
    if (slide.image && asset) {
      elements.push({
        kind: 'image',
        id: `${slide.id}-image`,
        assetId: asset.id,
        mode: slide.image.mode,
        geometry: computeImageGeometry(frame, asset, slide.image),
        altText: asset.caption || asset.name,
      });
    } else {
      elements.push({ kind: 'imagePlaceholder', id: `${slide.id}-placeholder`, ...frame });
    }
  };

  // ---- theme decoration ----------------------------------------------------------------------
  /** Thin corner brackets, a dot grid and the page marker of the tech style. */
  const techFrame = (opts: { dots?: boolean } = {}) => {
    const L = 0.26;
    const o = 0.28;
    // top-left and bottom-right brackets
    hline(o, o, L, theme.accent, 1.25);
    vline(o, o, L, theme.accent, 1.25);
    hline(SLIDE_W - o - L, SLIDE_H - o, L, theme.accent, 1.25);
    vline(SLIDE_W - o, SLIDE_H - o - L, L, theme.accent, 1.25);
    if (opts.dots !== false) {
      for (let r = 0; r < 3; r++) for (let c = 0; c < 6; c++) shape('ellipse', { x: SLIDE_W - 2.05 + c * 0.22, y: 0.42 + r * 0.22, w: 0.05, h: 0.05 }, { fill: theme.line });
    }
  };
  const executiveFrame = () => shape('rect', { x: 0.3, y: 0.3, w: SLIDE_W - 0.6, h: SLIDE_H - 0.6 }, { line: theme.line, lineW: 0.75 });

  const footer = () => {
    if (!ctx || style !== 'tech') return;
    hline(M, 6.98, CW, theme.line, 0.75);
    rect({ x: M, y: 6.96, w: 0.45, h: 0.045 }, theme.accent);
    addText({ role: 'footer', text: `${pad2(ctx.index + 1)} / ${pad2(ctx.total)}`, x: SLIDE_W - M - 2.2, y: 7.03, w: 2.2, h: 0.3, size: 10, min: 8, font: 'label', color: theme.muted, align: 'right', spacing: 1.5 });
  };

  // ---- shared header -------------------------------------------------------------------------
  /** Eyebrow + title + theme rule. Returns the top of the content area. */
  const header = (align: 'left' | 'center' = 'left'): number => {
    const center = align === 'center';
    if (kicker) {
      addText({ role: 'kicker', text: kicker, x: M, y: 0.5, w: CW, h: 0.34, size: 12, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking, align });
    }
    const titleY = kicker ? 0.84 : 0.55;
    addText({ role: 'title', text: slide.title, x: M, y: titleY, w: CW, h: kicker ? 0.92 : 1.1, size: 32, min: 20, font: 'heading', color: theme.title, bold: true, valign: 'bottom', align });
    const ruleY = 1.9;
    if (style === 'tech') {
      hline(M, ruleY, CW, theme.line, 0.75);
      rect({ x: M, y: ruleY - 0.025, w: 0.9, h: 0.05 }, theme.accent);
      shape('rect', { x: M + 0.96, y: ruleY - 0.04, w: 0.08, h: 0.08 }, { fill: theme.accent });
    } else if (style === 'executive') {
      hline(center ? (SLIDE_W - 3) / 2 : M, ruleY, center ? 3 : CW, theme.accent, 0.75);
    } else {
      rect({ x: center ? (SLIDE_W - 1.1) / 2 : M, y: ruleY - 0.035, w: 1.1, h: 0.07 }, theme.accent);
    }
    return 2.2;
  };

  // ---- reusable compositions ----------------------------------------------------------------
  /** Text-only list: numbered rows for 2–5 items, a bullet list otherwise. */
  const textList = (body: string, area: Rect, opts: { numbered?: boolean; center?: boolean } = {}) => {
    const items = parseItems(body);
    const numbered = (opts.numbered ?? true) && items.length >= 2 && items.length <= 5;
    if (!numbered) {
      addText({ role: 'body', text: body, ...area, size: 22, min: 12, font: 'body', color: theme.text, bullets: true });
      return;
    }
    const gap = 0.2;
    const hasDetail = items.some((it) => it.detail);
    const rowH = Math.min((area.h - gap * (items.length - 1)) / items.length, hasDetail ? 1.25 : 0.8);
    const block = rowH * items.length + gap * (items.length - 1);
    const y0 = opts.center ? area.y + (area.h - block) / 2 : area.y;
    items.forEach((it, i) => {
      const y = y0 + i * (rowH + gap);
      const numW = 0.9;
      if (style === 'clean') {
        const d = Math.min(0.62, rowH - 0.1);
        shape('ellipse', { x: area.x, y: y + 0.05, w: d, h: d }, { fill: theme.accent });
        addText({ role: 'number', key: `num-${i}`, text: String(i + 1), x: area.x, y: y + 0.05, w: d, h: d, size: 18, min: 10, font: 'label', color: theme.onAccent, bold: true, align: 'center', valign: 'middle' });
      } else {
        addText({ role: 'number', key: `num-${i}`, text: pad2(i + 1), x: area.x, y, w: numW, h: it.detail ? Math.min(0.6, rowH) : rowH, size: style === 'tech' ? 24 : 26, min: 12, font: style === 'tech' ? 'label' : 'heading', color: theme.accent, bold: true, valign: it.detail ? 'top' : 'middle' });
      }
      if (style === 'tech' && i < items.length - 1) hline(area.x + numW, y + rowH + gap / 2, area.w - numW, theme.line, 0.5);
      const tx = area.x + numW + 0.15;
      const tw = area.w - numW - 0.15;
      if (it.detail) {
        const lh = Math.min(0.55, rowH * 0.42);
        addText({ role: 'itemLabel', key: `label-${i}`, label: `Point ${i + 1}`, text: it.label, x: tx, y, w: tw, h: lh, size: 22, min: 13, font: 'heading', color: theme.title, bold: true, valign: 'top' });
        addText({ role: 'itemDetail', key: `detail-${i}`, label: `Point ${i + 1} text`, text: it.detail, x: tx, y: y + lh, w: tw, h: rowH - lh, size: 17, min: 11, font: 'body', color: theme.text });
      } else {
        addText({ role: 'itemLabel', key: `label-${i}`, label: `Point ${i + 1}`, text: it.label, x: tx, y, w: tw, h: rowH, size: 22, min: 12, font: 'body', color: theme.text, valign: 'middle' });
      }
    });
  };

  const cards = (items: SlideItem[], area: Rect) => {
    const n = items.length;
    const cols = n <= 3 ? n : n === 4 ? 2 : 3;
    const rows = Math.ceil(n / cols);
    const gap = 0.3;
    const cw = (area.w - gap * (cols - 1)) / cols;
    const ch = (area.h - gap * (rows - 1)) / rows;
    items.forEach((it, i) => {
      const x = area.x + (i % cols) * (cw + gap);
      const y = area.y + Math.floor(i / cols) * (ch + gap);
      card({ x, y, w: cw, h: ch });
      const ix = x + 0.3;
      const iw = cw - 0.6;
      let top = y + 0.28;
      if (style === 'tech') {
        addText({ role: 'number', key: `num-${i}`, text: pad2(i + 1), x: ix, y: top, w: 1.2, h: 0.36, size: 14, min: 10, font: 'label', color: theme.accent, bold: true, spacing: 1.5 });
        hline(ix, top + 0.42, 0.55, theme.accent, 1.5);
        shape('hexagon', { x: x + cw - 0.62, y: y + 0.24, w: 0.36, h: 0.32 }, { line: theme.accent, lineW: 0.75, lineT: 30 });
        top += 0.6;
      } else if (style === 'executive') {
        hline(x, y, cw, theme.accent, 1.5);
        addText({ role: 'number', key: `num-${i}`, text: pad2(i + 1), x: ix, y: top, w: 1.2, h: 0.42, size: 18, min: 11, font: 'heading', color: theme.accent, italic: true });
        top += 0.55;
      } else {
        const d = 0.48;
        shape('ellipse', { x: ix, y: top, w: d, h: d }, { fill: theme.accent });
        addText({ role: 'number', key: `num-${i}`, text: String(i + 1), x: ix, y: top, w: d, h: d, size: 15, min: 10, font: 'label', color: theme.onAccent, bold: true, align: 'center', valign: 'middle' });
        top += 0.68;
      }
      const remaining = y + ch - 0.25 - top;
      if (it.detail) {
        const lh = Math.min(0.8, remaining * 0.38);
        addText({ role: 'itemLabel', key: `label-${i}`, label: `Card ${i + 1} title`, text: it.label, x: ix, y: top, w: iw, h: lh, size: 20, min: 12, font: 'heading', color: theme.title, bold: true });
        addText({ role: 'itemDetail', key: `detail-${i}`, label: `Card ${i + 1} text`, text: it.detail, x: ix, y: top + lh + 0.05, w: iw, h: remaining - lh - 0.05, size: 15, min: 10, font: 'body', color: theme.text });
      } else {
        addText({ role: 'itemLabel', key: `label-${i}`, label: `Card ${i + 1}`, text: it.label, x: ix, y: top, w: iw, h: remaining, size: 20, min: 11, font: 'heading', color: theme.title, bold: true });
      }
    });
  };

  const workflow = (items: SlideItem[], area: Rect) => {
    const n = items.length;
    const colW = area.w / n;
    const node = n >= 6 ? 0.78 : n === 5 ? 0.95 : 1.15;
    const big = n <= 4;
    const blockH = node + 0.25 + 0.6 + 1.5;
    const cy = area.y + Math.max(0, (area.h - blockH) / 2 - 0.15);
    items.forEach((it, i) => {
      const cx = area.x + colW * i + colW / 2;
      const nx = cx - node / 2;
      // connector to the next node
      if (i < n - 1) {
        const x1 = cx + node / 2 + 0.08;
        const x2 = cx + colW - node / 2 - 0.08;
        if (style === 'tech') {
          hline(x1, cy + node / 2, x2 - x1, theme.accent, 1, 35);
          shape('ellipse', { x: x2 - 0.09, y: cy + node / 2 - 0.045, w: 0.09, h: 0.09 }, { fill: theme.accent });
        } else {
          hline(x1, cy + node / 2, x2 - x1, style === 'executive' ? theme.accent : theme.line, 1.25);
        }
      }
      if (style === 'tech') {
        shape('hexagon', { x: nx, y: cy, w: node, h: node * 0.88 }, { fill: theme.cardFill, line: theme.accent, lineW: 1.25 });
        addText({ role: 'number', key: `num-${i}`, text: pad2(i + 1), x: nx, y: cy, w: node, h: node * 0.88, size: big ? 22 : 18, min: 10, font: 'label', color: theme.accent, bold: true, align: 'center', valign: 'middle' });
      } else if (style === 'executive') {
        shape('ellipse', { x: nx, y: cy, w: node, h: node }, { line: theme.accent, lineW: 1.25 });
        addText({ role: 'number', key: `num-${i}`, text: String(i + 1), x: nx, y: cy, w: node, h: node, size: 22, min: 11, font: 'heading', color: theme.accent, align: 'center', valign: 'middle' });
      } else {
        shape('ellipse', { x: nx, y: cy, w: node, h: node }, { fill: theme.accent });
        addText({ role: 'number', key: `num-${i}`, text: String(i + 1), x: nx, y: cy, w: node, h: node, size: 22, min: 11, font: 'label', color: theme.onAccent, bold: true, align: 'center', valign: 'middle' });
      }
      const tw = colW - 0.25;
      const tx = cx - tw / 2;
      const labelY = cy + node + 0.25;
      addText({ role: 'itemLabel', key: `label-${i}`, label: `Step ${i + 1} title`, text: it.label, x: tx, y: labelY, w: tw, h: 0.6, size: big ? 22 : n === 5 ? 19 : 17, min: 11, font: 'heading', color: theme.title, bold: true, align: 'center', valign: 'bottom' });
      if (it.detail) {
        addText({ role: 'itemDetail', key: `detail-${i}`, label: `Step ${i + 1} text`, text: it.detail, x: tx, y: labelY + 0.68, w: tw, h: area.y + area.h - labelY - 0.68, size: big ? 17 : n === 5 ? 15 : 13, min: 9, font: 'body', color: theme.text, align: 'center' });
      }
    });
  };

  /** Restrained geometry for otherwise empty areas of text-only slides. */
  const motif = (r: Rect) => {
    if (style === 'tech') {
      const s = Math.min(r.w, r.h);
      const cx = r.x + r.w / 2;
      const cy = r.y + r.h / 2;
      shape('hexagon', { x: cx - s / 2, y: cy - (s * 0.88) / 2, w: s, h: s * 0.88 }, { line: theme.line, lineW: 0.75 });
      shape('hexagon', { x: cx - s * 0.33, y: cy - s * 0.29, w: s * 0.66, h: s * 0.58 }, { line: theme.accent, lineW: 1, lineT: 45 });
      shape('hexagon', { x: cx - s * 0.12, y: cy - s * 0.105, w: s * 0.24, h: s * 0.21 }, { fill: theme.accent, fillT: 20 });
      hline(cx + s * 0.12, cy, s * 0.6, theme.accent, 0.75, 40);
    } else if (style === 'executive') {
      vline(r.x + r.w / 2, r.y, r.h, theme.accent, 0.75);
    } else {
      const s = Math.min(r.w, r.h);
      shape('ellipse', { x: r.x + r.w - s, y: r.y, w: s, h: s }, { fill: theme.accentSoft });
      shape('ellipse', { x: r.x + r.w - s * 1.15, y: r.y + s * 0.55, w: s * 0.45, h: s * 0.45 }, { fill: theme.accent, fillT: 70 });
    }
  };

  // ---- layouts -------------------------------------------------------------------------------
  const layout = slide.layout === 'textImage' && !slide.image ? 'bullets' : slide.layout;
  if (slide.layout === 'textImage' && !slide.image && toParagraphs(slide.body).length) {
    warnings.push({ level: 'info', message: 'No image chosen: shown as a text slide.' });
  }

  switch (layout) {
    case 'title': {
      const hasImage = Boolean(slide.image);
      if (style === 'tech') techFrame({ dots: !hasImage });
      if (style === 'executive') executiveFrame();
      if (hasImage) {
        addImage({ x: 7.1, y: 0, w: SLIDE_W - 7.1, h: SLIDE_H });
        if (style === 'tech') vline(7.1, 0, SLIDE_H, theme.accent, 1.5);
      } else if (style === 'tech') {
        // concentric outline geometry on the right
        const cx = 10.45;
        const cy = 3.75;
        for (const [d, color, t] of [[4.9, theme.line, 0], [3.5, theme.accent, 55], [2.1, theme.line, 0]] as const) {
          shape('ellipse', { x: cx - d / 2, y: cy - d / 2, w: d, h: d }, { line: color, lineW: 0.75, lineT: t });
        }
        shape('hexagon', { x: cx - 0.55, y: cy - 0.48, w: 1.1, h: 0.96 }, { fill: theme.accent, fillT: 15 });
        hline(cx + 0.55, cy, SLIDE_W - cx - 0.55, theme.accent, 0.75, 40);
      } else if (style === 'clean') {
        rect({ x: 0, y: 0, w: 0.32, h: SLIDE_H }, theme.accent);
        shape('ellipse', { x: 8.9, y: -1.4, w: 6.2, h: 6.2 }, { fill: theme.accentSoft });
        shape('ellipse', { x: 10.6, y: 4.3, w: 2.6, h: 2.6 }, { fill: theme.accent, fillT: 80 });
      }
      if (style === 'executive' && !hasImage) {
        if (kicker) addText({ role: 'kicker', text: kicker, x: 1.5, y: 1.55, w: SLIDE_W - 3, h: 0.36, size: 13, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking, align: 'center' });
        hline((SLIDE_W - 2.4) / 2, 2.1, 2.4, theme.accent, 0.75);
        addText({ role: 'title', text: slide.title, x: 1.3, y: 2.25, w: SLIDE_W - 2.6, h: 2.0, size: 46, min: 24, font: 'heading', color: theme.title, bold: true, align: 'center', valign: 'middle' });
        hline((SLIDE_W - 2.4) / 2, 4.4, 2.4, theme.accent, 0.75);
        addText({ role: 'body', text: slide.body, x: 1.5, y: 4.6, w: SLIDE_W - 3, h: 1.5, size: 22, min: 13, font: 'body', color: theme.muted, align: 'center' });
        break;
      }
      const left = style === 'clean' ? 1.1 : 0.9;
      const textW = hasImage ? 7.1 - left - 0.45 : style === 'tech' ? 6.85 : 7.6;
      const used = addText({ role: 'title', text: slide.title, x: left, y: 1.95, w: textW, h: 2.25, size: hasImage ? 42 : 48, min: 24, font: 'heading', color: theme.title, bold: true, valign: 'bottom' });
      kickerAbove(left, textW, 4.2, used);
      if (style === 'tech') {
        rect({ x: left, y: 4.35, w: 1.2, h: 0.06 }, theme.accent);
        if (hasImage) hline(left + 1.25, 4.38, textW - 1.25, theme.line, 0.75);
      } else {
        rect({ x: left, y: 4.33, w: 1.4, h: 0.08 }, theme.accent);
      }
      addText({ role: 'body', text: slide.body, x: left, y: 4.6, w: textW, h: 1.7, size: 22, min: 13, font: 'body', color: theme.muted });
      break;
    }
    case 'bullets': {
      if (style === 'executive') executiveFrame();
      const top = header();
      const listW = style === 'executive' ? CW : 8.4;
      textList(slide.body, { x: M, y: top + 0.1, w: listW, h: 6.7 - top - 0.1 });
      if (style !== 'executive') motif({ x: M + listW + 0.6, y: top + 0.5, w: CW - listW - 0.6, h: 3.4 });
      break;
    }
    case 'cards': {
      if (style === 'executive') executiveFrame();
      const top = header();
      const items = parseItems(slide.body);
      if (items.length === 0) break;
      if (items.length > 6) {
        warnings.push({ level: 'warning', message: `Feature cards: ${items.length} cards is more than fits (6). Shown as a list; split the slide or shorten it.` });
        addText({ role: 'body', text: slide.body, x: M, y: top, w: CW, h: 6.75 - top, size: 20, min: 11, font: 'body', color: theme.text, bullets: true });
        break;
      }
      cards(items, { x: M, y: top + 0.05, w: CW, h: 6.75 - top - 0.05 });
      break;
    }
    case 'process': {
      if (style === 'executive') executiveFrame();
      const top = header();
      const items = parseItems(slide.body);
      if (items.length === 0) break;
      if (items.length > 6) {
        warnings.push({ level: 'warning', message: `Workflow: ${items.length} steps is more than fits (6). Shown as a list; split the slide or merge steps.` });
        addText({ role: 'body', text: slide.body, x: M, y: top, w: CW, h: 6.75 - top, size: 20, min: 11, font: 'body', color: theme.text, bullets: true });
        break;
      }
      workflow(items, { x: M, y: top + 0.2, w: CW, h: 6.75 - top - 0.2 });
      break;
    }
    case 'textImage': {
      const top = header();
      addText({ role: 'body', text: slide.body, x: M, y: top, w: 5.75, h: 6.75 - top, size: 20, min: 12, font: 'body', color: theme.text, bullets: true });
      const frame = { x: 6.85, y: top, w: SLIDE_W - M - 6.85, h: 6.75 - top };
      addImage(frame);
      if (style === 'tech') {
        hline(frame.x - 0.18, frame.y, 0.4, theme.accent, 1.25);
        vline(frame.x - 0.18, frame.y, 0.4, theme.accent, 1.25);
      }
      break;
    }
    case 'imageCaption': {
      const top = header();
      addImage({ x: M, y: top, w: CW, h: 6.2 - top });
      addText({ role: 'caption', text: slide.caption, x: M, y: 6.3, w: CW, h: 0.6, size: 16, min: 11, font: 'body', color: theme.muted, italic: style !== 'tech', align: style === 'tech' ? 'left' : 'center' });
      break;
    }
    case 'fullImage': {
      background = '000000';
      addImage({ x: 0, y: 0, w: SLIDE_W, h: SLIDE_H });
      if (slide.title.trim() || slide.caption.trim()) {
        rect({ x: 0, y: 5.6, w: SLIDE_W, h: 1.9 }, '000000', 40);
        if (style === 'tech') rect({ x: M, y: 5.6, w: 0.9, h: 0.05 }, theme.accent);
        addText({ role: 'title', text: slide.title, x: M, y: 5.72, w: CW, h: 0.9, size: 30, min: 18, font: 'heading', color: 'FFFFFF', bold: true, valign: 'middle' });
        addText({ role: 'caption', text: slide.caption, x: M, y: 6.62, w: CW, h: 0.7, size: 16, min: 11, font: 'body', color: 'E5E7EB' });
      }
      break;
    }
    case 'comparison': {
      if (style === 'executive') executiveFrame();
      const top = header();
      const gap = 0.45;
      const colW = (CW - gap) / 2;
      const rightX = M + colW + gap;
      const h = 6.75 - top;
      for (const [x, headingRole, bodyRole, heading, body] of [
        [M, 'leftHeading', 'leftBody', slide.leftHeading, slide.leftBody],
        [rightX, 'rightHeading', 'rightBody', slide.rightHeading, slide.rightBody],
      ] as const) {
        card({ x, y: top, w: colW, h });
        if (style === 'tech') rect({ x: x + 0.3, y: top, w: 0.8, h: 0.05 }, theme.accent);
        if (style === 'executive') hline(x, top, colW, theme.accent, 1.5);
        addText({ role: headingRole, text: heading, x: x + 0.3, y: top + 0.2, w: colW - 0.6, h: 0.75, size: 22, min: 14, font: 'heading', color: theme.accent, bold: true, valign: 'middle' });
        addText({ role: bodyRole, text: body, x: x + 0.3, y: top + 1.05, w: colW - 0.6, h: h - 1.25, size: 18, min: 11, font: 'body', color: theme.text, bullets: true });
      }
      if (style === 'tech') shape('hexagon', { x: M + colW + gap / 2 - 0.2, y: top + h / 2 - 0.18, w: 0.4, h: 0.36 }, { fill: theme.background, line: theme.accent, lineW: 1 });
      break;
    }
    case 'takeaway': {
      if (style === 'tech') {
        techFrame({ dots: false });
        // square brackets around the statement
        const bx1 = 1.0;
        const bx2 = SLIDE_W - 1.0;
        for (const [x, dir] of [[bx1, 1], [bx2, -1]] as const) {
          vline(x, 1.7, 3.0, theme.accent, 1.5);
          hline(dir > 0 ? x : x - 0.35, 1.7, 0.35, theme.accent, 1.5);
          hline(dir > 0 ? x : x - 0.35, 4.7, 0.35, theme.accent, 1.5);
        }
        if (kicker) addText({ role: 'kicker', text: kicker, x: 1.5, y: 1.15, w: 10.3, h: 0.36, size: 13, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking });
        addText({ role: 'title', text: slide.title, x: 1.5, y: 1.8, w: 10.3, h: 2.8, size: 40, min: 22, font: 'heading', color: theme.title, bold: true, valign: 'middle' });
        addText({ role: 'body', text: slide.body, x: 1.5, y: 5.0, w: 10.3, h: 1.4, size: 20, min: 13, font: 'body', color: theme.muted });
      } else if (style === 'executive') {
        executiveFrame();
        if (kicker) addText({ role: 'kicker', text: kicker, x: 1.5, y: 1.3, w: SLIDE_W - 3, h: 0.36, size: 13, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking, align: 'center' });
        hline((SLIDE_W - 1.6) / 2, 1.85, 1.6, theme.accent, 0.75);
        addText({ role: 'title', text: slide.title, x: 1.4, y: 2.0, w: SLIDE_W - 2.8, h: 2.6, size: 40, min: 22, font: 'heading', color: theme.title, bold: true, italic: true, align: 'center', valign: 'middle' });
        hline((SLIDE_W - 1.6) / 2, 4.75, 1.6, theme.accent, 0.75);
        addText({ role: 'body', text: slide.body, x: 1.5, y: 4.95, w: SLIDE_W - 3, h: 1.4, size: 20, min: 13, font: 'body', color: theme.muted, align: 'center' });
      } else {
        shape('roundRect', { x: 0.75, y: 1.4, w: SLIDE_W - 1.5, h: 4.7 }, { fill: theme.surface, radius: 0.2 });
        rect({ x: 0.75, y: 1.4, w: 0.16, h: 4.7 }, theme.accent);
        if (kicker) addText({ role: 'kicker', text: kicker, x: 1.5, y: 1.75, w: 10.3, h: 0.36, size: 13, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking });
        addText({ role: 'title', text: slide.title, x: 1.5, y: 2.1, w: 10.3, h: 2.4, size: 38, min: 22, font: 'heading', color: theme.title, bold: true, valign: 'middle' });
        addText({ role: 'body', text: slide.body, x: 1.5, y: 4.55, w: 10.3, h: 1.35, size: 20, min: 13, font: 'body', color: theme.muted });
      }
      break;
    }
    case 'closing': {
      const lines = toParagraphs(slide.body);
      const withSteps = lines.length >= 2;
      if (style === 'tech') techFrame({ dots: !withSteps });
      if (style === 'executive') executiveFrame();
      if (withSteps) {
        // Title on the left, the next steps as a numbered list on the right.
        if (style === 'clean') rect({ x: 0, y: 0, w: 0.32, h: SLIDE_H }, theme.accent);
        const used = addText({ role: 'title', text: slide.title, x: 0.95, y: 1.85, w: 4.8, h: 2.3, size: 40, min: 22, font: 'heading', color: theme.title, bold: true, valign: 'bottom' });
        kickerAbove(0.95, 4.8, 4.15, used);
        if (style === 'tech') {
          rect({ x: 0.95, y: 4.35, w: 1.0, h: 0.05 }, theme.accent);
          vline(6.25, 1.3, 4.9, theme.line, 0.75);
        } else {
          rect({ x: 0.95, y: 4.33, w: 1.2, h: 0.07 }, theme.accent);
        }
        textList(slide.body, { x: 6.75, y: 1.3, w: SLIDE_W - 6.75 - M, h: 4.9 }, { numbered: true, center: true });
        break;
      }
      if (style === 'tech') {
        const cx = SLIDE_W / 2;
        for (const [d, color, t] of [[4.6, theme.line, 0], [3.2, theme.accent, 60]] as const) {
          shape('ellipse', { x: cx - d / 2, y: 3.0 - d / 2, w: d, h: d }, { line: color, lineW: 0.75, lineT: t });
        }
      } else if (style === 'clean') {
        shape('ellipse', { x: -1.6, y: 4.2, w: 4.6, h: 4.6 }, { fill: theme.accentSoft });
        shape('ellipse', { x: SLIDE_W - 2.4, y: -1.1, w: 3.6, h: 3.6 }, { fill: theme.accentSoft });
      }
      if (kicker) addText({ role: 'kicker', text: kicker, x: 1.2, y: 1.7, w: SLIDE_W - 2.4, h: 0.36, size: 13, min: 9, font: 'label', color: theme.accent, bold: true, upper: true, spacing: theme.labelTracking, align: 'center' });
      addText({ role: 'title', text: slide.title, x: 1.2, y: 2.1, w: SLIDE_W - 2.4, h: 1.75, size: 48, min: 24, font: 'heading', color: theme.title, bold: true, align: 'center', valign: 'bottom' });
      rect({ x: (SLIDE_W - 1.4) / 2, y: 4.0, w: 1.4, h: style === 'executive' ? 0.03 : 0.07 }, theme.accent);
      addText({ role: 'body', text: slide.body, x: 1.2, y: 4.3, w: SLIDE_W - 2.4, h: 1.7, size: 22, min: 13, font: 'body', color: theme.muted, align: 'center' });
      break;
    }
  }

  if (layout !== 'title' && layout !== 'fullImage' && layout !== 'takeaway' && layout !== 'closing') {
    if (style === 'tech') techFrame({ dots: false });
  }
  if (layout !== 'fullImage') footer();

  if (!slide.title.trim() && slide.layout !== 'fullImage') {
    warnings.push({ level: 'info', message: 'This slide has no title.' });
  }
  if ((layout === 'cards' || layout === 'process') && parseItems(slide.body).length === 0) {
    warnings.push({ level: 'info', message: `Add one ${layout === 'cards' ? 'card' : 'step'} per line, written "Label — detail".` });
  }
  const unique = uniqueMessages(warnings.map((w) => w.message));
  return { background, elements, warnings: unique.map((m) => warnings.find((w) => w.message === m)!) };
}

/** Fields the editor shows for each layout. */
const KICKER = { field: 'kicker' as const, label: 'Eyebrow label (optional, short)', multiline: false };
export const LAYOUT_FIELDS: Record<Slide['layout'], { field: keyof Slide; label: string; multiline: boolean }[]> = {
  title: [KICKER, { field: 'title', label: 'Title', multiline: false }, { field: 'body', label: 'Subtitle', multiline: true }],
  bullets: [KICKER, { field: 'title', label: 'Title', multiline: false }, { field: 'body', label: 'Points (one per line; "Label — detail" for numbered rows)', multiline: true }],
  cards: [KICKER, { field: 'title', label: 'Title', multiline: false }, { field: 'body', label: 'Cards (one per line: "Label — detail", 2–6 cards)', multiline: true }],
  process: [KICKER, { field: 'title', label: 'Title', multiline: false }, { field: 'body', label: 'Steps in order (one per line: "Label — detail", 2–6 steps)', multiline: true }],
  imageCaption: [KICKER, { field: 'title', label: 'Title', multiline: false }, { field: 'caption', label: 'Caption', multiline: true }],
  textImage: [KICKER, { field: 'title', label: 'Title', multiline: false }, { field: 'body', label: 'Body (one bullet per line)', multiline: true }],
  fullImage: [
    { field: 'title', label: 'Title (optional overlay)', multiline: false },
    { field: 'caption', label: 'Caption (optional overlay)', multiline: true },
  ],
  comparison: [
    KICKER,
    { field: 'title', label: 'Title', multiline: false },
    { field: 'leftHeading', label: 'Left heading', multiline: false },
    { field: 'leftBody', label: 'Left points (one per line)', multiline: true },
    { field: 'rightHeading', label: 'Right heading', multiline: false },
    { field: 'rightBody', label: 'Right points (one per line)', multiline: true },
  ],
  takeaway: [KICKER, { field: 'title', label: 'Key takeaway', multiline: false }, { field: 'body', label: 'Supporting line', multiline: true }],
  closing: [KICKER, { field: 'title', label: 'Closing title', multiline: false }, { field: 'body', label: 'Closing text (two or more lines become numbered next steps)', multiline: true }],
};
