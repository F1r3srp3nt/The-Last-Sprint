/**
 * The only bridge between the sandboxed renderer and the main process. It exposes a fixed set
 * of functions; the renderer gets no access to ipcRenderer, Node or Electron itself, and no
 * function returns a provider key.
 */
import { contextBridge, ipcRenderer } from 'electron';

const CH = {
  credentialsStatus: 'ps:credentials:status',
  credentialsSave: 'ps:credentials:save',
  credentialsClear: 'ps:credentials:clear',
  fileSave: 'ps:file:save',
  fileOpenProject: 'ps:file:open-project',
  backendStatus: 'ps:backend:status',
  backendRestart: 'ps:backend:restart',
} as const;

type Provider = 'anthropic' | 'elevenlabs';
type Kind = 'project' | 'pptx' | 'zip';

async function call<T>(channel: string, payload?: unknown): Promise<T> {
  const result = (await ipcRenderer.invoke(channel, payload)) as { ok: true; value: T } | { ok: false; error: string };
  if (!result?.ok) throw new Error(result?.error ?? 'Request failed.');
  return result.value;
}

contextBridge.exposeInMainWorld('presentationStudioDesktop', Object.freeze({
  isDesktop: true,
  platform: process.platform,
  credentials: Object.freeze({
    status: () => call(CH.credentialsStatus),
    save: (provider: Provider, key: string) => call(CH.credentialsSave, { provider, key }),
    clear: (provider: Provider) => call(CH.credentialsClear, { provider }),
  }),
  files: Object.freeze({
    save: (kind: Kind, suggestedName: string, bytes: Uint8Array) => call(CH.fileSave, { kind, suggestedName, bytes }),
    openProject: () => call(CH.fileOpenProject),
  }),
  backend: Object.freeze({
    status: () => call(CH.backendStatus),
    restart: () => call(CH.backendRestart),
    onChange: (listener: (status: unknown) => void) => {
      const wrapped = (_e: unknown, status: unknown) => listener(status);
      ipcRenderer.on('ps:backend:changed', wrapped);
      return () => ipcRenderer.removeListener('ps:backend:changed', wrapped);
    },
  }),
}));
