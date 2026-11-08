/** Browser-side image helpers. Originals are stored untouched; these make derived copies only. */
import type { Asset } from '../shared/model';
import { newId } from '../shared/util';

export const ACCEPTED_TYPES = ['image/png', 'image/jpeg', 'image/webp'] as const;
const MAX_BYTES = 25 * 1024 * 1024;

export async function readImageFile(file: File): Promise<{ asset: Asset; blob: Blob }> {
  const type = file.type === 'image/jpg' ? 'image/jpeg' : file.type;
  if (!(ACCEPTED_TYPES as readonly string[]).includes(type)) {
    throw new Error(`"${file.name}" is not a PNG, JPEG or WebP image.`);
  }
  if (file.size > MAX_BYTES) throw new Error(`"${file.name}" is larger than 25 MB.`);
  let width: number;
  let height: number;
  try {
    const bmp = await createImageBitmap(file);
    width = bmp.width;
    height = bmp.height;
    bmp.close();
  } catch {
    throw new Error(`"${file.name}" could not be read as an image.`);
  }
  const blob = file.slice(0, file.size, type);
  return {
    asset: {
      id: newId('img'),
      name: file.name,
      mime: type as Asset['mime'],
      width,
      height,
      bytes: file.size,
      caption: '',
      preferredSlide: null,
    },
    blob,
  };
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(',')[1] ?? '');
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

async function drawScaled(blob: Blob, maxEdge: number, type: 'image/jpeg' | 'image/png', background?: string): Promise<Blob> {
  const bmp = await createImageBitmap(blob);
  const scale = Math.min(1, maxEdge / Math.max(bmp.width, bmp.height));
  const w = Math.max(1, Math.round(bmp.width * scale));
  const h = Math.max(1, Math.round(bmp.height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d')!;
  if (background) {
    ctx.fillStyle = background;
    ctx.fillRect(0, 0, w, h);
  }
  ctx.drawImage(bmp, 0, 0, w, h);
  bmp.close();
  return new Promise((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not encode image.'))), type, 0.85));
}

const modelCache = new Map<string, string>();

/** A JPEG copy, at most 1568 px on the long edge, for the generation model. */
export async function imageForModel(id: string, blob: Blob): Promise<{ mediaType: 'image/jpeg'; data: string }> {
  const cached = modelCache.get(id);
  if (cached) return { mediaType: 'image/jpeg', data: cached };
  const scaled = await drawScaled(blob, 1568, 'image/jpeg', '#ffffff');
  const data = await blobToBase64(scaled);
  modelCache.set(id, data);
  return { mediaType: 'image/jpeg', data };
}

/**
 * Image data for PptxGenJS. PNG and JPEG are embedded byte-for-byte; WebP is
 * converted to PNG (lossless) because older PowerPoint versions cannot show WebP.
 */
export async function imageForPptx(asset: Asset, blob: Blob): Promise<string> {
  if (asset.mime === 'image/webp') {
    const png = await drawScaled(blob, Number.MAX_SAFE_INTEGER, 'image/png');
    return `image/png;base64,${await blobToBase64(png)}`;
  }
  return `${asset.mime};base64,${await blobToBase64(blob)}`;
}

/** Object URLs for blobs, created once per blob. */
const urlCache = new WeakMap<Blob, string>();
export function blobUrl(blob: Blob | undefined): string | undefined {
  if (!blob) return undefined;
  let url = urlCache.get(blob);
  if (!url) {
    url = URL.createObjectURL(blob);
    urlCache.set(blob, url);
  }
  return url;
}

export function downloadBytes(bytes: Uint8Array | Blob, filename: string, type: string) {
  const blob = bytes instanceof Blob ? bytes : new Blob([bytes as Uint8Array<ArrayBuffer>], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
