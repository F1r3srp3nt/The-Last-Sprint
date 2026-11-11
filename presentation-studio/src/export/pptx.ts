/**
 * Editable PowerPoint export with PptxGenJS. Every slide is built from the
 * same RenderedSlide elements the preview draws: real text boxes, real
 * pictures (cropped with PowerPoint's own crop, so it can be undone in
 * PowerPoint) and speaker notes. Nothing is rasterised.
 *
 * Runs in the browser and in Node (used by the tests).
 */
import PptxGenJS from 'pptxgenjs';
import type { Project } from '../shared/model';
import { renderSlide, type ImageElement, type ShapeElement, type TextElement } from '../shared/render';
import { getTheme } from '../shared/themes';
import { BULLET_INDENT_PT } from '../shared/textFit';

/** Returns the image as `image/<type>;base64,<data>` in a format PowerPoint can read (PNG or JPEG). */
export type ImageDataResolver = (assetId: string) => Promise<string | null>;

const EMU_PER_INCH = 914400;

/**
 * PptxGenJS reads numbers below 100 as inches and larger ones as EMU. Fill-mode
 * images can be scaled past 100 inches, so image geometry is always passed in
 * EMU to avoid that ambiguity.
 */
function emu(inches: number): number {
  const v = Math.round(inches * EMU_PER_INCH);
  return Math.abs(v) < 100 ? 0 : v;
}

function addTextElement(slide: PptxGenJS.Slide, el: TextElement) {
  const runs: PptxGenJS.TextProps[] = el.paragraphs.map((p, i) => ({
    text: p,
    options: {
      bullet: el.bullets ? { indent: BULLET_INDENT_PT } : false,
      breakLine: i < el.paragraphs.length - 1,
      paraSpaceAfter: i < el.paragraphs.length - 1 ? el.paraSpacePt : 0,
    },
  }));
  slide.addText(runs, {
    x: el.x,
    y: el.y,
    w: el.w,
    h: el.h,
    fontFace: el.font.pptx,
    fontSize: el.fontSize,
    color: el.color,
    bold: el.bold,
    italic: el.italic,
    align: el.align,
    valign: el.valign,
    margin: 0,
    charSpacing: el.charSpacing || undefined,
    fit: 'none',
    wrap: true,
    objectName: el.role,
  });
}

function addShapeElement(pptx: PptxGenJS, slide: PptxGenJS.Slide, el: ShapeElement) {
  const type = {
    rect: pptx.ShapeType.rect,
    roundRect: pptx.ShapeType.roundRect,
    ellipse: pptx.ShapeType.ellipse,
    hexagon: pptx.ShapeType.hexagon,
    line: pptx.ShapeType.line,
  }[el.shape];
  slide.addShape(type, {
    x: el.x,
    y: el.y,
    w: el.w,
    h: el.h,
    fill: el.fill ? { color: el.fill, transparency: el.fillTransparency } : { type: 'none' },
    line: el.line ? { color: el.line.color, width: el.line.width, transparency: el.line.transparency } : { type: 'none' },
    ...(el.shape === 'roundRect' ? { rectRadius: el.radius } : {}),
  });
}

function addImageElement(slide: PptxGenJS.Slide, el: ImageElement, data: string) {
  const g = el.geometry;
  if (g.crop) {
    slide.addImage({
      data,
      x: emu(g.frame.x),
      y: emu(g.frame.y),
      w: emu(g.draw.w),
      h: emu(g.draw.h),
      sizing: { type: 'crop', x: emu(g.crop.x), y: emu(g.crop.y), w: emu(g.crop.w), h: emu(g.crop.h) },
      altText: el.altText,
    });
  } else {
    slide.addImage({ data, x: emu(g.draw.x), y: emu(g.draw.y), w: emu(g.draw.w), h: emu(g.draw.h), altText: el.altText });
  }
}

export async function buildPptx(project: Project, resolveImage: ImageDataResolver): Promise<PptxGenJS> {
  const pptx = new PptxGenJS();
  pptx.layout = 'LAYOUT_WIDE'; // 13.333 x 7.5 in, the size render.ts uses
  pptx.title = project.title;
  pptx.subject = project.brief.topic;
  pptx.author = 'Presentation Studio';
  const theme = getTheme(project.themeId);
  const cache = new Map<string, string | null>();

  for (const [index, s] of project.slides.entries()) {
    const rendered = renderSlide(s, theme, project.assets, { index, total: project.slides.length });
    const slide = pptx.addSlide();
    slide.background = { color: rendered.background };
    for (const el of rendered.elements) {
      if (el.kind === 'text') addTextElement(slide, el);
      else if (el.kind === 'shape') addShapeElement(pptx, slide, el);
      else if (el.kind === 'image') {
        if (!cache.has(el.assetId)) cache.set(el.assetId, await resolveImage(el.assetId));
        const data = cache.get(el.assetId);
        if (data) addImageElement(slide, el, data);
      }
      // imagePlaceholder: editor-only, never exported
    }
    if (s.notes.trim()) slide.addNotes(s.notes.trim());
  }
  return pptx;
}

export async function exportPptxBytes(project: Project, resolveImage: ImageDataResolver): Promise<Uint8Array> {
  const pptx = await buildPptx(project, resolveImage);
  const out = await pptx.write({ outputType: 'uint8array' });
  return out as Uint8Array;
}
