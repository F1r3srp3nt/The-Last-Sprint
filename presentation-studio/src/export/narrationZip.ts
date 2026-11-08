/**
 * "PowerPoint + narration" export: a ZIP with the editable .pptx, one numbered
 * audio file per narrated slide, and a slide-to-audio mapping (JSON and CSV).
 * Audio is not embedded in the .pptx (see README: not verified).
 */
import JSZip from 'jszip';
import type { BinaryStore, Project } from '../shared/model';
import { narrationStatus } from '../shared/narration';
import { pad2, slugify } from '../shared/util';

export interface NarrationMappingRow {
  slide: number;
  slideId: string;
  title: string;
  audioFile: string | null;
  status: 'ready' | 'outdated' | 'missing' | 'no-notes';
  voice: string | null;
  model: string | null;
  characters: number;
}

export function narrationMapping(project: Project): NarrationMappingRow[] {
  return project.slides.map((s, i) => {
    const status = narrationStatus(s);
    const hasAudio = Boolean(s.narration);
    return {
      slide: i + 1,
      slideId: s.id,
      title: s.title,
      audioFile: hasAudio ? `narration/slide-${pad2(i + 1)}.mp3` : null,
      status: status === 'none' ? 'missing' : status,
      voice: s.narration?.voiceName ?? null,
      model: s.narration?.modelId ?? null,
      characters: s.narration?.characters ?? 0,
    };
  });
}

function csvCell(v: unknown): string {
  const s = v === null || v === undefined ? '' : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export async function buildNarrationZip(project: Project, pptx: Uint8Array, store: BinaryStore): Promise<Uint8Array> {
  const zip = new JSZip();
  const base = slugify(project.title);
  zip.file(`${base}.pptx`, pptx, { binary: true });
  const rows = narrationMapping(project);
  for (const row of rows) {
    const s = project.slides[row.slide - 1];
    if (!row.audioFile || !s.narration) continue;
    const blob = store.get(s.narration.audioId);
    if (!blob) {
      row.audioFile = null;
      row.status = 'missing';
      continue;
    }
    zip.file(row.audioFile, new Uint8Array(await blob.arrayBuffer()), { binary: true });
  }
  zip.file('narration/mapping.json', JSON.stringify({ presentation: `${base}.pptx`, slides: rows }, null, 2));
  const header = ['slide', 'slideId', 'title', 'audioFile', 'status', 'voice', 'model', 'characters'] as const;
  const csv = [header.join(','), ...rows.map((r) => header.map((h) => csvCell(r[h])).join(','))].join('\n');
  zip.file('narration/mapping.csv', csv + '\n');
  zip.file(
    'README.txt',
    [
      `${project.title}`,
      '',
      `${base}.pptx is the editable presentation.`,
      'narration/slide-NN.mp3 is the narration for slide NN, generated with ElevenLabs from that slide\'s speaker notes.',
      'narration/mapping.json and mapping.csv list every slide and its audio file.',
      'status "outdated" means the speaker notes changed after the audio was generated.',
      'status "missing" means the slide has notes but no narration; "no-notes" means it has no speaker notes.',
      '',
      'Exported by Presentation Studio (Oslo Sprint).',
    ].join('\n'),
  );
  return zip.generateAsync({ type: 'uint8array', compression: 'DEFLATE' });
}
