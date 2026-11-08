import { describe, expect, it } from 'vitest';
import JSZip from 'jszip';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { exportPptxBytes } from '../src/export/pptx';
import { buildNarrationZip } from '../src/export/narrationZip';
import { textHash } from '../src/shared/util';
import { nodeImageResolver, sampleProject } from './helpers';

const outDir = join(import.meta.dirname, '..', 'test-output');

async function exportSample() {
  const { project, store } = sampleProject();
  const bytes = await exportPptxBytes(project, await nodeImageResolver(store, project));
  return { project, store, bytes, zip: await JSZip.loadAsync(bytes) };
}

function slideFiles(zip: JSZip, prefix: string) {
  return Object.keys(zip.files)
    .filter((f) => new RegExp(`^${prefix}\\d+\\.xml$`).test(f))
    .sort((a, b) => Number(a.match(/(\d+)\.xml$/)![1]) - Number(b.match(/(\d+)\.xml$/)![1]));
}

describe('PowerPoint export', () => {
  it('writes a valid package with one slide per model slide', async () => {
    const { project, bytes, zip } = await exportSample();
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, 'sample.pptx'), bytes);
    expect(zip.file('[Content_Types].xml')).toBeTruthy();
    expect(zip.file('ppt/presentation.xml')).toBeTruthy();
    expect(slideFiles(zip, 'ppt/slides/slide')).toHaveLength(project.slides.length);
    const pres = await zip.file('ppt/presentation.xml')!.async('string');
    // LAYOUT_WIDE: 13.333 x 7.5 in
    expect(pres).toMatch(/<p:sldSz cx="12192000" cy="6858000"/);
  });

  it('exports real, editable text boxes (not pictures of slides)', async () => {
    const { project, zip } = await exportSample();
    const files = slideFiles(zip, 'ppt/slides/slide');
    for (let i = 0; i < project.slides.length; i++) {
      const xml = await zip.file(files[i])!.async('string');
      const title = project.slides[i].title.replace(/&/g, '&amp;');
      expect(xml).toContain(`<a:t>${title}</a:t>`);
      expect(xml).toMatch(/<p:sp>[\s\S]*?<p:txBody>/);
    }
    const s2 = await zip.file(files[1])!.async('string');
    expect(s2).toContain('<a:t>Short trips to the ferry</a:t>');
    expect(s2).toMatch(/<a:buChar char="/);
  });

  it('writes speaker notes', async () => {
    const { zip } = await exportSample();
    const notes = await Promise.all(slideFiles(zip, 'ppt/notesSlides/notesSlide').map((f) => zip.file(f)!.async('string')));
    expect(notes.some((n) => n.includes('Explain that this is a synthetic sample used by the tests.'))).toBe(true);
    expect(notes.some((n) => n.includes('Close the session.'))).toBe(true);
  });

  it('places images without stretching them', async () => {
    const { project, zip } = await exportSample();
    const files = slideFiles(zip, 'ppt/slides/slide');
    const media = Object.keys(zip.files).filter((f) => f.startsWith('ppt/media/'));
    expect(media.length).toBeGreaterThanOrEqual(3);

    // Slide 3: fit mode, no crop -> picture aspect equals the image aspect (1600x900).
    const s3 = await zip.file(files[2])!.async('string');
    const ext3 = s3.match(/<p:pic>[\s\S]*?<a:ext cx="(\d+)" cy="(\d+)"/)!;
    expect(Number(ext3[1]) / Number(ext3[2])).toBeCloseTo(1600 / 900, 2);
    expect(s3).toContain('<a:stretch><a:fillRect/></a:stretch>');

    // Slide 2: fill mode with zoom -> PowerPoint crop (srcRect); the visible part of the image has the frame's aspect.
    const s2 = await zip.file(files[1])!.async('string');
    const src = s2.match(/<a:srcRect l="(-?\d+)" r="(-?\d+)" t="(-?\d+)" b="(-?\d+)"\/>/)!;
    const [l, r, t, b] = src.slice(1).map(Number);
    const ext2 = s2.match(/<p:pic>[\s\S]*?<a:ext cx="(\d+)" cy="(\d+)"/)!;
    const frameAspect = Number(ext2[1]) / Number(ext2[2]);
    const visibleAspect = ((1 - (l + r) / 1e5) * 900) / ((1 - (t + b) / 1e5) * 1200);
    expect(visibleAspect).toBeCloseTo(frameAspect, 2);
    for (const v of [l, r, t, b]) expect(v).toBeGreaterThanOrEqual(0);
    expect(project.slides[1].image?.mode).toBe('fill');
  });

  it('builds the narration ZIP with numbered audio files and a mapping', async () => {
    const { project, store, bytes } = await exportSample();
    const audio = new Blob([new Uint8Array([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0])], { type: 'audio/mpeg' });
    store.set('aud_1', audio);
    project.slides[1].narration = {
      audioId: 'aud_1', notesHash: textHash(project.slides[1].notes), voiceId: 'v1', voiceName: 'Test voice',
      modelId: 'eleven_multilingual_v2', characters: 60, createdAt: new Date().toISOString(), mime: 'audio/mpeg',
    };
    project.slides[6].narration = { ...project.slides[1].narration, notesHash: 'stale' };
    store.set('aud_1', audio);
    const zipBytes = await buildNarrationZip(project, bytes, store);
    const zip = await JSZip.loadAsync(zipBytes);
    expect(zip.file('synthetic-sample-deck.pptx')).toBeTruthy();
    expect(zip.file('narration/slide-02.mp3')).toBeTruthy();
    expect(zip.file('narration/slide-07.mp3')).toBeTruthy();
    const mapping = JSON.parse(await zip.file('narration/mapping.json')!.async('string'));
    expect(mapping.slides).toHaveLength(7);
    expect(mapping.slides[1]).toMatchObject({ slide: 2, audioFile: 'narration/slide-02.mp3', status: 'ready' });
    expect(mapping.slides[6]).toMatchObject({ slide: 7, status: 'outdated' });
    expect(mapping.slides[0]).toMatchObject({ slide: 1, audioFile: null, status: 'no-notes' });
    const csv = await zip.file('narration/mapping.csv')!.async('string');
    expect(csv.split('\n')[0]).toBe('slide,slideId,title,audioFile,status,voice,model,characters');
  });
});
