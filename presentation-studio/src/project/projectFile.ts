/**
 * Project files (.pstudio) are ZIP archives:
 *   project.json          slide model, brief, theme, asset metadata
 *   assets/<id>.<ext>     original uploads, byte-for-byte
 *   audio/<id>.mp3        generated narration
 * No credentials are ever written here.
 */
import JSZip from 'jszip';
import { ProjectSchema, type BinaryStore, type Project } from '../shared/model';
import { bytesToBlob } from '../shared/util';

export const PROJECT_EXTENSION = '.pstudio';

const EXT: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'audio/mpeg': 'mp3',
};

function assetPath(id: string, mime: string) {
  return `assets/${id}.${EXT[mime] ?? 'bin'}`;
}
function audioPath(id: string, mime: string) {
  return `audio/${id}.${EXT[mime] ?? 'bin'}`;
}

export async function saveProject(project: Project, store: BinaryStore): Promise<Uint8Array> {
  const zip = new JSZip();
  zip.file('project.json', JSON.stringify(project, null, 2));
  for (const a of project.assets) {
    const blob = store.get(a.id);
    if (!blob) throw new Error(`Image "${a.name}" is missing its data and cannot be saved.`);
    zip.file(assetPath(a.id, a.mime), new Uint8Array(await blob.arrayBuffer()), { binary: true });
  }
  for (const s of project.slides) {
    if (!s.narration) continue;
    const blob = store.get(s.narration.audioId);
    if (blob) zip.file(audioPath(s.narration.audioId, s.narration.mime), new Uint8Array(await blob.arrayBuffer()), { binary: true });
  }
  return zip.generateAsync({ type: 'uint8array', compression: 'DEFLATE', compressionOptions: { level: 6 } });
}

export interface LoadedProject {
  project: Project;
  store: BinaryStore;
  warnings: string[];
}

export async function loadProject(data: Uint8Array | ArrayBuffer | Blob): Promise<LoadedProject> {
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(data instanceof Blob ? await data.arrayBuffer() : data);
  } catch {
    throw new Error('This file is not a Presentation Studio project (it is not a valid ZIP archive).');
  }
  const manifest = zip.file('project.json');
  if (!manifest) throw new Error('This file is not a Presentation Studio project (project.json is missing).');
  let json: unknown;
  try {
    json = JSON.parse(await manifest.async('string'));
  } catch {
    throw new Error('project.json is not valid JSON.');
  }
  const parsed = ProjectSchema.safeParse(json);
  if (!parsed.success) {
    const first = parsed.error.issues[0];
    throw new Error(`The project file is not in a supported format (${first.path.join('.') || 'root'}: ${first.message}).`);
  }
  const project = parsed.data;
  const store: BinaryStore = new Map();
  const warnings: string[] = [];

  const missingAssets = new Set<string>();
  for (const a of project.assets) {
    const f = zip.file(assetPath(a.id, a.mime));
    if (!f) {
      missingAssets.add(a.id);
      continue;
    }
    store.set(a.id, bytesToBlob(await f.async('uint8array'), a.mime));
  }
  if (missingAssets.size) {
    warnings.push(`${missingAssets.size} image(s) were missing from the file and have been removed.`);
    project.assets = project.assets.filter((a) => !missingAssets.has(a.id));
    for (const s of project.slides) if (s.image && missingAssets.has(s.image.assetId)) s.image = null;
  }
  for (const s of project.slides) {
    if (s.image && !project.assets.some((a) => a.id === s.image!.assetId)) s.image = null;
    if (!s.narration) continue;
    const f = zip.file(audioPath(s.narration.audioId, s.narration.mime));
    if (!f) {
      warnings.push(`Narration audio for slide "${s.title || s.id}" was missing and has been cleared.`);
      s.narration = null;
      continue;
    }
    store.set(s.narration.audioId, bytesToBlob(await f.async('uint8array'), s.narration.mime));
  }
  return { project, store, warnings };
}
