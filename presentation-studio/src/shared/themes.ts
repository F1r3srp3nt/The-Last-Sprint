/**
 * Deck themes. These style the slides only; the app interface has its own
 * palette in src/client/styles/app.css. Colours are hex without '#', the form
 * PptxGenJS expects.
 */
import type { ThemeId } from './model';

export interface FontSpec {
  /** Font name written into the .pptx. */
  pptx: string;
  /** CSS font stack for the preview; starts with the same font. */
  css: string;
  /** Average glyph width as a fraction of the font size, used by the text-fit estimate. */
  widthFactor: number;
}

export interface DeckTheme {
  id: ThemeId;
  name: string;
  description: string;
  background: string;
  surface: string;
  title: string;
  text: string;
  muted: string;
  accent: string;
  accentSoft: string;
  /** Text colour on top of the accent colour. */
  onAccent: string;
  headingFont: FontSpec;
  bodyFont: FontSpec;
}

const ARIAL: FontSpec = { pptx: 'Arial', css: 'Arial, "Liberation Sans", Helvetica, sans-serif', widthFactor: 0.52 };
const GEORGIA: FontSpec = { pptx: 'Georgia', css: 'Georgia, "DejaVu Serif", "Times New Roman", serif', widthFactor: 0.55 };
const TREBUCHET: FontSpec = {
  pptx: 'Trebuchet MS',
  css: '"Trebuchet MS", "DejaVu Sans", Arial, sans-serif',
  widthFactor: 0.54,
};

export const THEMES: Record<ThemeId, DeckTheme> = {
  'clean-light': {
    id: 'clean-light',
    name: 'Clean light',
    description: 'White background, navy text, blue accent.',
    background: 'FFFFFF',
    surface: 'F1F5F9',
    title: '0F172A',
    text: '334155',
    muted: '64748B',
    accent: '2563EB',
    accentSoft: 'DBEAFE',
    onAccent: 'FFFFFF',
    headingFont: ARIAL,
    bodyFont: ARIAL,
  },
  'executive-dark': {
    id: 'executive-dark',
    name: 'Executive dark',
    description: 'Charcoal background, serif headings, gold accent.',
    background: '15171C',
    surface: '22252D',
    title: 'F5F3EE',
    text: 'D4D2CC',
    muted: '9A978F',
    accent: 'C9A45C',
    accentSoft: '3A3226',
    onAccent: '15171C',
    headingFont: GEORGIA,
    bodyFont: ARIAL,
  },
  'futuristic-cyan': {
    id: 'futuristic-cyan',
    name: 'Futuristic cyan',
    description: 'Deep navy background with cyan highlights.',
    background: '071526',
    surface: '0D2238',
    title: 'E8FBFF',
    text: 'B9D3E2',
    muted: '7E9BB0',
    accent: '22D3EE',
    accentSoft: '0E3A4E',
    onAccent: '04121F',
    headingFont: TREBUCHET,
    bodyFont: TREBUCHET,
  },
};

export function getTheme(id: ThemeId): DeckTheme {
  return THEMES[id];
}
