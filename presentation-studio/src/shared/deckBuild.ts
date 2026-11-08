/**
 * Builds slides from either generated content (AI mode) or the brief alone
 * (template mode). Template mode never writes new content: it only arranges
 * the user's own text and images, and every slide is labelled "template".
 */
import { defaultPlacement, IMAGE_LAYOUTS, newSlide, type Asset, type Brief, type LayoutId, type Slide } from './model';
import type { OutlineSlide, SlideContent } from './generationSchemas';
import { toParagraphs } from './textFit';

export function slideFromContent(content: SlideContent, id: string, previous?: Slide): Slide {
  const image = content.imageId && IMAGE_LAYOUTS.has(content.layout)
    ? previous?.image && previous.image.assetId === content.imageId
      ? previous.image
      : defaultPlacement(content.imageId, content.layout)
    : null;
  return newSlide(id, content.layout, 'ai', {
    title: content.title,
    body: content.body,
    caption: content.caption,
    leftHeading: content.leftHeading,
    leftBody: content.leftBody,
    rightHeading: content.rightHeading,
    rightBody: content.rightBody,
    image,
    notes: content.notes,
    flags: content.flags,
    narration: null,
  });
}

/** Placeholder slide shown while a slide is still being written, or after it failed. */
export function slideFromOutline(entry: OutlineSlide, id: string): Slide {
  const imageId = entry.imageIds[0];
  return newSlide(id, entry.layout, 'ai', {
    title: entry.title,
    body: entry.keyPoints.join('\n'),
    image: imageId && IMAGE_LAYOUTS.has(entry.layout) ? defaultPlacement(imageId, entry.layout) : null,
  });
}

/** Split the brief into the user's own points: lines if there are several, otherwise sentences. */
export function briefPoints(brief: string): string[] {
  const lines = toParagraphs(brief);
  if (lines.length > 1) return lines;
  if (lines.length === 0) return [];
  return lines[0]
    .split(/(?<=[.!?])\s+(?=[A-ZÆØÅÄÖÜ0-9"“])/)
    .map((s) => s.trim())
    .filter(Boolean);
}

const TEMPLATE_FLAG = 'Template mode: arranged from your brief without AI. Review and complete this slide.';

export function buildTemplateDeck(brief: Brief, assets: Asset[], makeId: () => string): Slide[] {
  const total = Math.max(1, brief.slideCount);
  const points = briefPoints(brief.brief);
  const slides: Slide[] = [];

  slides.push(
    newSlide(makeId(), 'title', 'template', {
      title: brief.topic.trim() || 'Untitled presentation',
      body: brief.audience.trim() ? `For ${brief.audience.trim()}` : '',
    }),
  );
  if (total === 1) return attachPreferredImages(slides, assets);

  const middleCount = total >= 3 ? total - 2 : total - 1;
  // Images the user pinned to a slide go there; the rest are spread over the middle slides in order.
  const pinned = new Map<number, Asset>();
  const free: Asset[] = [];
  for (const a of assets) {
    if (a.preferredSlide && a.preferredSlide <= total && !pinned.has(a.preferredSlide)) pinned.set(a.preferredSlide, a);
    else free.push(a);
  }
  for (let i = 0; i < middleCount; i++) {
    const slideNo = i + 2;
    // Spread the points evenly so no slide is left empty while others are full.
    const chunk = points.slice(Math.round((i * points.length) / middleCount), Math.round(((i + 1) * points.length) / middleCount));
    const asset = pinned.get(slideNo) ?? (pinned.size + free.length > 0 ? free.shift() : undefined);
    let layout: LayoutId;
    if (asset && chunk.length > 0) layout = 'textImage';
    else if (asset) layout = 'imageCaption';
    else layout = 'textImage';
    const [first, ...rest] = chunk;
    slides.push(
      newSlide(makeId(), layout, 'template', {
        title: first ?? '',
        body: rest.join('\n'),
        caption: asset?.caption ?? '',
        image: asset ? defaultPlacement(asset.id, layout) : null,
        flags: chunk.length === 0 && !asset ? ['Template mode: no content was provided for this slide.'] : [TEMPLATE_FLAG],
      }),
    );
  }
  if (total >= 3) {
    slides.push(newSlide(makeId(), 'closing', 'template', { title: 'Thank you', body: 'Questions?' }));
  }
  return slides;
}

function attachPreferredImages(slides: Slide[], assets: Asset[]): Slide[] {
  const a = assets.find((x) => x.preferredSlide === 1) ?? assets[0];
  if (a) slides[0].image = defaultPlacement(a.id, 'title');
  return slides;
}
