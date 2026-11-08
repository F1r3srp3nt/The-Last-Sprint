/**
 * Presentation Studio desktop shell (Electron main process).
 *
 * - The renderer is the existing React client, served from the app bundle over a private
 *   `app://studio` scheme with a strict Content-Security-Policy.
 * - `/api/*` requests from the renderer are forwarded here to the bundled backend (a utility
 *   process on a random 127.0.0.1 port) with a per-launch token the renderer never sees.
 * - Provider keys are kept in the main process, encrypted with safeStorage (macOS Keychain).
 * - The renderer runs sandboxed with context isolation and no Node integration; it reaches the
 *   main process only through the validated channels in ipc.ts.
 */
import { app, BrowserWindow, dialog, ipcMain, Menu, protocol, safeStorage, session, shell, utilityProcess, type MenuItemConstructorOptions } from 'electron';
import { appendFileSync, existsSync, mkdirSync, statSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { basename, extname, join } from 'node:path';
import type { z } from 'zod';
import { BackendManager } from './backend';
import { CredentialError, CredentialStore, type Encryptor } from './credentials';
import {
  APP_ORIGIN,
  CHANNELS,
  CredentialClearSchema,
  CredentialSaveSchema,
  FILE_KINDS,
  FileSaveSchema,
  isAppUrl,
  MAX_FILE_BYTES,
  NoArgsSchema,
  safeFileName,
  staticPath,
} from './ipc';

const TOKEN_HEADER = 'x-presentation-studio-token';

// ---- Test hooks (only when PRESENTATION_STUDIO_E2E_DIR is set; documented in DESKTOP.md) ------
// The end-to-end test drives the packaged app over the Chrome DevTools protocol, which cannot
// click native dialogs. With this variable set, save dialogs write into that folder, the open
// dialog returns PRESENTATION_STUDIO_E2E_OPEN, user data lives in that folder, and keys may be
// kept in a clearly labelled non-secure test store. Setting environment variables already
// requires the user's own account, so this grants nothing an attacker would not already have.
const e2eDir = process.env.PRESENTATION_STUDIO_E2E_DIR || null;
if (e2eDir) app.setPath('userData', join(e2eDir, 'user-data'));

protocol.registerSchemesAsPrivileged([
  { scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, codeCache: true } },
]);

if (!app.requestSingleInstanceLock()) {
  app.quit();
}

// ---- Logging (never keys; the backend logs only error codes and sizes) -----------------------
let logFile: string | null = null;
function log(line: string) {
  const stamped = `${new Date().toISOString()} ${line}`;
  if (!app.isPackaged || e2eDir) console.log(stamped);
  try {
    if (!logFile) {
      const dir = join(app.getPath('userData'), 'logs');
      mkdirSync(dir, { recursive: true });
      logFile = join(dir, 'main.log');
    }
    appendFileSync(logFile, `${stamped}\n`);
  } catch {
    /* logging must never break the app */
  }
}

// ---- Credentials ------------------------------------------------------------------------------
const electronEncryptor: Encryptor = {
  secure: () => safeStorage.isEncryptionAvailable() && !(process.platform === 'linux' && safeStorage.getSelectedStorageBackend() === 'basic_text'),
  backendName: () =>
    process.platform === 'darwin' ? 'macOS Keychain' : process.platform === 'win32' ? 'Windows DPAPI' : `Linux secret store (${safeStorage.getSelectedStorageBackend()})`,
  encrypt: (s) => safeStorage.encryptString(s),
  decrypt: (b) => safeStorage.decryptString(b),
};
const e2eEncryptor: Encryptor = {
  secure: () => true,
  backendName: () => 'E2E test store (NOT secure; test runs only)',
  encrypt: (s) => Buffer.from(`e2e:${s}`, 'utf8'),
  decrypt: (b) => b.toString('utf8').replace(/^e2e:/, ''),
};

let credentials: CredentialStore;
let backend: BackendManager;
let mainWindow: BrowserWindow | null = null;

function e2eBaseUrls() {
  if (!e2eDir) return undefined;
  return {
    anthropic: process.env.PRESENTATION_STUDIO_E2E_ANTHROPIC_BASE_URL || undefined,
    elevenlabs: process.env.PRESENTATION_STUDIO_E2E_ELEVENLABS_BASE_URL || undefined,
  };
}

// ---- app:// scheme: static client + /api forwarding -----------------------------------------
const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.ico': 'image/x-icon',
};
const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "media-src 'self' blob:",
  "font-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join('; ');

const FORWARD_REQUEST_HEADERS = ['content-type', 'accept'];
const FORWARD_RESPONSE_HEADERS = ['content-type', 'x-narration-model', 'x-narration-characters'];
const MAX_API_BODY = 120 * 1024 * 1024;

function jsonError(status: number, code: string, message: string, hint?: string): Response {
  return new Response(JSON.stringify({ error: { code, message, hint, retryable: true } }), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

async function forwardApi(request: Request, url: URL): Promise<Response> {
  const declared = Number(request.headers.get('content-length') ?? 0);
  if (declared > MAX_API_BODY) return jsonError(413, 'too_large', 'The request is too large.');
  const endpoint = await backend.ready();
  if (!endpoint) {
    const status = backend.current();
    return jsonError(503, 'backend_unavailable', status.error ?? 'The built-in server is not running.', 'Choose "Restart server" in the banner, or quit and reopen Presentation Studio.');
  }
  const headers = new Headers();
  for (const name of FORWARD_REQUEST_HEADERS) {
    const v = request.headers.get(name);
    if (v) headers.set(name, v);
  }
  headers.set(TOKEN_HEADER, endpoint.token);
  const init: RequestInit = { method: request.method, headers, redirect: 'manual' };
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    const body = await request.arrayBuffer();
    if (body.byteLength > MAX_API_BODY) return jsonError(413, 'too_large', 'The request is too large.');
    init.body = body;
  }
  let res: Response;
  try {
    res = await fetch(new URL(url.pathname + url.search, endpoint.url), init);
  } catch {
    return jsonError(503, 'backend_unavailable', 'The built-in server did not answer.', 'Choose "Restart server" in the banner.');
  }
  const out = new Headers();
  for (const name of FORWARD_RESPONSE_HEADERS) {
    const v = res.headers.get(name);
    if (v) out.set(name, v);
  }
  return new Response(res.body, { status: res.status, headers: out });
}

async function serveStatic(url: URL): Promise<Response> {
  const dist = join(app.getAppPath(), 'dist');
  let rel = staticPath(url.pathname);
  if (!rel) return new Response('Bad path', { status: 400 });
  let file = join(dist, rel);
  if (!existsSync(file) || statSync(file).isDirectory()) {
    if (extname(rel)) return new Response('Not found', { status: 404 });
    rel = 'index.html';
    file = join(dist, rel);
  }
  const bytes = await readFile(file);
  return new Response(bytes, {
    status: 200,
    headers: {
      'content-type': MIME[extname(file).toLowerCase()] ?? 'application/octet-stream',
      'content-security-policy': CSP,
      'x-content-type-options': 'nosniff',
      'cache-control': 'no-cache',
    },
  });
}

function registerAppProtocol() {
  protocol.handle('app', async (request) => {
    const url = new URL(request.url);
    if (url.host !== 'studio') return new Response('Not found', { status: 404 });
    if (url.pathname.startsWith('/api/')) return forwardApi(request, url);
    if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405 });
    return serveStatic(url);
  });
}

// ---- Validated IPC ------------------------------------------------------------------------------
type Result<T> = { ok: true; value: T } | { ok: false; error: string };

function handle<S extends z.ZodType, T>(channel: string, schema: S, fn: (args: z.infer<S>, win: BrowserWindow | null) => Promise<T> | T) {
  ipcMain.handle(channel, async (event, payload): Promise<Result<T>> => {
    if (!isAppUrl(event.senderFrame?.url)) {
      log(`[ipc] refused ${channel}: sender is not the app`);
      return { ok: false, error: 'Refused.' };
    }
    const parsed = schema.safeParse(payload);
    if (!parsed.success) {
      log(`[ipc] refused ${channel}: invalid payload`);
      return { ok: false, error: 'Invalid request.' };
    }
    try {
      return { ok: true, value: await fn(parsed.data, BrowserWindow.fromWebContents(event.sender)) };
    } catch (err) {
      const message = err instanceof CredentialError ? err.message : `Failed: ${(err as Error).message}`;
      log(`[ipc] ${channel} failed: ${err instanceof CredentialError ? 'validation' : (err as Error).message}`);
      return { ok: false, error: message };
    }
  });
}

function credentialView() {
  return { ...credentials.status(), backend: backend.current() };
}

function registerIpc() {
  handle(CHANNELS.credentialsStatus, NoArgsSchema, () => credentialView());
  handle(CHANNELS.credentialsSave, CredentialSaveSchema, async ({ provider, key }) => {
    credentials.save(provider, key);
    log(`[credentials] ${provider} key saved (${credentials.status().storage.name}); restarting the server`);
    await backend.restart();
    return credentialView();
  });
  handle(CHANNELS.credentialsClear, CredentialClearSchema, async ({ provider }) => {
    credentials.clear(provider);
    log(`[credentials] ${provider} key removed; restarting the server`);
    await backend.restart();
    return credentialView();
  });
  handle(CHANNELS.backendStatus, NoArgsSchema, () => backend.current());
  handle(CHANNELS.backendRestart, NoArgsSchema, async () => {
    log('[desktop] restart requested from the app');
    await backend.restart();
    return backend.current();
  });

  handle(CHANNELS.fileSave, FileSaveSchema, async ({ kind, suggestedName, bytes }, win) => {
    const name = safeFileName(kind, suggestedName);
    const { extension, label } = FILE_KINDS[kind];
    let target: string;
    if (e2eDir) {
      target = join(e2eDir, name);
    } else {
      const options = { defaultPath: join(app.getPath('documents'), name), filters: [{ name: label, extensions: [extension.slice(1)] }] };
      const result = win ? await dialog.showSaveDialog(win, options) : await dialog.showSaveDialog(options);
      if (result.canceled || !result.filePath) return { saved: false as const };
      target = result.filePath.toLowerCase().endsWith(extension) ? result.filePath : `${result.filePath}${extension}`;
    }
    await writeFile(target, bytes);
    log(`[files] saved ${kind} (${bytes.byteLength} bytes)`);
    return { saved: true as const, fileName: basename(target) };
  });

  handle(CHANNELS.fileOpenProject, NoArgsSchema, async (_args, win) => {
    let path: string | undefined;
    if (e2eDir) {
      path = process.env.PRESENTATION_STUDIO_E2E_OPEN || undefined;
    } else {
      const options = {
        properties: ['openFile' as const],
        filters: [{ name: FILE_KINDS.project.label, extensions: ['pstudio', 'zip'] }],
      };
      const result = win ? await dialog.showOpenDialog(win, options) : await dialog.showOpenDialog(options);
      path = result.canceled ? undefined : result.filePaths[0];
    }
    if (!path) return { opened: false as const };
    const size = statSync(path).size;
    if (size > MAX_FILE_BYTES) throw new Error('The file is larger than 1 GB.');
    const bytes = new Uint8Array(await readFile(path));
    log(`[files] opened project (${size} bytes)`);
    return { opened: true as const, fileName: basename(path), bytes };
  });
}

// ---- Window ----------------------------------------------------------------------------------
function hardenSession() {
  const ses = session.defaultSession;
  ses.setPermissionRequestHandler((wc, permission, callback, details) => {
    // Only the microphone, only for the app itself (spoken brief).
    const ok = permission === 'media' && isAppUrl(wc.getURL()) && (details as { mediaTypes?: string[] }).mediaTypes?.every((t) => t === 'audio') !== false;
    callback(ok);
  });
  ses.setPermissionCheckHandler((wc, permission) => permission === 'media' && isAppUrl(wc?.getURL()));
  ses.on('will-download', (event) => event.preventDefault()); // files go through the save dialog
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1100,
    minHeight: 700,
    show: false,
    title: 'Presentation Studio',
    backgroundColor: '#0a1630',
    webPreferences: {
      preload: join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      spellcheck: false,
      devTools: !app.isPackaged,
    },
  });
  mainWindow = win;
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => (mainWindow = null));
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//i.test(url)) void shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (event, url) => {
    if (!isAppUrl(url)) event.preventDefault();
  });
  win.webContents.on('will-attach-webview', (event) => event.preventDefault());
  win.webContents.on('will-prevent-unload', (event) => {
    const choice = dialog.showMessageBoxSync(win, {
      type: 'question',
      buttons: ['Discard changes', 'Cancel'],
      defaultId: 1,
      cancelId: 1,
      message: 'Discard unsaved changes?',
      detail: 'This project has changes that are not saved.',
    });
    if (choice === 0) event.preventDefault();
  });
  win.webContents.on('render-process-gone', (_e, details) => log(`[desktop] renderer gone: ${details.reason}`));
  void win.loadURL(`${APP_ORIGIN}/`);
  return win;
}

function buildMenu() {
  const template: MenuItemConstructorOptions[] = [
    ...(process.platform === 'darwin' ? [{ role: 'appMenu' as const }] : []),
    { role: 'fileMenu' },
    { role: 'editMenu' },
    { label: 'View', submenu: [{ role: 'togglefullscreen' }, ...(app.isPackaged ? [] : [{ role: 'toggleDevTools' as const }])] },
    { role: 'windowMenu' },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---- Lifecycle -----------------------------------------------------------------------------
app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  }
});

app.whenReady().then(async () => {
  log(`[desktop] Presentation Studio ${app.getVersion()} starting (Electron ${process.versions.electron}, ${process.platform}-${process.arch}, packaged: ${app.isPackaged})`);
  const encryptor = e2eDir && process.env.PRESENTATION_STUDIO_E2E_TEST_KEYSTORE === '1' ? e2eEncryptor : electronEncryptor;
  credentials = new CredentialStore(join(app.getPath('userData'), 'credentials.json'), encryptor);
  backend = new BackendManager({
    fork: () =>
      utilityProcess.fork(join(__dirname, 'backend.cjs'), [], {
        serviceName: 'Presentation Studio Server',
        stdio: 'pipe',
        // A clean environment: nothing from the user's shell (no .env, no proxy or provider variables).
        env: { NODE_ENV: 'production' },
      }),
    keys: () => ({ anthropic: credentials.read('anthropic'), elevenlabs: credentials.read('elevenlabs'), baseUrls: e2eBaseUrls() }),
    log,
  });
  backend.onChange((s) => {
    log(`[desktop] backend ${s.state}${s.error ? `: ${s.error}` : ''}`);
    mainWindow?.webContents.send('ps:backend:changed', s);
  });
  registerAppProtocol();
  registerIpc();
  hardenSession();
  buildMenu();
  createWindow();
  await backend.start();
  if (backend.current().state === 'failed' && mainWindow && !e2eDir) {
    const choice = await dialog.showMessageBox(mainWindow, {
      type: 'warning',
      buttons: ['Retry', 'Continue without it'],
      defaultId: 0,
      message: 'The built-in server did not start.',
      detail: `${backend.current().error ?? ''}\n\nEditing, saving and PowerPoint export still work. AI generation and voice need the server.`,
    });
    if (choice.response === 0) await backend.restart();
  }
});

let backendStopped = false;
app.on('will-quit', (event) => {
  if (backendStopped || !backend) return;
  event.preventDefault();
  void backend.stop().finally(() => {
    backendStopped = true;
    log('[desktop] backend stopped; quitting');
    app.quit();
  });
});

app.on('window-all-closed', () => app.quit());
