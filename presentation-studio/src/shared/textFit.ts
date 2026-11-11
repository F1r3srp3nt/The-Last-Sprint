/**
 * Deterministic text-fit estimate shared by the preview and the export.
 *
 * We cannot measure fonts the same way in the browser and in PowerPoint, so
 * both use this estimate to pick one font size. It errs on the side of
 * caution: it assumes slightly wider glyphs and less usable width than a real
 * renderer, so text that "fits" here normally fits in both places.
 */

export interface FitInput {
  paragraphs: string[];
  /** Box size in inches. */
  boxW: number;
  boxH: number;
  /** Preferred and minimum font sizes in points. */
  fontSize: number;
  minFontSize: number;
  widthFactor: number;
  bold?: boolean;
  bullets?: boolean;
  /** Line height as a multiple of the font size. */
  lineHeight?: number;
  /** Space after each paragraph, as a fraction of the font size. */
  paraSpace?: number;
  /** Extra space between characters, in points (letter spacing). */
  charSpacing?: number;
}

export interface FitResult {
  fontSize: number;
  lineCount: number;
  /** True when the text does not fit even at the minimum size. */
  overflow: boolean;
  /** True when the size was reduced from the preferred size. */
  shrunk: boolean;
}

export const LINE_HEIGHT = 1.2;
export const PARA_SPACE = 0.35;
export const BULLET_INDENT_PT = 18;
const WIDTH_SAFETY = 0.92;
const HEIGHT_SAFETY = 0.96;

export function countWrappedLines(text: string, widthPt: number, charPt: number): number {
  const maxChars = Math.max(1, Math.floor(widthPt / charPt));
  const words = text.split(/\s+/).filter(Boolean);
  if (words.length === 0) return 1;
  let lines = 1;
  let current = 0;
  for (const word of words) {
    let len = word.length;
    if (current === 0) {
      // Break words longer than a full line.
      while (len > maxChars) {
        lines += 1;
        len -= maxChars;
      }
      current = len;
    } else if (current + 1 + len <= maxChars) {
      current += 1 + len;
    } else {
      lines += 1;
      while (len > maxChars) {
        lines += 1;
        len -= maxChars;
      }
      current = len;
    }
  }
  return lines;
}

export function measureHeightPt(input: FitInput, size: number): { heightPt: number; lines: number } {
  const lineHeight = input.lineHeight ?? LINE_HEIGHT;
  const paraSpace = input.paraSpace ?? PARA_SPACE;
  const indent = input.bullets ? BULLET_INDENT_PT : 0;
  const widthPt = input.boxW * 72 * WIDTH_SAFETY - indent;
  const charPt = size * input.widthFactor * (input.bold ? 1.07 : 1) + (input.charSpacing ?? 0);
  let lines = 0;
  for (const p of input.paragraphs) lines += countWrappedLines(p, widthPt, charPt);
  const paras = Math.max(0, input.paragraphs.length - 1);
  return { heightPt: lines * size * lineHeight + paras * size * paraSpace, lines };
}

export function fitText(input: FitInput): FitResult {
  const limit = input.boxH * 72 * HEIGHT_SAFETY;
  if (input.paragraphs.length === 0) {
    return { fontSize: input.fontSize, lineCount: 0, overflow: false, shrunk: false };
  }
  for (let size = input.fontSize; size >= input.minFontSize; size -= 1) {
    const { heightPt, lines } = measureHeightPt(input, size);
    if (heightPt <= limit) {
      return { fontSize: size, lineCount: lines, overflow: false, shrunk: size < input.fontSize };
    }
  }
  const { lines } = measureHeightPt(input, input.minFontSize);
  return { fontSize: input.minFontSize, lineCount: lines, overflow: true, shrunk: true };
}

/** Split editor text into paragraphs, dropping blank lines and typed bullet markers. */
export function toParagraphs(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*(?:[-*•–]\s+)/, '').trim())
    .filter((line) => line.length > 0);
}
