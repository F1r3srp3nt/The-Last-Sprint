/**
 * Starts, watches and stops the bundled backend (server/desktop.ts) in an Electron utility
 * process. The utility process uses Electron's own Node runtime, so the user needs no Node.js.
 */
import { randomBytes } from 'node:crypto';

export type BackendState = 'stopped' | 'starting' | 'ready' | 'failed';

export interface BackendStatus {
  state: BackendState;
  /** Plain-language reason when state is "failed". */
  error: string | null;
  restarts: number;
}

/** The parts of Electron's UtilityProcess this manager uses (injected for tests). */
export interface ChildProcessLike {
  postMessage(message: unknown): void;
  kill(): boolean;
  on(event: 'message', listener: (message: unknown) => void): this;
  on(event: 'exit', listener: (code: number) => void): this;
  stdout?: NodeJS.ReadableStream | null;
  stderr?: NodeJS.ReadableStream | null;
}

export interface BackendOptions {
  fork: () => ChildProcessLike;
  /** Sent to the backend over its private channel when it starts. */
  keys: () => { anthropic: string | null; elevenlabs: string | null; baseUrls?: { anthropic?: string; elevenlabs?: string } };
  log: (line: string) => void;
  startTimeoutMs?: number;
  stopTimeoutMs?: number;
  /** Automatic restarts after an unexpected exit, before giving up. */
  maxAutoRestarts?: number;
}

export class BackendManager {
  private child: ChildProcessLike | null = null;
  private port: number | null = null;
  private token = '';
  private status: BackendStatus = { state: 'stopped', error: null, restarts: 0 };
  private starting: Promise<void> | null = null;
  private stopping = false;
  private listeners = new Set<(s: BackendStatus) => void>();

  constructor(private readonly opts: BackendOptions) {}

  onChange(listener: (s: BackendStatus) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  current(): BackendStatus {
    return { ...this.status };
  }

  /** Base URL and token for forwarding requests, or null when not ready. */
  endpoint(): { url: string; token: string } | null {
    return this.status.state === 'ready' && this.port ? { url: `http://127.0.0.1:${this.port}`, token: this.token } : null;
  }

  private set(next: Partial<BackendStatus>) {
    this.status = { ...this.status, ...next };
    for (const l of this.listeners) l(this.current());
  }

  /** Starts the backend if needed and resolves when it is ready (or has failed). */
  start(): Promise<void> {
    if (this.status.state === 'ready') return Promise.resolve();
    if (!this.starting) this.starting = this.launch().finally(() => (this.starting = null));
    return this.starting;
  }

  /** Waits for readiness; returns the endpoint or null if the backend could not start. */
  async ready(): Promise<{ url: string; token: string } | null> {
    if (this.status.state !== 'ready') await this.start();
    return this.endpoint();
  }

  private launch(): Promise<void> {
    this.set({ state: 'starting', error: null });
    this.token = randomBytes(32).toString('hex');
    this.port = null;
    const child = this.opts.fork();
    this.child = child;
    const pipe = (stream: NodeJS.ReadableStream | null | undefined, label: string) =>
      stream?.on('data', (d: Buffer) => String(d).split(/\r?\n/).filter(Boolean).forEach((line) => this.opts.log(`[backend${label}] ${line}`)));
    pipe(child.stdout, '');
    pipe(child.stderr, ':err');

    return new Promise<void>((resolve) => {
      let settled = false;
      const settle = (next: Partial<BackendStatus>) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.set(next);
        resolve();
      };
      /** Stops this child on purpose: its exit is then not treated as a crash. */
      const discard = () => {
        if (this.child === child) {
          this.child = null;
          this.port = null;
        }
        child.kill();
      };
      const timer = setTimeout(() => {
        this.opts.log('[desktop] backend did not report ready in time; stopping it');
        settle({ state: 'failed', error: 'The built-in server did not start in time.' });
        discard();
      }, this.opts.startTimeoutMs ?? 20_000);

      child.on('message', (raw) => {
        const msg = raw as { type?: string; port?: unknown; message?: unknown };
        if (msg?.type === 'ready' && typeof msg.port === 'number' && Number.isInteger(msg.port) && msg.port > 0 && msg.port < 65536) {
          this.port = msg.port;
          this.opts.log(`[desktop] backend ready on 127.0.0.1:${msg.port}`);
          settle({ state: 'ready', error: null });
        } else if (msg?.type === 'error') {
          const text = typeof msg.message === 'string' ? msg.message.slice(0, 300) : 'unknown error';
          this.opts.log(`[desktop] backend reported an error: ${text}`);
          settle({ state: 'failed', error: `The built-in server could not start: ${text}` });
          discard();
        }
      });
      child.on('exit', (code) => {
        const wasCurrent = this.child === child;
        if (wasCurrent) {
          this.child = null;
          this.port = null;
        }
        if (!settled) {
          settle({ state: 'failed', error: `The built-in server stopped while starting (exit code ${code}).` });
          return;
        }
        if (!wasCurrent || this.stopping) return;
        this.opts.log(`[desktop] backend exited unexpectedly (code ${code})`);
        if (this.status.restarts < (this.opts.maxAutoRestarts ?? 2)) {
          this.set({ state: 'stopped', restarts: this.status.restarts + 1 });
          void this.start();
        } else {
          this.set({ state: 'failed', error: `The built-in server stopped unexpectedly (exit code ${code}).` });
        }
      });

      child.postMessage({ type: 'start', token: this.token, keys: this.opts.keys() });
    });
  }

  /** Stops the backend and waits for it to exit (killing it after a timeout). */
  async stop(): Promise<void> {
    const child = this.child;
    this.stopping = true;
    try {
      if (this.starting) await this.starting;
      if (!child && !this.child) return;
      const target = this.child ?? child!;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          target.kill();
          resolve();
        }, this.opts.stopTimeoutMs ?? 3000);
        target.on('exit', () => {
          clearTimeout(timer);
          resolve();
        });
        try {
          target.postMessage({ type: 'shutdown' });
        } catch {
          target.kill();
        }
      });
      this.child = null;
      this.port = null;
      this.set({ state: 'stopped' });
    } finally {
      this.stopping = false;
    }
  }

  /** Stops and starts again, e.g. after a key change. */
  async restart(): Promise<void> {
    await this.stop();
    this.set({ restarts: 0 });
    await this.start();
  }
}
