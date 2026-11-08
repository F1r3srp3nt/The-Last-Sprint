import type { Slide } from './model';
import { textHash } from './util';

export type NarrationStatus = 'none' | 'no-notes' | 'ready' | 'outdated';

export function narrationStatus(slide: Slide): NarrationStatus {
  if (!slide.narration) return slide.notes.trim() ? 'none' : 'no-notes';
  return slide.narration.notesHash === textHash(slide.notes) ? 'ready' : 'outdated';
}

/** Text sent to the voice provider for a slide: its speaker notes, trimmed. */
export function narrationText(slide: Slide): string {
  return slide.notes.replace(/\s+\n/g, '\n').trim();
}

/** ElevenLabs bills text-to-speech by character, so this is the number we show before asking for confirmation. */
export function narrationCharacters(slides: Slide[]): number {
  return slides.reduce((sum, s) => sum + narrationText(s).length, 0);
}
