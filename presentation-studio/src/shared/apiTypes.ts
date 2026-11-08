/** Request/response shapes shared by the server and the browser client. */
import type { Brief } from './model';
import type { ImageNote, Outline, OutlineSlide, SlideContent } from './generationSchemas';

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    /** What the user can do about it. */
    hint?: string;
    retryable: boolean;
    details?: string[];
  };
}

export interface ProviderStatus {
  generation: {
    provider: 'anthropic' | 'none';
    configured: boolean;
    model: string | null;
    /** null = not checked yet in this server session. */
    verified: boolean | null;
    verifiedAt: string | null;
    lastError: string | null;
  };
  elevenlabs: {
    configured: boolean;
    verified: boolean | null;
    verifiedAt: string | null;
    lastError: string | null;
    ttsModel: string;
    sttModel: string;
    /** Results of the individual checks run by "Verify connection". */
    /** ok: true passed, false failed, null not tested (for example because testing would use credits). */
    checks: { name: string; ok: boolean | null; detail: string }[];
    credits: { used: number; limit: number; resetsAt: string | null; tier: string } | null;
  };
}

export interface GenerationImage {
  id: string;
  name: string;
  caption: string;
  preferredSlide: number | null;
  /** Downscaled copy for the model. The original upload is never modified. */
  mediaType: 'image/jpeg' | 'image/png' | 'image/webp';
  data: string;
}

export interface OutlineRequest {
  brief: Brief;
  images: GenerationImage[];
}
export interface OutlineResponse {
  outline: Outline;
  notices: string[];
  model: string;
}

export interface SlideRequest {
  brief: Brief;
  outline: Outline;
  index: number;
  /** Planned slide (from the outline) or the current slide when regenerating. */
  planned: OutlineSlide;
  images: GenerationImage[];
  imageNotes: ImageNote[];
  /** Present when regenerating an existing slide. */
  current?: SlideContent;
  instruction?: string;
  /** Titles of the other slides, for context when regenerating. */
  deckTitles?: string[];
}
export interface SlideResponse {
  content: SlideContent;
  notices: string[];
  model: string;
}

export interface Voice {
  voiceId: string;
  name: string;
  category: string;
  description: string;
  previewUrl: string | null;
  labels: Record<string, string>;
}

export interface TranscriptResponse {
  text: string;
  languageCode: string | null;
}
