/**
 * Cards and workflow slides store one item per line in the slide body, written
 * "Label — detail". These helpers split such lines; the text itself is never
 * changed, so it stays editable as plain text.
 */
import { toParagraphs } from './textFit';

export interface SlideItem {
  label: string;
  detail: string;
}

/** Separators people and models use between a short label and its detail. */
const SEPARATORS = [' — ', ' – ', ' - ', ' -- '];

export function parseItem(line: string): SlideItem {
  for (const sep of SEPARATORS) {
    const i = line.indexOf(sep);
    if (i > 0) return { label: line.slice(0, i).trim(), detail: line.slice(i + sep.length).trim() };
  }
  // "Label: detail" when the label is short and the colon is not part of a time or URL.
  const m = /^([^:]{1,48}):\s+(.+)$/.exec(line);
  if (m && !/\d$/.test(m[1]) && !/^https?$/i.test(m[1].trim())) return { label: m[1].trim(), detail: m[2].trim() };
  return { label: line.trim(), detail: '' };
}

export function parseItems(body: string): SlideItem[] {
  return toParagraphs(body).map(parseItem);
}

/** True when most lines have a "label — detail" shape (used to choose cards or a workflow automatically). */
export function looksLikeItems(body: string): boolean {
  const items = parseItems(body);
  if (items.length < 2 || items.length > 6) return false;
  const structured = items.filter((it) => it.detail && it.label.length <= 48).length;
  return structured >= Math.ceil(items.length * 0.6);
}

/** Titles that announce a sequence ("How it works", "Four steps", "Roadmap", ...). */
const SEQUENCE_TITLE = /\b(steps?|process|workflow|how it works|timeline|roadmap|phases?|stages?|journey|sequence|prosess|steg|fremgangsmåte|tidslinje|etapy|kroki|proces)\b/i;

/** True when the lines read as a sequence: numbered, using step words, or under a title that announces steps. */
export function looksSequential(body: string, title = ''): boolean {
  const lines = toParagraphs(body);
  if (lines.length < 2) return false;
  if (SEQUENCE_TITLE.test(title)) return true;
  const numbered = lines.filter((l) => /^(\d+[.)]|step\s*\d+|phase\s*\d+|steg\s*\d+|krok\s*\d+)/i.test(l)).length;
  if (numbered >= Math.ceil(lines.length / 2)) return true;
  const stepWords = /\b(first|then|next|after|finally|start|launch|pilot|review|deploy|plan|build|test|measure|først|deretter|til slutt|najpierw|następnie|na koniec)\b/i;
  return lines.filter((l) => stepWords.test(l)).length >= Math.ceil(lines.length * 0.6);
}
