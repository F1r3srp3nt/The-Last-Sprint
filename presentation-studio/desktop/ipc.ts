/**
 * The complete IPC surface between the renderer and the main process, with validation.
 * Every handler checks the sender's origin and validates its payload with these schemas;
 * anything else is rejected. No channel returns a key.
 */
import { z } from 'zod';
import { PROVIDERS } from './credentials';

export const APP_ORIGIN = 'app://studio';

export const CHANNELS = {
  credentialsStatus: 'ps:credentials:status',
  credentialsSave: 'ps:credentials:save',
  credentialsClear: 'ps:credentials:clear',
  fileSave: 'ps:file:save',
  fileOpenProject: 'ps:file:open-project',
  backendStatus: 'ps:backend:status',
  backendRestart: 'ps:backend:restart',
} as const;

export const MAX_FILE_BYTES = 1024 * 1024 * 1024; // 1 GiB

export const FILE_KINDS = {
  project: { extension: '.pstudio', label: 'Presentation Studio project' },
  pptx: { extension: '.pptx', label: 'PowerPoint presentation' },
  zip: { extension: '.zip', label: 'PowerPoint + narration (ZIP)' },
} as const;
export type FileKind = keyof typeof FILE_KINDS;

export const ProviderSchema = z.enum(PROVIDERS);
export const CredentialSaveSchema = z.strictObject({ provider: ProviderSchema, key: z.string().max(1024) });
export const CredentialClearSchema = z.strictObject({ provider: ProviderSchema });
export const FileSaveSchema = z.strictObject({
  kind: z.enum(['project', 'pptx', 'zip']),
  suggestedName: z.string().max(200),
  bytes: z.instanceof(Uint8Array).refine((b) => b.byteLength > 0 && b.byteLength <= MAX_FILE_BYTES, 'file size out of range'),
});
export const NoArgsSchema = z.undefined();

/** A safe file name for the save dialog: no folders, no control characters, the right extension. */
export function safeFileName(kind: FileKind, suggested: string): string {
  const ext = FILE_KINDS[kind].extension;
  let base = suggested
    .replace(/[\\/:*?"<>|\u0000-\u001f\u007f]/g, '-')
    .replace(/^\.+/, '')
    .trim();
  if (base.toLowerCase().endsWith(ext)) base = base.slice(0, -ext.length);
  base = base.slice(0, 120).trim() || 'presentation';
  return `${base}${ext}`;
}

/** True only for the app's own pages. */
export function isAppUrl(url: string | undefined | null): boolean {
  if (!url) return false;
  try {
    const u = new URL(url);
    return u.protocol === 'app:' && u.host === 'studio';
  } catch {
    return false;
  }
}

/** Static files of the renderer: maps an app:// path to a file path inside dist/, or null. */
export function staticPath(pathname: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (decoded.includes('\0') || decoded.split('/').some((seg) => seg === '..')) return null;
  const rel = decoded.replace(/^\/+/, '');
  return rel === '' ? 'index.html' : rel;
}
