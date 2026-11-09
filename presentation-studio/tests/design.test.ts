// Slide design system, pre-generation checks, deduplication, restyling and resumable generation.
// No provider is called: everything runs on synthetic deck data.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import JSZip from 'jszip';
import { emptyProject, LAYOUT_IDS, newSlide, ProjectSchema, THEME_IDS, type Project, type Slide } from '../src/shared/model';
import { renderSlide, type ShapeElement, type TextElement } from '../src/shared/render';
import { THEMES } from '../src/shared/themes';
import { parseItem, parseItems } from '../src/shared/items';
import { conflictKey, parseSlideCount, slideCountConflict, slideCountMentions } from '../src/shared/briefCheck';
import { uniqueMessages } from '../src/shared/util';
import { fitLayoutToContent, validateOutline, validateSlideContent } from '../src/shared/generationSchemas';
import { slideFromContent } from '../src/shared/deckBuild';
import { applyRestyle, planRestyle } from '../src/shared/restyle';
import { briefKey, resumeInfo } from '../src/shared/resume';
import { exportPptxBytes } from '../src/export/pptx';
import { samplesDir } from './helpers';

/** The synthetic three-slide deck in samples/three-slide-deck.json. */
function threeSlideDeck(): Project {
  const raw = JSON.parse(readFileSync(join(samplesDir, 'three-slide-deck.json'), 'utf8')) as { title: string; slides: Partial<Slide>[] };
  const p = emptyProject();
  p.title = raw.title;
  p.slides = raw.slides.map((s, i) => newSlide(`deck${i + 1}`, s.layout!, 'ai', s));
  return p;
}

const texts = (els: ReturnType<typeof renderSlide>['elements']) => els.filter((e): e is TextElement => e.kind === 'text');
const shapes = (els: ReturnType<typeof renderSlide>['elements']) => els.filter((e): e is ShapeElement => e.kind === 'shape');

describe('slide count before generation', () => {
  it('finds slide counts written in the brief, in several languages, without false matches', () => {
    expect(slideCountMentions('Make 3 slides about bike sharing').map((m) => m.count)).toEqual([3]);
    expect(slideCountMentions('A three-slide deck for the board').map((m) => m.count)).toEqual([3]);
    expect(slideCountMentions('Lag tre korte lysbilder om sykkel').map((m) => m.count)).toEqual([3]);
    expect(slideCountMentions('Prezentacja: trzy slajdy').map((m) => m.count)).toEqual([3]);
    for (const none of ['Listen to the slides carefully', 'slide 3 shows the map', 'In 2026 we grew. Slides should be short.']) {
      expect(slideCountMentions(none)).toEqual([]);
    }
  });

  it('reports a conflict between the field and the brief (the 13-versus-3 case) and none when they agree', () => {
    const c = slideCountConflict({ topic: 'Bike share', brief: 'Make 3 slides', slideCount: 13 });
    expect(c).toEqual({ field: 13, mentioned: [3], example: '3 slides' });
    expect(conflictKey(c!)).toBe('13:3');
    expect(slideCountConflict({ topic: 'Bike share', brief: 'Make 3 slides', slideCount: 3 })).toBeNull();
    expect(slideCountConflict({ topic: 'Bike share', brief: 'No count here', slideCount: 7 })).toBeNull();
  });

  it('keeps the slide-count input editable: an empty box is not saved as 1', () => {
    // The old handler saved Number('') || 1 = 1 on every keystroke, so clearing "6" and typing "3" gave "13".
    expect(parseSlideCount('')).toBeNull();
    expect(parseSlideCount('3')).toBe(3);
    expect(parseSlideCount('13')).toBe(13);
    expect(parseSlideCount('31')).toBeNull();
    expect(parseSlideCount('0')).toBeNull();
    expect(parseSlideCount('2.5')).toBeNull();
  });
});

describe('deduplicated warnings', () => {
  it('drops repeated and already-shown messages, keeping order and first wording', () => {
    expect(uniqueMessages(['No figures were given.', 'no figures were given', '  ', 'Other.'])).toEqual(['No figures were given.', 'Other.']);
    expect(uniqueMessages(['A gap.', 'B gap.'], ['a gap'])).toEqual(['B gap.']);
  });

  it('reports a slide-count mismatch once, even when the outline is validated on the server and again in the browser', () => {
    const outline = {
      title: 'T',
      slides: [1, 2, 3].map((n) => ({ layout: 'bullets', title: `S${n}`, purpose: '', keyPoints: [], imageIds: [] })),
      imageNotes: [],
      missingInfo: [],
    };
    const server = validateOutline(structuredClone(outline), { slideCount: 13, assetIds: [] });
    const client = validateOutline(server.value, { slideCount: 13, assetIds: [] });
    const merged = uniqueMessages([...server.notices, ...client.notices]);
    expect(merged).toEqual(['The slide count is 13, but the planned outline has 3 slides.']);
  });

  it('drops slide flags that repeat each other or the deck-level missing information', () => {
    const s = slideFromContent(
      { layout: 'bullets', kicker: 'Why', title: 'T', body: 'a\nb', caption: '', leftHeading: '', leftBody: '', rightHeading: '', rightBody: '', imageId: '', notes: '', flags: ['No figures were given.', 'No figures were given', 'Winter use is unknown.'] },
      'x',
      undefined,
      ['Winter use is unknown'],
    );
    expect(s.flags).toEqual(['No figures were given.']);
    expect(s.kicker).toBe('Why');
  });

  it('never repeats a render warning on a slide', () => {
    const s = newSlide('w', 'process', 'manual', { title: '', body: Array.from({ length: 8 }, (_, i) => `Step ${i} — detail`).join('\n') });
    const r = renderSlide(s, THEMES['futuristic-cyan'], []);
    expect(new Set(r.warnings.map((w) => w.message)).size).toBe(r.warnings.length);
    expect(r.warnings.some((w) => /more than fits/.test(w.message))).toBe(true);
  });
});

describe('layout normalisation (no image generation)', () => {
  it('turns image layouts without an image into text layouts and reports it', () => {
    expect(fitLayoutToContent({ layout: 'fullImage', body: 'a\nb', imageId: '' }).layout).toBe('bullets');
    expect(fitLayoutToContent({ layout: 'imageCaption', body: '', imageId: '' }).layout).toBe('takeaway');
    expect(fitLayoutToContent({ layout: 'textImage', body: 'a', imageId: '' })).toEqual({ layout: 'bullets', notice: null });
    expect(fitLayoutToContent({ layout: 'cards', body: 'only one', imageId: '' }).layout).toBe('bullets');
    expect(fitLayoutToContent({ layout: 'process', body: 'A — 1\nB — 2', imageId: '' }).layout).toBe('process');
    const v = validateSlideContent(
      { layout: 'fullImage', kicker: '', title: 'T', body: 'x\ny', caption: '', leftHeading: '', leftBody: '', rightHeading: '', rightBody: '', imageId: '', notes: '', flags: [] },
      { assetIds: [] },
    );
    expect(v.value!.layout).toBe('bullets');
    const outline = validateOutline(
      { title: 'T', slides: [{ layout: 'fullImage', title: 'A', purpose: '', keyPoints: [], imageIds: [] }], imageNotes: [], missingInfo: [] },
      { slideCount: 1, assetIds: [] },
    );
    expect(outline.value!.slides[0].layout).toBe('bullets');
  });
});

describe('design system', () => {
  it('parses "Label — detail" lines without changing the text', () => {
    expect(parseItem('Unlock — Scan the code')).toEqual({ label: 'Unlock', detail: 'Scan the code' });
    expect(parseItem('Ride: short trips')).toEqual({ label: 'Ride', detail: 'short trips' });
    expect(parseItem('Meet at 10:30 by the dock')).toEqual({ label: 'Meet at 10:30 by the dock', detail: '' });
    expect(parseItems('a — 1\n\n• b — 2')).toHaveLength(2);
  });

  it('renders every layout in every theme as editable text plus native shapes, without overflow on sample content', () => {
    const body = 'Find a bike — Stations by the ferry\nUnlock — Scan the dock code\nRide — Short trips\nReturn — Any station';
    for (const themeId of THEME_IDS) {
      for (const layout of LAYOUT_IDS) {
        const s = newSlide(`${layout}`, layout, 'manual', {
          kicker: 'Section',
          title: 'A clear, specific title',
          body,
          caption: 'Caption',
          leftHeading: 'Left',
          leftBody: 'One\nTwo',
          rightHeading: 'Right',
          rightBody: 'One\nTwo',
        });
        const r = renderSlide(s, THEMES[themeId], [], { index: 1, total: 3 });
        const t = texts(r.elements);
        expect(t.every((e) => !e.overflow), `${themeId}/${layout}: ${r.warnings.map((w) => w.message).join('; ')}`).toBe(true);
        expect(t.find((e) => e.role === 'title' || layout === 'fullImage'), `${themeId}/${layout} has a title`).toBeTruthy();
        expect(new Set(r.elements.map((e) => e.id)).size, `${themeId}/${layout} ids are unique`).toBe(r.elements.length);
      }
    }
  });

  it('draws a workflow as numbered nodes with connectors, and cards as separate cards', () => {
    const deck = threeSlideDeck();
    const workflow = renderSlide({ ...deck.slides[1], layout: 'process' }, THEMES['futuristic-cyan'], []);
    expect(texts(workflow.elements).filter((e) => e.role === 'number').map((e) => e.paragraphs[0])).toEqual(['01', '02', '03', '04']);
    expect(texts(workflow.elements).filter((e) => e.role === 'itemLabel').map((e) => e.paragraphs[0])).toEqual(['Find a bike', 'Unlock', 'Ride', 'Return']);
    expect(shapes(workflow.elements).filter((e) => e.shape === 'hexagon').length).toBeGreaterThanOrEqual(4);
    const cards = renderSlide({ ...deck.slides[1], layout: 'cards' }, THEMES['clean-light'], []);
    expect(shapes(cards.elements).filter((e) => e.shape === 'roundRect')).toHaveLength(4);
  });

  it('gives Futuristic Cyan its own typography and geometry', () => {
    const s = threeSlideDeck().slides[0];
    const cyan = renderSlide(s, THEMES['futuristic-cyan'], [], { index: 0, total: 3 });
    const clean = renderSlide(s, THEMES['clean-light'], [], { index: 0, total: 3 });
    const kicker = texts(cyan.elements).find((e) => e.role === 'kicker')!;
    expect(kicker.font.pptx).toBe('Courier New');
    expect(kicker.charSpacing).toBeGreaterThan(0);
    expect(kicker.paragraphs[0]).toBe('PILOT PROPOSAL');
    expect(texts(cyan.elements).find((e) => e.role === 'footer')?.paragraphs[0]).toBe('01 / 03');
    expect(shapes(cyan.elements).some((e) => e.shape === 'hexagon')).toBe(true);
    expect(shapes(cyan.elements).filter((e) => e.shape === 'line').length).toBeGreaterThanOrEqual(4);
    expect(texts(clean.elements).find((e) => e.role === 'footer')).toBeUndefined();
    expect(shapes(clean.elements).some((e) => e.shape === 'hexagon')).toBe(false);
  });

  it('shows a text-only slide without an empty image area', () => {
    const r = renderSlide(threeSlideDeck().slides[1], THEMES['futuristic-cyan'], []);
    expect(r.elements.some((e) => e.kind === 'imagePlaceholder')).toBe(false);
    expect(texts(r.elements).filter((e) => e.role === 'itemLabel')).toHaveLength(4);
  });

  it('turns a closing slide with several lines into numbered next steps', () => {
    const r = renderSlide(threeSlideDeck().slides[2], THEMES['executive-dark'], []);
    expect(texts(r.elements).filter((e) => e.role === 'number').map((e) => e.paragraphs[0])).toEqual(['01', '02', '03']);
  });
});

describe('PowerPoint export of the new design', () => {
  it('writes native shapes, letter spacing, every text and the notes', async () => {
    const p = applyRestyleTo(threeSlideDeck());
    p.themeId = 'futuristic-cyan';
    const zip = await JSZip.loadAsync(await exportPptxBytes(p, async () => null));
    const slides = await Promise.all([1, 2, 3].map((n) => zip.file(`ppt/slides/slide${n}.xml`)!.async('string')));
    const all = slides.join('\n');
    for (const t of ['Fjordlight bike-share pilot', 'PILOT PROPOSAL', 'Find a bike', 'Stations sit next to the ferry stops', 'Start with one district', 'Decide on winter use', '02 / 03']) {
      expect(all).toContain(t);
    }
    expect(all).toContain('prst="hexagon"');
    expect(all).toContain('prst="ellipse"');
    expect(all).toContain('prst="line"');
    expect(all).toMatch(/spc="300"/); // 3 pt letter spacing on the eyebrow label
    expect(all).not.toContain('<p:pic>'); // no pictures: everything is editable shapes and text
    const notes = await Promise.all(Object.keys(zip.files).filter((f) => /notesSlide\d+\.xml$/.test(f)).map((f) => zip.file(f)!.async('string')));
    expect(notes.join('\n')).toContain('Walk through the four steps a rider takes.');
  });
});

function applyRestyleTo(p: Project): Project {
  return { ...p, slides: applyRestyle(p.slides, planRestyle(p.slides)) };
}

describe('restyle existing deck (no AI)', () => {
  it('picks layouts from content and keeps text, notes, images and narration', () => {
    const p = threeSlideDeck();
    p.slides[1].narration = { audioId: 'aud', notesHash: 'h', voiceId: 'v', voiceName: 'V', modelId: 'm', characters: 10, createdAt: 'now', mime: 'audio/mpeg' };
    const changes = planRestyle(p.slides);
    expect(changes).toEqual([{ slideId: 'deck2', index: 1, from: 'textImage', to: 'process', reason: 'its points read as steps in order' }]);
    const after = applyRestyle(p.slides, changes);
    after.forEach((s, i) => {
      const { layout: _a, ...rest } = s;
      const { layout: _b, ...before } = p.slides[i];
      expect(rest).toEqual(before);
    });
    expect(after[1].narration?.audioId).toBe('aud');
  });

  it('chooses cards for parallel items and never touches content-specific layouts', () => {
    const cardsSlide = newSlide('c', 'bullets', 'manual', { title: 'What riders get', body: 'Cheap — Low fare\nNearby — Many stations\nFlexible — Any return dock' });
    const comparison = newSlide('k', 'comparison', 'manual', { title: 'A vs B', leftBody: 'x', rightBody: 'y' });
    const withImage = newSlide('i', 'textImage', 'manual', { title: 'Map', body: 'a — 1\nb — 2\nc — 3', image: { assetId: 'img', mode: 'fit', zoom: 1, focusX: 0.5, focusY: 0.5 } });
    expect(planRestyle([cardsSlide, comparison, withImage]).map((c) => [c.slideId, c.to])).toEqual([['c', 'cards']]);
  });
});

describe('resumable generation', () => {
  function generated(): Project {
    const p = threeSlideDeck();
    p.brief = { ...p.brief, topic: 'Bike share', brief: 'Pilot', slideCount: 3 };
    const outline = { title: 'T', slides: p.slides.map((s) => ({ layout: s.layout, title: s.title, purpose: '', keyPoints: [], imageIds: [] })), imageNotes: [], missingInfo: [] };
    p.generation = { ...p.generation, mode: 'ai', resume: { briefKey: briefKey(p), outline, slideIds: p.slides.map((s) => s.id), pending: ['deck3'] } };
    return p;
  }

  it('offers to write only the unwritten slides, in their outline positions', () => {
    const info = resumeInfo(generated())!;
    expect(info.pendingCount).toBe(1);
    expect(info.entries.filter((e) => e.pending)).toEqual([{ slideId: 'deck3', index: 2, pending: true }]);
  });

  it('survives reordering, but not a changed brief or a damaged record', () => {
    const p = generated();
    p.slides.reverse();
    expect(resumeInfo(p)!.entries.find((e) => e.slideId === 'deck3')!.index).toBe(2);
    const changed = generated();
    changed.brief.brief = 'A different brief';
    expect(resumeInfo(changed)).toBeNull();
    const damaged = generated();
    damaged.generation.resume!.outline = { title: 1 };
    expect(resumeInfo(damaged)).toBeNull();
  });

  it('is saved with the project, and projects from before this change still open', () => {
    const p = generated();
    const roundTrip = ProjectSchema.parse(JSON.parse(JSON.stringify(p)));
    expect(resumeInfo(roundTrip)?.pendingCount).toBe(1);
    const old = JSON.parse(JSON.stringify(threeSlideDeck())) as { slides: Record<string, unknown>[]; generation: Record<string, unknown> };
    for (const s of old.slides) delete s.kicker;
    delete old.generation.resume;
    const loaded = ProjectSchema.parse(old);
    expect(loaded.slides[0].kicker).toBe('');
    expect(loaded.generation.resume).toBeNull();
  });
});
