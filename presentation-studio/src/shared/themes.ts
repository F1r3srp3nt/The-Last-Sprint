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
  /**
   * Visual language used by the renderer for compositions and decoration:
   * clean = soft panels and accent bars; executive = centred, thin gold rules, serif;
   * tech = asymmetric, monospace numbering, cyan hairlines, outlined geometry.
   */
  style: 'clean' | 'executive' | 'tech';
  /** Font for eyebrow labels and step/card numbers. */
  labelFont: FontSpec;
  /** Hairlines, connectors and card outlines. */
  line: string;
  cardFill: string;
  /** Card outline colour, or null for borderless cards. */
  cardLine: string | null;
  /** Corner radius of cards, in inches (0 = square). */
  radius: number;
  /** Letter spacing of eyebrow labels, in points. */
  labelTracking: number;
}

const ARIAL: FontSpec = { pptx: 'Arial', css: 'Arial, "Liberation Sans", Helvetica, sans-serif', widthFactor: 0.52 };
const GEORGIA: FontSpec = { pptx: 'Georgia', css: 'Georgia, "DejaVu Serif", "Times New Roman", serif', widthFactor: 0.55 };
const TREBUCHET: FontSpec = {
  pptx: 'Trebuchet MS',
  css: '"Trebuchet MS", "DejaVu Sans", Arial, sans-serif',
  widthFactor: 0.54,
};
/** Installed with Windows, macOS and Office, so exported decks keep their look. */
const COURIER: FontSpec = { pptx: 'Courier New', css: '"Courier New", "Liberation Mono", "DejaVu Sans Mono", monospace', widthFactor: 0.62 };

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
    style: 'clean',
    labelFont: ARIAL,
    line: 'CBD5E1',
    cardFill: 'F1F5F9',
    cardLine: null,
    radius: 0.14,
    labelTracking: 1.5,
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
    style: 'executive',
    labelFont: ARIAL,
    line: '6B5B3A',
    cardFill: '1C1F26',
    cardLine: '4A4130',
    radius: 0,
    labelTracking: 2.5,
  },
  'futuristic-cyan': {
    id: 'futuristic-cyan',
    name: 'Futuristic cyan',
    description: 'Deep navy, cyan hairlines, monospace numbering and outlined geometry.',
    background: '050B18',
    surface: '0A1A2F',
    title: 'F2FDFF',
    text: 'C3D9E6',
    muted: '7FA0B5',
    accent: '22D3EE',
    accentSoft: '0C3347',
    onAccent: '03101C',
    headingFont: TREBUCHET,
    bodyFont: TREBUCHET,
    style: 'tech',
    labelFont: COURIER,
    line: '1F5770',
    cardFill: '081628',
    cardLine: '1F5770',
    radius: 0.06,
    labelTracking: 3,
  },
};

export function getTheme(id: ThemeId): DeckTheme {
  return THEMES[id];
}
