import { describe, expect, it } from 'vitest';
import { computeImageGeometry } from '../src/shared/imageGeometry';
import { countWrappedLines, fitText, toParagraphs } from '../src/shared/textFit';
import { renderSlide } from '../src/shared/render';
import { THEMES } from '../src/shared/themes';
import { buildTemplateDeck, briefPoints } from '../src/shared/deckBuild';
import { validateOutline } from '../src/shared/generationSchemas';
import { narrationStatus } from '../src/shared/narration';
import { emptyBrief, newSlide, type Asset } from '../src/shared/model';
import { textHash } from '../src/shared/util';
import { loadProject, saveProject } from '../src/project/projectFile';
import { sampleProject } from './helpers';

const asset = (id: string, w: number, h: number, preferredSlide: number | null = null): Asset => ({ id, name: `${id}.png`, mime: 'image/png', width: w, height: h, bytes: 1, caption: `caption ${id}`, preferredSlide });

describe('image geometry', () => {
  const frame = { x: 1, y: 1, w: 6, h: 3 };
  it('fit keeps the aspect ratio and centres the image', () => {
    const g = computeImageGeometry(frame, { width: 1000, height: 1000 }, { mode: 'fit', zoom: 1, focusX: 0.5, focusY: 0.5 });
    expect(g.draw.w / g.draw.h).toBeCloseTo(1);
    expect(g.draw.h).toBeCloseTo(3);
    expect(g.draw.x).toBeCloseTo(2.5);
    expect(g.crop).toBeNull();
  });
  it('fill covers the frame without stretching, cropping the overflow', () => {
    const g = computeImageGeometry(frame, { width: 1000, height: 1000 }, { mode: 'fill', zoom: 1, focusX: 0.5, focusY: 0.5 });
    expect(g.draw.w / g.draw.h).toBeCloseTo(1);
    expect(g.draw.w).toBeCloseTo(6);
    expect(g.crop).toMatchObject({ x: 0, w: 6, h: 3 });
    expect(g.crop!.y).toBeCloseTo(1.5);
  });
  it('focus and zoom move the crop but keep it inside the image', () => {
    const g = computeImageGeometry(frame, { width: 1000, height: 1000 }, { mode: 'fill', zoom: 2, focusX: 1, focusY: 0 });
    expect(g.draw.w).toBeCloseTo(12);
    expect(g.crop!.x).toBeCloseTo(6); // right edge
    expect(g.crop!.y).toBeCloseTo(0); // top edge
    expect(g.crop!.x + g.crop!.w).toBeLessThanOrEqual(g.draw.w + 1e-9);
  });
});

describe('text fit', () => {
  it('wraps words', () => {
    expect(countWrappedLines('aaa bbb ccc', 7 * 10, 10)).toBe(2);
    expect(countWrappedLines('', 100, 10)).toBe(1);
  });
  it('keeps the preferred size when text fits', () => {
    const r = fitText({ paragraphs: ['Short'], boxW: 5, boxH: 1, fontSize: 30, minFontSize: 12, widthFactor: 0.52 });
    expect(r).toMatchObject({ fontSize: 30, overflow: false, shrunk: false });
  });
  it('shrinks long text and flags text that cannot fit', () => {
    const many = Array.from({ length: 8 }, () => 'A fairly long bullet point that wraps across the column width');
    const r = fitText({ paragraphs: many, boxW: 5.9, boxH: 5.1, fontSize: 20, minFontSize: 12, widthFactor: 0.52, bullets: true });
    expect(r.shrunk).toBe(true);
    expect(r.fontSize).toBeLessThan(20);
    const huge = Array.from({ length: 40 }, () => 'A fairly long bullet point that wraps across the column width');
    expect(fitText({ paragraphs: huge, boxW: 5.9, boxH: 5.1, fontSize: 20, minFontSize: 12, widthFactor: 0.52 }).overflow).toBe(true);
  });
  it('strips typed bullet markers and blank lines', () => {
    expect(toParagraphs('- one\n\n• two\n* three\n  four  ')).toEqual(['one', 'two', 'three', 'four']);
  });
  it('renders an overflow warning on the slide', () => {
    const s = newSlide('x', 'textImage', 'manual', { title: 'T', body: Array.from({ length: 40 }, (_, i) => `Bullet ${i} with quite a lot of words in it to wrap`).join('\n') });
    const r = renderSlide(s, THEMES['clean-light'], []);
    expect(r.warnings.some((w) => w.level === 'warning' && /too much text/.test(w.message))).toBe(true);
    const body = r.elements.find((e) => e.kind === 'text' && e.role === 'body');
    expect(body && body.kind === 'text' && body.overflow).toBe(true);
  });
});

describe('layouts', () => {
  it('every layout renders inside the slide bounds', () => {
    for (const layout of ['title', 'imageCaption', 'textImage', 'fullImage', 'comparison', 'takeaway', 'closing'] as const) {
      const s = newSlide('x', layout, 'manual', { title: 'Title', body: 'One\nTwo', caption: 'Cap', leftHeading: 'L', leftBody: 'a', rightHeading: 'R', rightBody: 'b', image: { assetId: 'a', mode: 'fit', zoom: 1, focusX: 0.5, focusY: 0.5 } });
      const r = renderSlide(s, THEMES['executive-dark'], [asset('a', 400, 300)]);
      for (const el of r.elements) {
        const box = el.kind === 'image' ? el.geometry.frame : el;
        expect(box.x).toBeGreaterThanOrEqual(0);
        expect(box.y).toBeGreaterThanOrEqual(0);
        expect(box.x + box.w).toBeLessThanOrEqual(13.334);
        expect(box.y + box.h).toBeLessThanOrEqual(7.501);
      }
    }
  });
});

describe('template mode', () => {
  it('uses only the brief, honours pinned images and labels every slide', () => {
    const brief = { ...emptyBrief(), topic: 'Topic', audience: 'Team', brief: 'First point\nSecond point\nThird point\nFourth point\nFifth point', slideCount: 6 };
    let n = 0;
    const slides = buildTemplateDeck(brief, [asset('a', 10, 10, 3), asset('b', 10, 10)], () => `s${++n}`);
    expect(slides).toHaveLength(6);
    expect(slides.every((s) => s.origin === 'template')).toBe(true);
    expect(slides[0]).toMatchObject({ layout: 'title', title: 'Topic', body: 'For Team' });
    expect(slides[2].image?.assetId).toBe('a');
    expect(slides.at(-1)!.layout).toBe('closing');
    const text = slides.map((s) => `${s.title}\n${s.body}`).join('\n');
    for (const p of ['First point', 'Second point', 'Third point', 'Fourth point', 'Fifth point']) expect(text).toContain(p);
    expect(slides.slice(1, -1).every((s) => s.title)).toBe(true); // no empty middle slides
    expect(slides.every((s) => s.notes === '')).toBe(true); // never invents notes
  });
  it('splits a single paragraph into sentences', () => {
    expect(briefPoints('We want a pilot. It should be small! Is winter a problem?')).toHaveLength(3);
  });
});

describe('outline validation', () => {
  it('rejects malformed outlines and removes unknown image ids', () => {
    expect(validateOutline({ title: 1 }, { slideCount: 3, assetIds: [] }).ok).toBe(false);
    const r = validateOutline(
      { title: 'T', slides: [{ layout: 'textImage', title: 'A', purpose: '', keyPoints: [], imageIds: ['ghost', 'img'] }], imageNotes: [{ imageId: 'ghost', description: '', visibleText: '' }], missingInfo: [] },
      { slideCount: 1, assetIds: ['img'] },
    );
    expect(r.ok).toBe(true);
    expect(r.value!.slides[0].imageIds).toEqual(['img']);
    expect(r.value!.imageNotes).toEqual([]);
    const pinned = validateOutline(
      { title: 'T', slides: [{ layout: 'textImage', title: 'A', purpose: '', keyPoints: [], imageIds: ['img'] }, { layout: 'takeaway', title: 'B', purpose: '', keyPoints: [], imageIds: [] }], imageNotes: [], missingInfo: [] },
      { slideCount: 2, assetIds: ['img'], preferred: { img: 2 } },
    );
    expect(pinned.value!.slides[0].imageIds).toEqual([]);
    expect(pinned.value!.slides[1]).toMatchObject({ imageIds: ['img'], layout: 'textImage' });
    expect(validateOutline({ title: 'T', slides: [{ layout: 'bogus', title: '', purpose: '', keyPoints: [], imageIds: [] }], imageNotes: [], missingInfo: [] }, { slideCount: 1, assetIds: [] }).ok).toBe(false);
  });
});

describe('narration status', () => {
  it('marks narration outdated when the notes change', () => {
    const s = newSlide('x', 'takeaway', 'manual', { notes: 'Original notes.' });
    expect(narrationStatus(s)).toBe('none');
    s.narration = { audioId: 'a', notesHash: textHash('Original notes.'), voiceId: 'v', voiceName: 'V', modelId: 'm', characters: 15, createdAt: '', mime: 'audio/mpeg' };
    expect(narrationStatus(s)).toBe('ready');
    s.notes = 'Original  notes.'; // whitespace-only change
    expect(narrationStatus(s)).toBe('ready');
    s.notes = 'Changed notes.';
    expect(narrationStatus(s)).toBe('outdated');
    expect(narrationStatus(newSlide('y', 'title', 'manual'))).toBe('no-notes');
  });
});

describe('project file', () => {
  it('round-trips slides, original image bytes and narration audio', async () => {
    const { project, store } = sampleProject();
    const audio = new Blob([new Uint8Array([1, 2, 3, 4])], { type: 'audio/mpeg' });
    store.set('aud_x', audio);
    project.slides[1].narration = { audioId: 'aud_x', notesHash: textHash(project.slides[1].notes), voiceId: 'v', voiceName: 'V', modelId: 'm', characters: 10, createdAt: 'now', mime: 'audio/mpeg' };
    const bytes = await saveProject(project, store);
    const loaded = await loadProject(bytes);
    expect(loaded.warnings).toEqual([]);
    expect(loaded.project).toEqual(project);
    for (const a of project.assets) {
      const before = new Uint8Array(await store.get(a.id)!.arrayBuffer());
      const after = new Uint8Array(await loaded.store.get(a.id)!.arrayBuffer());
      expect(after).toEqual(before);
    }
    expect(new Uint8Array(await loaded.store.get('aud_x')!.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(new TextDecoder().decode(bytes)).not.toMatch(/api[_-]?key/i);
  });
  it('rejects files that are not projects', async () => {
    await expect(loadProject(new Uint8Array([1, 2, 3]))).rejects.toThrow(/not a Presentation Studio project/);
  });
});
