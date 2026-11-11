/**
 * "Restyle existing deck": picks a better-suited layout for each slide from its own content,
 * without any AI call. Only layouts that use the same fields (title + body) are swapped, so
 * no text is hidden or lost; speaker notes, images and narration are never touched.
 */
import { BODY_LAYOUTS, LAYOUT_LABELS, type LayoutId, type Slide } from './model';
import { looksLikeItems, looksSequential, parseItems } from './items';
import { toParagraphs } from './textFit';

export interface RestyleChange {
  slideId: string;
  index: number;
  from: LayoutId;
  to: LayoutId;
  reason: string;
}

/** The layout this slide's content suggests, or its current layout. */
export function suggestLayout(slide: Slide): { layout: LayoutId; reason: string } {
  const keep = { layout: slide.layout, reason: '' };
  if (!BODY_LAYOUTS.has(slide.layout)) return keep; // title, comparison, takeaway, image layouts: content-specific
  if (slide.layout === 'closing') return keep;
  if (slide.layout === 'textImage' && slide.image) return keep;
  const lines = toParagraphs(slide.body);
  if (lines.length === 0) return keep;
  if (looksLikeItems(slide.body)) {
    if (looksSequential(slide.body, slide.title)) return { layout: 'process', reason: 'its points read as steps in order' };
    if (lines.length >= 3) return { layout: 'cards', reason: 'its points are parallel "label — detail" items' };
  }
  if ((slide.layout === 'cards' || slide.layout === 'process') && (lines.length < 2 || parseItems(slide.body).length > 6)) {
    return { layout: 'bullets', reason: 'it does not have 2–6 items' };
  }
  if (slide.layout === 'textImage') return { layout: 'bullets', reason: 'it has no image' };
  return keep;
}

export function planRestyle(slides: readonly Slide[]): RestyleChange[] {
  const changes: RestyleChange[] = [];
  slides.forEach((s, index) => {
    const { layout, reason } = suggestLayout(s);
    if (layout !== s.layout) changes.push({ slideId: s.id, index, from: s.layout, to: layout, reason });
  });
  return changes;
}

/** Applies the layout changes; every other field of every slide is kept as it is. */
export function applyRestyle(slides: readonly Slide[], changes: readonly RestyleChange[]): Slide[] {
  const to = new Map(changes.map((c) => [c.slideId, c.to]));
  return slides.map((s) => (to.has(s.id) ? { ...s, layout: to.get(s.id)! } : s));
}

export function describeChange(c: RestyleChange): string {
  return `Slide ${c.index + 1}: ${LAYOUT_LABELS[c.from]} → ${LAYOUT_LABELS[c.to]} (${c.reason})`;
}
