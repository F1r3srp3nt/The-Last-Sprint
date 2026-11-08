import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { bytesToBlob } from '../src/shared/util';
import { emptyProject, newSlide, defaultPlacement, type Asset, type BinaryStore, type Project } from '../src/shared/model';

const here = dirname(fileURLToPath(import.meta.url));
export const samplesDir = join(here, '..', 'samples');

export function sampleAsset(file: string, id: string, mime: Asset['mime'], width: number, height: number): { asset: Asset; bytes: Uint8Array } {
  const bytes = new Uint8Array(readFileSync(join(samplesDir, file)));
  return {
    asset: { id, name: file, mime, width, height, bytes: bytes.length, caption: `Synthetic sample: ${file}`, preferredSlide: null },
    bytes,
  };
}

/** A small deck that uses every layout. Synthetic content, clearly labelled. */
export function sampleProject(): { project: Project; store: BinaryStore } {
  const wide = sampleAsset('fjordlight-harbour-wide.png', 'img_wide', 'image/png', 1600, 900);
  const tall = sampleAsset('bike-station-portrait.jpg', 'img_tall', 'image/jpeg', 900, 1200);
  const project = emptyProject();
  project.title = 'Synthetic sample deck';
  project.assets = [wide.asset, tall.asset];
  project.slides = [
    newSlide('s1', 'title', 'manual', { title: 'Fjordlight bike-share pilot (synthetic sample)', body: 'For the test suite' }),
    newSlide('s2', 'textImage', 'manual', {
      title: 'Why a pilot',
      body: 'Short trips to the ferry\nFewer car trips in the centre\nOpen question: winter use',
      image: { ...defaultPlacement('img_tall', 'textImage'), mode: 'fill', zoom: 1.4, focusX: 0.3, focusY: 0.6 },
      notes: 'Explain that this is a synthetic sample used by the tests.',
    }),
    newSlide('s3', 'imageCaption', 'manual', { title: 'The harbour', caption: 'Drawing of a fictional district', image: defaultPlacement('img_wide', 'imageCaption') }),
    newSlide('s4', 'fullImage', 'manual', { title: 'Full-bleed image', caption: 'Fill mode, cropped', image: defaultPlacement('img_wide', 'fullImage') }),
    newSlide('s5', 'comparison', 'manual', { title: 'Option A vs B', leftHeading: 'Docks', leftBody: 'Fixed stations\nEasy to find', rightHeading: 'Free-floating', rightBody: 'Park anywhere\nHarder to manage' }),
    newSlide('s6', 'takeaway', 'manual', { title: 'Start small and measure', body: 'One district first' }),
    newSlide('s7', 'closing', 'manual', { title: 'Thank you', body: 'Questions?', notes: 'Close the session.' }),
  ];
  const store: BinaryStore = new Map([
    ['img_wide', bytesToBlob(wide.bytes, 'image/png')],
    ['img_tall', bytesToBlob(tall.bytes, 'image/jpeg')],
  ]);
  return { project, store };
}

export async function nodeImageResolver(store: BinaryStore, project: Project) {
  return async (id: string) => {
    const blob = store.get(id);
    const asset = project.assets.find((a) => a.id === id);
    if (!blob || !asset) return null;
    const b64 = Buffer.from(await blob.arrayBuffer()).toString('base64');
    return `${asset.mime};base64,${b64}`;
  };
}
