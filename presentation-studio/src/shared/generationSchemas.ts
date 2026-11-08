/**
 * Shapes the generation model must return. The server asks the model for these
 * via structured outputs and validates them; the browser validates them again
 * before rendering. Every field is required (empty string / empty array when
 * unused) so the shapes stay compatible with structured outputs.
 */
import { z } from 'zod';
import { IMAGE_LAYOUTS, LAYOUT_IDS } from './model';

export const OutlineSlideSchema = z.object({
  layout: z.enum(LAYOUT_IDS),
  title: z.string(),
  purpose: z.string(),
  keyPoints: z.array(z.string()),
  imageIds: z.array(z.string()),
});

export const ImageNoteSchema = z.object({
  imageId: z.string(),
  description: z.string(),
  /** Text the model could read inside the image, quoted as source material. */
  visibleText: z.string(),
});

export const OutlineSchema = z.object({
  title: z.string(),
  slides: z.array(OutlineSlideSchema),
  imageNotes: z.array(ImageNoteSchema),
  missingInfo: z.array(z.string()),
});
export type Outline = z.infer<typeof OutlineSchema>;
export type OutlineSlide = z.infer<typeof OutlineSlideSchema>;
export type ImageNote = z.infer<typeof ImageNoteSchema>;

export const SlideContentSchema = z.object({
  layout: z.enum(LAYOUT_IDS),
  title: z.string(),
  body: z.string(),
  caption: z.string(),
  leftHeading: z.string(),
  leftBody: z.string(),
  rightHeading: z.string(),
  rightBody: z.string(),
  /** Id of the image to show, or "" for none. */
  imageId: z.string(),
  notes: z.string(),
  flags: z.array(z.string()),
});
export type SlideContent = z.infer<typeof SlideContentSchema>;

export interface ValidationResult<T> {
  ok: boolean;
  value: T | null;
  errors: string[];
  notices: string[];
}

/** Checks references and counts the schema cannot express. Repairs what is safe to repair and reports it. */
export function validateOutline(
  raw: unknown,
  opts: { slideCount: number; assetIds: string[]; /** imageId -> 1-based slide the user pinned it to */ preferred?: Record<string, number> },
): ValidationResult<Outline> {
  const parsed = OutlineSchema.safeParse(raw);
  if (!parsed.success) {
    return { ok: false, value: null, errors: parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`), notices: [] };
  }
  const outline = parsed.data;
  const notices: string[] = [];
  const errors: string[] = [];
  if (outline.slides.length === 0) errors.push('The outline has no slides.');
  if (outline.slides.length > 30) errors.push('The outline has more than 30 slides.');
  if (outline.slides.length !== opts.slideCount && outline.slides.length > 0) {
    notices.push(`You asked for ${opts.slideCount} slides; the outline has ${outline.slides.length}.`);
  }
  const known = new Set(opts.assetIds);
  for (const s of outline.slides) {
    const unknown = s.imageIds.filter((id) => !known.has(id));
    if (unknown.length) {
      notices.push(`Removed unknown image references from "${s.title}".`);
      s.imageIds = s.imageIds.filter((id) => known.has(id));
    }
  }
  outline.imageNotes = outline.imageNotes.filter((n) => known.has(n.imageId));
  // The user's own placements win over the model's suggestions.
  for (const [imageId, slideNo] of Object.entries(opts.preferred ?? {})) {
    const target = outline.slides[slideNo - 1];
    if (!known.has(imageId) || !target) continue;
    if (target.imageIds[0] === imageId && IMAGE_LAYOUTS.has(target.layout)) continue;
    for (const s of outline.slides) s.imageIds = s.imageIds.filter((id) => id !== imageId);
    target.imageIds = [imageId, ...target.imageIds];
    if (!IMAGE_LAYOUTS.has(target.layout)) target.layout = 'textImage';
    notices.push(`Placed an image on slide ${slideNo} as you requested.`);
  }
  return { ok: errors.length === 0, value: errors.length ? null : outline, errors, notices };
}

export function validateSlideContent(raw: unknown, opts: { assetIds: string[] }): ValidationResult<SlideContent> {
  const parsed = SlideContentSchema.safeParse(raw);
  if (!parsed.success) {
    return { ok: false, value: null, errors: parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`), notices: [] };
  }
  const content = parsed.data;
  const notices: string[] = [];
  if (content.imageId && !opts.assetIds.includes(content.imageId)) {
    notices.push('Removed a reference to an unknown image.');
    content.imageId = '';
  }
  return { ok: true, value: content, errors: [], notices };
}
