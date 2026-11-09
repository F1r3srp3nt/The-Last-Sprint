/**
 * Resuming AI generation: the outline and the list of unwritten slides are stored in the
 * project, so a retry, a reload or a reopened project continues instead of regenerating
 * (and paying for) the whole deck.
 */
import { OutlineSchema, type Outline } from './generationSchemas';
import type { Project } from './model';
import { textHash } from './util';

/** Fingerprint of everything the outline was planned from. A changed brief or image set needs a new outline. */
export function briefKey(p: Pick<Project, 'brief' | 'assets'>): string {
  return textHash(JSON.stringify({ b: p.brief, a: p.assets.map((a) => [a.id, a.caption, a.preferredSlide]) }));
}

export interface ResumeInfo {
  outline: Outline;
  /** Outline entries whose slide still exists, with their position in the outline. */
  entries: { slideId: string; index: number; pending: boolean }[];
  pendingCount: number;
}

/** What a previous AI run left to do for this exact brief, or null when nothing can be resumed. */
export function resumeInfo(p: Project): ResumeInfo | null {
  const r = p.generation.resume;
  if (!r || r.briefKey !== briefKey(p)) return null;
  const parsed = OutlineSchema.safeParse(r.outline);
  if (!parsed.success || parsed.data.slides.length !== r.slideIds.length) return null;
  const existing = new Set(p.slides.map((s) => s.id));
  const pending = new Set(r.pending);
  const entries = r.slideIds.map((slideId, index) => ({ slideId, index, pending: pending.has(slideId) })).filter((e) => existing.has(e.slideId));
  return { outline: parsed.data, entries, pendingCount: entries.filter((e) => e.pending).length };
}

