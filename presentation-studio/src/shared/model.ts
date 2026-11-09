/**
 * The slide model. The editor preview, the PowerPoint export and the saved
 * project file all read from these types, so there is one source of truth.
 */
import { z } from 'zod';

export const LAYOUT_IDS = [
  'title',
  'bullets',
  'cards',
  'process',
  'textImage',
  'imageCaption',
  'fullImage',
  'comparison',
  'takeaway',
  'closing',
] as const;
export type LayoutId = (typeof LAYOUT_IDS)[number];

export const LAYOUT_LABELS: Record<LayoutId, string> = {
  title: 'Title',
  bullets: 'Key points (text only)',
  cards: 'Feature cards',
  process: 'Workflow / steps',
  imageCaption: 'Image with caption',
  textImage: 'Text + image',
  fullImage: 'Full image',
  comparison: 'Comparison',
  takeaway: 'Key takeaway',
  closing: 'Closing',
};

export const THEME_IDS = ['clean-light', 'executive-dark', 'futuristic-cyan'] as const;
export type ThemeId = (typeof THEME_IDS)[number];

/** Where a slide's content came from. Shown in the UI so template output is never mistaken for AI output. */
export const ORIGINS = ['ai', 'template', 'manual'] as const;
export type SlideOrigin = (typeof ORIGINS)[number];

export const ImagePlacementSchema = z.object({
  assetId: z.string().min(1),
  /** fit = whole image visible inside the frame; fill = image covers the frame and is cropped. */
  mode: z.enum(['fit', 'fill']),
  /** 1 = no extra zoom. Only used in fill mode. */
  zoom: z.number().min(1).max(3),
  /** Crop focus point (0..1) in the source image. Only used in fill mode. */
  focusX: z.number().min(0).max(1),
  focusY: z.number().min(0).max(1),
});
export type ImagePlacement = z.infer<typeof ImagePlacementSchema>;

export const NarrationRefSchema = z.object({
  audioId: z.string().min(1),
  /** Hash of the speaker notes the audio was generated from; differs => outdated. */
  notesHash: z.string(),
  voiceId: z.string(),
  voiceName: z.string(),
  modelId: z.string(),
  characters: z.number().int().nonnegative(),
  createdAt: z.string(),
  mime: z.string(),
});
export type NarrationRef = z.infer<typeof NarrationRefSchema>;

export const SlideSchema = z.object({
  id: z.string().min(1),
  layout: z.enum(LAYOUT_IDS),
  /** Short eyebrow label above the title (e.g. a section name). Optional; added after version 1 files, so it defaults to "". */
  kicker: z.string().default(''),
  title: z.string(),
  /**
   * Bullets or paragraph text. One paragraph per line. Also the subtitle on title slides.
   * Cards and workflow slides use one item per line, written "Label — detail".
   */
  body: z.string(),
  caption: z.string(),
  leftHeading: z.string(),
  leftBody: z.string(),
  rightHeading: z.string(),
  rightBody: z.string(),
  image: ImagePlacementSchema.nullable(),
  notes: z.string(),
  origin: z.enum(ORIGINS),
  /** Missing information the generator flagged instead of inventing it. */
  flags: z.array(z.string()),
  narration: NarrationRefSchema.nullable(),
});
export type Slide = z.infer<typeof SlideSchema>;

export const AssetSchema = z.object({
  id: z.string().min(1),
  name: z.string(),
  mime: z.enum(['image/png', 'image/jpeg', 'image/webp']),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
  bytes: z.number().int().nonnegative(),
  caption: z.string(),
  /** 1-based slide number the user wants this image on, or null to let the generator decide. */
  preferredSlide: z.number().int().positive().nullable(),
});
export type Asset = z.infer<typeof AssetSchema>;

export const BriefSchema = z.object({
  topic: z.string(),
  brief: z.string(),
  audience: z.string(),
  language: z.string(),
  slideCount: z.number().int().min(1).max(30),
  tone: z.string(),
  includeNotes: z.boolean(),
});
export type Brief = z.infer<typeof BriefSchema>;

/**
 * What an AI run has already produced, so a retry continues instead of paying for the whole deck again.
 * `outline` is validated with OutlineSchema (generationSchemas.ts) when it is used.
 */
export const GenerationResumeSchema = z.object({
  /** Fingerprint of the brief and images the outline was planned from. */
  briefKey: z.string(),
  outline: z.unknown(),
  /** Slide id for each outline entry, in outline order. */
  slideIds: z.array(z.string()),
  /** Slide ids whose content has not been written yet (pending or failed). */
  pending: z.array(z.string()),
});
export type GenerationResume = z.infer<typeof GenerationResumeSchema>;

export const GenerationInfoSchema = z.object({
  mode: z.enum(['ai', 'template', 'manual']),
  provider: z.string().nullable(),
  model: z.string().nullable(),
  generatedAt: z.string().nullable(),
  missingInfo: z.array(z.string()),
  /** Added after version 1 files; absent means nothing to resume. */
  resume: GenerationResumeSchema.nullable().default(null),
});
export type GenerationInfo = z.infer<typeof GenerationInfoSchema>;

export const NarrationSettingsSchema = z.object({
  voiceId: z.string().nullable(),
  voiceName: z.string().nullable(),
  modelId: z.string().nullable(),
});
export type NarrationSettings = z.infer<typeof NarrationSettingsSchema>;

export const PROJECT_FORMAT = 'presentation-studio-project';
export const PROJECT_VERSION = 1;

export const ProjectSchema = z.object({
  format: z.literal(PROJECT_FORMAT),
  version: z.literal(PROJECT_VERSION),
  title: z.string(),
  themeId: z.enum(THEME_IDS),
  brief: BriefSchema,
  assets: z.array(AssetSchema),
  slides: z.array(SlideSchema),
  generation: GenerationInfoSchema,
  narration: NarrationSettingsSchema,
});
export type Project = z.infer<typeof ProjectSchema>;

/** Binary files (original image uploads and narration audio), keyed by id. Kept outside the JSON model. */
export type BinaryStore = Map<string, Blob>;

export function emptyBrief(): Brief {
  return {
    topic: '',
    brief: '',
    audience: '',
    language: 'English',
    slideCount: 6,
    tone: 'Clear and confident',
    includeNotes: true,
  };
}

export function emptyProject(): Project {
  return {
    format: PROJECT_FORMAT,
    version: PROJECT_VERSION,
    title: 'Untitled presentation',
    themeId: 'futuristic-cyan',
    brief: emptyBrief(),
    assets: [],
    slides: [],
    generation: { mode: 'manual', provider: null, model: null, generatedAt: null, missingInfo: [], resume: null },
    narration: { voiceId: null, voiceName: null, modelId: null },
  };
}

export function newSlide(id: string, layout: LayoutId, origin: SlideOrigin, partial: Partial<Slide> = {}): Slide {
  return {
    id,
    layout,
    kicker: '',
    title: '',
    body: '',
    caption: '',
    leftHeading: '',
    leftBody: '',
    rightHeading: '',
    rightBody: '',
    image: null,
    notes: '',
    origin,
    flags: [],
    narration: null,
    ...partial,
  };
}

export function defaultPlacement(assetId: string, layout: LayoutId): ImagePlacement {
  return { assetId, mode: layout === 'fullImage' ? 'fill' : 'fit', zoom: 1, focusX: 0.5, focusY: 0.5 };
}

/** Layouts that have an image frame. */
export const IMAGE_LAYOUTS: ReadonlySet<LayoutId> = new Set(['title', 'imageCaption', 'textImage', 'fullImage']);
/** Layouts that cannot work without an image. */
export const IMAGE_REQUIRED_LAYOUTS: ReadonlySet<LayoutId> = new Set(['imageCaption', 'fullImage']);
/** Layouts whose content is the title plus the body lines, so one can switch between them without losing text. */
export const BODY_LAYOUTS: ReadonlySet<LayoutId> = new Set(['bullets', 'cards', 'process', 'textImage', 'closing']);
