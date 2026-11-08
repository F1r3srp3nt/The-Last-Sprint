// Desktop shell modules that run without Electron: credential storage, IPC validation, the
// backend lifecycle manager and the token-guarded backend. The packaged app itself is tested
// by e2e/run-desktop-e2e.mjs.
import { afterEach, describe, expect, it } from 'vitest';
import { EventEmitter } from 'node:events';
import type { Server } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CredentialError, CredentialStore, keyProblem, type Encryptor } from '../desktop/credentials';
import { CredentialSaveSchema, FileSaveSchema, isAppUrl, safeFileName, staticPath } from '../desktop/ipc';
import { BackendManager, type ChildProcessLike } from '../desktop/backend';
import { createDesktopApp, TOKEN_HEADER } from '../server/desktop';
import { keyHint, setDesktopMode } from '../server/hints';

const ANTHROPIC = 'test-anthropic-key-SECRET-123';
const ELEVEN = 'test-elevenlabs-key-SECRET-456';

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
  setDesktopMode(false);
});
function tempFile() {
  const d = mkdtempSync(join(tmpdir(), 'ps-cred-'));
  dirs.push(d);
  return join(d, 'credentials.json');
}
/** Reversible stand-in for safeStorage; the stored bytes never contain the key. */
const fakeEncryptor = (secure = true): Encryptor => ({
  secure: () => secure,
  backendName: () => 'Fake keychain',
  encrypt: (s) => Buffer.from([...Buffer.from(s)].map((b) => b ^ 0x5a)),
  decrypt: (b) => Buffer.from([...b].map((x) => x ^ 0x5a)).toString(),
});

describe('credential store', () => {
  it('saves, reads, replaces and clears keys per provider, encrypted on disk', () => {
    const file = tempFile();
    const store = new CredentialStore(file, fakeEncryptor());
    expect(store.status().providers).toEqual({ anthropic: { saved: false }, elevenlabs: { saved: false } });
    store.save('anthropic', `  ${ANTHROPIC}\n`);
    store.save('elevenlabs', ELEVEN);
    expect(store.read('anthropic')).toBe(ANTHROPIC);
    expect(store.read('elevenlabs')).toBe(ELEVEN);
    const raw = readFileSync(file, 'utf8');
    expect(raw).not.toContain(ANTHROPIC);
    expect(raw).not.toContain(ELEVEN);
    if (process.platform !== 'win32') expect(statSync(file).mode & 0o777).toBe(0o600);
    store.save('elevenlabs', `${ELEVEN}-new`);
    expect(store.read('elevenlabs')).toBe(`${ELEVEN}-new`);
    store.clear('elevenlabs');
    expect(store.read('elevenlabs')).toBeNull();
    expect(store.read('anthropic')).toBe(ANTHROPIC);
    expect(store.status().providers.elevenlabs.saved).toBe(false);
  });

  it('refuses to save without a secure OS store and never falls back to plain text', () => {
    const file = tempFile();
    const store = new CredentialStore(file, fakeEncryptor(false));
    expect(() => store.save('anthropic', ANTHROPIC)).toThrow(CredentialError);
    expect(() => readFileSync(file)).toThrow();
    expect(store.status().storage).toEqual({ secure: false, name: 'Fake keychain' });
  });

  it('validates pasted keys without echoing them', () => {
    expect(keyProblem('anthropic', ANTHROPIC)).toBeNull();
    for (const bad of ['', 'short', `${ANTHROPIC} extra`, `${ANTHROPIC}é`, 42]) {
      const p = keyProblem('anthropic', bad);
      expect(p).toBeTruthy();
      expect(p).not.toContain(ANTHROPIC);
    }
    expect(keyProblem('anthropic', 'sk_0123456789abcdef0123')).toMatch(/ElevenLabs key/);
    expect(keyProblem('elevenlabs', 'sk-ant-0123456789abcdef')).toMatch(/Anthropic key/);
  });

  it('treats a corrupt file or undecryptable entry as "not saved"', () => {
    const file = tempFile();
    const store = new CredentialStore(file, { ...fakeEncryptor(), decrypt: () => { throw new Error('locked'); } });
    store.save('anthropic', ANTHROPIC);
    expect(store.read('anthropic')).toBeNull();
  });
});

describe('IPC validation', () => {
  it('accepts only the documented shapes', () => {
    expect(CredentialSaveSchema.safeParse({ provider: 'anthropic', key: 'x' }).success).toBe(true);
    expect(CredentialSaveSchema.safeParse({ provider: 'openai', key: 'x' }).success).toBe(false);
    expect(CredentialSaveSchema.safeParse({ provider: 'anthropic', key: 'x', extra: 1 }).success).toBe(false);
    expect(FileSaveSchema.safeParse({ kind: 'pptx', suggestedName: 'a', bytes: new Uint8Array([1]) }).success).toBe(true);
    expect(FileSaveSchema.safeParse({ kind: 'exe', suggestedName: 'a', bytes: new Uint8Array([1]) }).success).toBe(false);
    expect(FileSaveSchema.safeParse({ kind: 'pptx', suggestedName: 'a', bytes: new Uint8Array() }).success).toBe(false);
    expect(FileSaveSchema.safeParse({ kind: 'pptx', suggestedName: 'a', bytes: 'not bytes' }).success).toBe(false);
  });

  it('makes safe file names with the right extension', () => {
    expect(safeFileName('pptx', 'deck.pptx')).toBe('deck.pptx');
    expect(safeFileName('project', '../../etc/passwd')).toBe('-..-etc-passwd.pstudio');
    expect(safeFileName('zip', 'a/b\\c:d*e?f"g<h>i|j\u0001')).toBe('a-b-c-d-e-f-g-h-i-j-.zip');
    expect(safeFileName('project', '   ')).toBe('presentation.pstudio');
    expect(safeFileName('project', '.hidden')).toBe('hidden.pstudio');
  });

  it('serves only app://studio paths inside dist', () => {
    expect(isAppUrl('app://studio/')).toBe(true);
    expect(isAppUrl('app://studio/assets/x.js')).toBe(true);
    for (const u of ['app://other/', 'https://studio/', 'file:///etc/passwd', '', null, 'not a url']) expect(isAppUrl(u)).toBe(false);
    expect(staticPath('/')).toBe('index.html');
    expect(staticPath('/assets/index.js')).toBe('assets/index.js');
    expect(staticPath('/../package.json')).toBeNull();
    expect(staticPath('/assets/%2e%2e/%2e%2e/secret')).toBeNull();
    expect(staticPath('/%E0%A4%A')).toBeNull();
  });
});

class FakeChild extends EventEmitter implements ChildProcessLike {
  sent: unknown[] = [];
  killed = false;
  constructor(private readonly behaviour: 'ready' | 'error' | 'silent' | 'crash-after-ready') {
    super();
  }
  postMessage(message: unknown) {
    this.sent.push(message);
    const type = (message as { type: string }).type;
    if (type === 'start') {
      queueMicrotask(() => {
        if (this.behaviour === 'ready' || this.behaviour === 'crash-after-ready') this.emit('message', { type: 'ready', port: 43210 });
        if (this.behaviour === 'error') this.emit('message', { type: 'error', message: 'port in use' });
        if (this.behaviour === 'crash-after-ready') setTimeout(() => this.emit('exit', 1), 5);
      });
    } else if (type === 'shutdown') {
      queueMicrotask(() => this.emit('exit', 0));
    }
  }
  kill() {
    this.killed = true;
    queueMicrotask(() => this.emit('exit', 9));
    return true;
  }
}

describe('backend manager', () => {
  const keys = () => ({ anthropic: ANTHROPIC, elevenlabs: null });

  it('starts, reports ready with a fresh token, and stops cleanly', async () => {
    const children: FakeChild[] = [];
    const logs: string[] = [];
    const m = new BackendManager({ fork: () => (children.push(new FakeChild('ready')), children.at(-1)!), keys, log: (l) => logs.push(l) });
    const ep = await m.ready();
    expect(ep?.url).toBe('http://127.0.0.1:43210');
    expect(ep?.token).toMatch(/^[0-9a-f]{64}$/);
    expect(children[0].sent[0]).toEqual({ type: 'start', token: ep!.token, keys: { anthropic: ANTHROPIC, elevenlabs: null } });
    await m.restart();
    expect(m.endpoint()?.token).not.toBe(ep!.token);
    expect(children).toHaveLength(2);
    await m.stop();
    expect(m.current().state).toBe('stopped');
    expect(children[1].sent.at(-1)).toEqual({ type: 'shutdown' });
    expect(logs.join('\n')).not.toContain(ANTHROPIC);
  });

  it('reports start errors and timeouts as failed, with a plain message', async () => {
    const failing = new BackendManager({ fork: () => new FakeChild('error'), keys, log: () => {} });
    await failing.start();
    expect(failing.current()).toMatchObject({ state: 'failed', error: expect.stringContaining('port in use') });
    expect(failing.endpoint()).toBeNull();

    const child = new FakeChild('silent');
    const slow = new BackendManager({ fork: () => child, keys, log: () => {}, startTimeoutMs: 30 });
    await slow.start();
    expect(slow.current()).toMatchObject({ state: 'failed', error: 'The built-in server did not start in time.' });
    expect(child.killed).toBe(true);
  });

  it('restarts after an unexpected exit, then gives up', async () => {
    let forks = 0;
    const m = new BackendManager({ fork: () => (forks++, new FakeChild('crash-after-ready')), keys, log: () => {}, maxAutoRestarts: 2 });
    await m.start();
    await new Promise((r) => setTimeout(r, 100));
    expect(forks).toBe(3);
    expect(m.current().state).toBe('failed');
    expect(m.current().error).toMatch(/stopped unexpectedly/);
  });
});

describe('desktop backend', () => {
  let server: Server | null = null;
  afterEach(() => server?.close());

  async function start(token: string) {
    const app = createDesktopApp({ type: 'start', token, keys: { anthropic: null, elevenlabs: ELEVEN } }, { log: () => {} });
    return new Promise<string>((resolve) => {
      server = app.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${(server!.address() as { port: number }).port}`));
    });
  }

  it('answers only requests that carry the launch token', async () => {
    const token = 'a'.repeat(64);
    const base = await start(token);
    expect((await fetch(`${base}/api/status`)).status).toBe(403);
    expect((await fetch(`${base}/api/status`, { headers: { [TOKEN_HEADER]: 'b'.repeat(64) } })).status).toBe(403);
    expect((await fetch(`${base}/api/status`, { headers: { [TOKEN_HEADER]: 'short' } })).status).toBe(403);
    const ok = await fetch(`${base}/api/status`, { headers: { [TOKEN_HEADER]: token } });
    expect(ok.status).toBe(200);
    const body = await ok.text();
    expect(JSON.parse(body).elevenlabs.configured).toBe(true);
    expect(body).not.toContain(ELEVEN);
    // The desktop backend serves no static files: the shell serves the client from the app bundle.
    expect((await fetch(`${base}/`, { headers: { [TOKEN_HEADER]: token } })).status).toBe(404);
  });

  it('rejects a weak token and points key hints at Setup', async () => {
    expect(() => createDesktopApp({ type: 'start', token: 'short', keys: { anthropic: null, elevenlabs: null } })).toThrow(/token/);
    const base = await start('c'.repeat(64));
    const res = await fetch(`${base}/api/generation/verify`, { method: 'POST', headers: { [TOKEN_HEADER]: 'c'.repeat(64) } });
    expect(res.status).toBe(503);
    const err = (await res.json()).error;
    expect(err.hint).toMatch(/Setup/);
    expect(err.hint).not.toMatch(/\.env/);
  });

  it('keeps the .env hint for the web version', () => {
    setDesktopMode(false);
    expect(keyHint('ANTHROPIC_API_KEY', 'add')).toMatch(/presentation-studio\/\.env/);
    setDesktopMode(true);
    expect(keyHint('ANTHROPIC_API_KEY', 'add')).toMatch(/Setup/);
  });
});
