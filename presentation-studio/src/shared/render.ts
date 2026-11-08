/**
 * Turns a Slide into positioned elements. The React preview and the PptxGenJS
 * export both draw exactly these elements, so they share every measurement.
 * Units: inches for positions, points for font sizes.
 */
import type { Asset, Slide } from './model';
import type { DeckTheme, FontSpec } from './themes';
import { computeImageGeometry, type ImageGeometry, type Rect } from './imageGeometry';
import { fitText, toParagraphs, LINE_HEIGHT, PARA_SPACE } from './textFit';

export const SLIDE_W = 13.333;
export const SLIDE_H = 7.5;
/** Points across the slide width (13.333 in x 72). Used by the preview to scale fonts. */
export const SLIDE_W_PT = SLIDE_W * 72;

export type TextRole =
  | 'title'
  | 'body'
  | 'caption'
  | 'leftHeading'
  | 'leftBody'
  | 'rightHeading'
  | 'rightBody';

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
  overflow: boolean;
  shrunk: boolean;
}

export interface RectElement extends Rect {
  kind: 'rect';
  id: string;
  color: string;
  /** 0 = opaque, 100 = invisible (PptxGenJS convention). */
  transparency: number;
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

export type SlideElement = TextElement | RectElement | ImageElement | PlaceholderElement;

export interface SlideWarning {
  level: 'info' | 'warning';
  message: string;
}

export interface RenderedSlide {
  background: string;
  elements: SlideElement[];
  warnings: SlideWarning[];
}

interface TextSpec extends Rect {
  role: TextRole;
  text: string;
  size: number;
  min: number;
  font: 'heading' | 'body';
  color: string;
  bold?: boolean;
  italic?: boolean;
  align?: TextElement['align'];
  valign?: TextElement['valign'];
  bullets?: boolean;
}

const ROLE_LABEL: Record<TextRole, string> = {
  title: 'Title',
  body: 'Body',
  caption: 'Caption',
  leftHeading: 'Left heading',
  leftBody: 'Left text',
  rightHeading: 'Right heading',
  rightBody: 'Right text',
};

export function renderSlide(slide: Slide, theme: DeckTheme, assets: Asset[]): RenderedSlide {
  const elements: SlideElement[] = [];
  const warnings: SlideWarning[] = [];
  let background = theme.background;
  const asset = slide.image ? assets.find((a) => a.id === slide.image!.assetId) ?? null : null;
  if (slide.image && !asset) {
    warnings.push({ level: 'warning', message: 'The selected image is no longer in the project.' });
  }

  const addText = (spec: TextSpec) => {
    const paragraphs = spec.role === 'title' ? [spec.text.replace(/\s*\n\s*/g, ' ').trim()].filter(Boolean) : toParagraphs(spec.text);
    if (paragraphs.length === 0) return;
    const font = spec.font === 'heading' ? theme.headingFont : theme.bodyFont;
    const bullets = Boolean(spec.bullets) && paragraphs.length > 1;
    const fit = fitText({
      paragraphs,
      boxW: spec.w,
      boxH: spec.h,
      fontSize: spec.size,
      minFontSize: spec.min,
      widthFactor: font.widthFactor,
      bold: spec.bold,
      bullets,
    });
    if (fit.overflow) {
      warnings.push({
        level: 'warning',
        message: `${ROLE_LABEL[spec.role]}: too much text. It does not fit even at ${spec.min} pt — shorten it or split the slide.`,
      });
    } else if (fit.fontSize <= Math.round(spec.size * 0.75)) {
      warnings.push({
        level: 'info',
        message: `${ROLE_LABEL[spec.role]}: dense text, reduced from ${spec.size} pt to ${fit.fontSize} pt to fit.`,
      });
    }
    elements.push({
      kind: 'text',
      id: `${slide.id}-${spec.role}`,
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
      overflow: fit.overflow,
      shrunk: fit.shrunk,
    });
  };

  const addRect = (id: string, r: Rect, color: string, transparency = 0) => {
    elements.push({ kind: 'rect', id: `${slide.id}-${id}`, ...r, color, transparency });
  };

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

  const header = () => {
    addText({ role: 'title', text: slide.title, x: 0.6, y: 0.4, w: 12.133, h: 1.0, size: 30, min: 20, font: 'heading', color: theme.title, bold: true, valign: 'bottom' });
    addRect('rule', { x: 0.6, y: 1.48, w: 1.2, h: 0.06 }, theme.accent);
  };

  switch (slide.layout) {
    case 'title': {
      const hasImage = Boolean(slide.image);
      const textW = hasImage ? 5.9 : 11.0;
      const left = hasImage ? 0.8 : 1.2;
      if (hasImage) addImage({ x: 7.1, y: 0, w: SLIDE_W - 7.1, h: SLIDE_H });
      addText({ role: 'title', text: slide.title, x: left, y: 1.7, w: textW, h: 2.2, size: hasImage ? 40 : 44, min: 24, font: 'heading', color: theme.title, bold: true, valign: 'bottom' });
      addRect('rule', { x: left, y: 4.05, w: 1.6, h: 0.08 }, theme.accent);
      addText({ role: 'body', text: slide.body, x: left, y: 4.3, w: textW, h: 1.7, size: 22, min: 14, font: 'body', color: theme.muted });
      break;
    }
    case 'imageCaption': {
      header();
      addImage({ x: 0.6, y: 1.75, w: 12.133, h: 4.35 });
      addText({ role: 'caption', text: slide.caption, x: 0.6, y: 6.25, w: 12.133, h: 0.85, size: 16, min: 11, font: 'body', color: theme.muted, italic: true, align: 'center' });
      break;
    }
    case 'textImage': {
      header();
      addText({ role: 'body', text: slide.body, x: 0.6, y: 1.8, w: 5.9, h: 5.1, size: 20, min: 12, font: 'body', color: theme.text, bullets: true });
      addImage({ x: 6.85, y: 1.8, w: 5.883, h: 5.1 });
      break;
    }
    case 'fullImage': {
      background = '000000';
      addImage({ x: 0, y: 0, w: SLIDE_W, h: SLIDE_H });
      if (slide.title.trim() || slide.caption.trim()) {
        addRect('band', { x: 0, y: 5.6, w: SLIDE_W, h: 1.9 }, '000000', 40);
        addText({ role: 'title', text: slide.title, x: 0.6, y: 5.72, w: 12.133, h: 0.9, size: 30, min: 18, font: 'heading', color: 'FFFFFF', bold: true, valign: 'middle' });
        addText({ role: 'caption', text: slide.caption, x: 0.6, y: 6.62, w: 12.133, h: 0.7, size: 16, min: 11, font: 'body', color: 'E5E7EB' });
      }
      break;
    }
    case 'comparison': {
      header();
      const colW = 5.9;
      const rightX = SLIDE_W - 0.6 - colW;
      addRect('left-panel', { x: 0.6, y: 1.8, w: colW, h: 5.1 }, theme.surface);
      addRect('right-panel', { x: rightX, y: 1.8, w: colW, h: 5.1 }, theme.surface);
      addText({ role: 'leftHeading', text: slide.leftHeading, x: 0.85, y: 1.95, w: colW - 0.5, h: 0.7, size: 22, min: 14, font: 'heading', color: theme.accent, bold: true, valign: 'middle' });
      addText({ role: 'leftBody', text: slide.leftBody, x: 0.85, y: 2.75, w: colW - 0.5, h: 3.95, size: 18, min: 11, font: 'body', color: theme.text, bullets: true });
      addText({ role: 'rightHeading', text: slide.rightHeading, x: rightX + 0.25, y: 1.95, w: colW - 0.5, h: 0.7, size: 22, min: 14, font: 'heading', color: theme.accent, bold: true, valign: 'middle' });
      addText({ role: 'rightBody', text: slide.rightBody, x: rightX + 0.25, y: 2.75, w: colW - 0.5, h: 3.95, size: 18, min: 11, font: 'body', color: theme.text, bullets: true });
      break;
    }
    case 'takeaway': {
      addRect('bar', { x: 1.0, y: 1.9, w: 0.14, h: 3.9 }, theme.accent);
      addText({ role: 'title', text: slide.title, x: 1.5, y: 1.8, w: 10.8, h: 2.5, size: 38, min: 22, font: 'heading', color: theme.title, bold: true, valign: 'middle' });
      addText({ role: 'body', text: slide.body, x: 1.5, y: 4.4, w: 10.8, h: 1.5, size: 20, min: 13, font: 'body', color: theme.muted });
      break;
    }
    case 'closing': {
      addText({ role: 'title', text: slide.title, x: 1.2, y: 2.1, w: 10.933, h: 1.7, size: 44, min: 24, font: 'heading', color: theme.title, bold: true, align: 'center', valign: 'bottom' });
      addRect('rule', { x: (SLIDE_W - 1.6) / 2, y: 3.95, w: 1.6, h: 0.08 }, theme.accent);
      addText({ role: 'body', text: slide.body, x: 1.2, y: 4.25, w: 10.933, h: 1.9, size: 20, min: 13, font: 'body', color: theme.muted, align: 'center' });
      break;
    }
  }

  if (!slide.title.trim() && slide.layout !== 'fullImage') {
    warnings.push({ level: 'info', message: 'This slide has no title.' });
  }
  return { background, elements, warnings };
}

/** Fields the editor shows for each layout. */
export const LAYOUT_FIELDS: Record<Slide['layout'], { field: keyof Slide; label: string; multiline: boolean }[]> = {
  title: [
    { field: 'title', label: 'Title', multiline: false },
    { field: 'body', label: 'Subtitle', multiline: true },
  ],
  imageCaption: [
    { field: 'title', label: 'Title', multiline: false },
    { field: 'caption', label: 'Caption', multiline: true },
  ],
  textImage: [
    { field: 'title', label: 'Title', multiline: false },
    { field: 'body', label: 'Body (one bullet per line)', multiline: true },
  ],
  fullImage: [
    { field: 'title', label: 'Title (optional overlay)', multiline: false },
    { field: 'caption', label: 'Caption (optional overlay)', multiline: true },
  ],
  comparison: [
    { field: 'title', label: 'Title', multiline: false },
    { field: 'leftHeading', label: 'Left heading', multiline: false },
    { field: 'leftBody', label: 'Left points (one per line)', multiline: true },
    { field: 'rightHeading', label: 'Right heading', multiline: false },
    { field: 'rightBody', label: 'Right points (one per line)', multiline: true },
  ],
  takeaway: [
    { field: 'title', label: 'Key takeaway', multiline: false },
    { field: 'body', label: 'Supporting line', multiline: true },
  ],
  closing: [
    { field: 'title', label: 'Closing title', multiline: false },
    { field: 'body', label: 'Closing text', multiline: true },
  ],
};
