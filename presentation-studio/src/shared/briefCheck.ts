/**
 * Checks run before any paid generation request.
 *
 * The slide-count field and the brief text can disagree ("Make 3 slides" in the brief,
 * 13 in the field). The model then has to guess which one wins. This finds slide counts
 * written in the brief so the user resolves the conflict before anything is sent.
 */
import type { Brief } from './model';

/** Number words per language, matched only together with that language's word for "slides". */
const LANGUAGES: { words: Record<string, number>; slide: string }[] = [
  {
    words: {
      one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12,
      thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19, twenty: 20, thirty: 30,
    },
    slide: '(?:slides?|slide-?deck)',
  },
  {
    words: {
      en: 1, ett: 1, to: 2, tre: 3, fire: 4, fem: 5, seks: 6, sju: 7, syv: 7, åtte: 8, ni: 9, ti: 10, elleve: 11, tolv: 12,
      tretten: 13, fjorten: 14, femten: 15, seksten: 16, sytten: 17, atten: 18, nitten: 19, tjue: 20,
    },
    slide: '(?:lysbilder?|lysark|foiler?)',
  },
  {
    words: {
      jeden: 1, jednego: 1, dwa: 2, dwóch: 2, trzy: 3, trzech: 3, cztery: 4, czterech: 4, pięć: 5, pięciu: 5, sześć: 6,
      sześciu: 6, siedem: 7, osiem: 8, dziewięć: 9, dziesięć: 10,
    },
    slide: '(?:slajd(?:y|ów|a)?)',
  },
];
const ANY_SLIDE = '(?:slides?|slide-?deck|lysbilder?|lysark|foiler?|slajd(?:y|ów|a)?)';

/** "<number> [up to two words] <slide word>", e.g. "3 slides", "a 5-slide deck", "tre korte lysbilder". */
function pattern(number: string, slide: string): RegExp {
  return new RegExp(`(?<![\\p{L}\\d])(${number})(?:\\s*-\\s*|\\s+)(?:[\\p{L}-]+\\s+){0,2}?${slide}(?![\\p{L}])`, 'giu');
}
const PATTERNS: { re: RegExp; words: Record<string, number> | null }[] = [
  { re: pattern('\\d{1,2}', ANY_SLIDE), words: null },
  ...LANGUAGES.map((l) => ({ re: pattern(Object.keys(l.words).sort((a, b) => b.length - a.length).join('|'), l.slide), words: l.words })),
];

export interface SlideCountMention {
  count: number;
  /** The words in the brief, e.g. "3 slides". */
  text: string;
}

/** Slide counts written in the topic or brief, e.g. "three slides", "a 5-slide deck", "3 lysbilder". */
export function slideCountMentions(text: string): SlideCountMention[] {
  const found: (SlideCountMention & { at: number })[] = [];
  for (const { re, words } of PATTERNS) {
    for (const m of text.matchAll(re)) {
      const raw = m[1].toLowerCase();
      const count = words ? words[raw] : Number(raw);
      if (count >= 1 && count <= 30) found.push({ count, text: m[0].trim(), at: m.index ?? 0 });
    }
  }
  return found.sort((a, b) => a.at - b.at).map(({ count, text }) => ({ count, text }));
}

export interface SlideCountConflict {
  field: number;
  /** Distinct counts found in the brief, in order of appearance. */
  mentioned: number[];
  /** The first mention, quoted in the message. */
  example: string;
}

/** A disagreement between the slide-count field and the brief, or null. */
export function slideCountConflict(brief: Pick<Brief, 'topic' | 'brief' | 'slideCount'>): SlideCountConflict | null {
  const mentions = slideCountMentions(`${brief.topic}\n${brief.brief}`);
  const counts = [...new Set(mentions.map((m) => m.count))];
  if (counts.length === 0 || (counts.length === 1 && counts[0] === brief.slideCount)) return null;
  return { field: brief.slideCount, mentioned: counts, example: mentions.find((m) => m.count !== brief.slideCount)?.text ?? mentions[0].text };
}

/** Key that identifies one particular conflict, so "keep the field value" is remembered until something changes. */
export function conflictKey(c: SlideCountConflict): string {
  return `${c.field}:${c.mentioned.join(',')}`;
}

/** Parses the slide-count input while the user is typing; null while it is empty or out of range. */
export function parseSlideCount(raw: string): number | null {
  if (!/^\s*\d{1,2}\s*$/.test(raw)) return null;
  const n = Number(raw);
  return n >= 1 && n <= 30 ? n : null;
}
