/**
 * Backend entry for the desktop app. Electron's main process starts this file in a separate
 * utility process (bundled Node runtime; no system Node.js needed).
 *
 * Protocol over the private parent port (never environment variables or argv, which other
 * processes of the same user could read):
 *   main → backend  { type: 'start', token, keys: { anthropic, elevenlabs } }
 *   backend → main  { type: 'ready', port } | { type: 'error', message }
 *   main → backend  { type: 'shutdown' }
 *
 * The server listens on 127.0.0.1 on a random free port and answers only requests that carry
 * the per-launch token, which only the main process knows (it adds the header when it forwards
 * renderer requests). The renderer itself never sees the token or any key.
 */
import express, { type NextFunction, type Request, type Response } from 'express';
import type { AddressInfo } from 'node:net';
import { timingSafeEqual } from 'node:crypto';
import { createApp, type AppDeps } from './app';
import { loadConfig } from './config';
import { setDesktopMode } from './hints';

export const TOKEN_HEADER = 'x-presentation-studio-token';

export interface DesktopStart {
  type: 'start';
  token: string;
  keys: {
    anthropic: string | null;
    elevenlabs: string | null;
    /** Test runs only (PRESENTATION_STUDIO_E2E_DIR): point the providers at local mock servers. */
    baseUrls?: { anthropic?: string; elevenlabs?: string };
  };
}

function sameToken(given: string | undefined, expected: Buffer): boolean {
  if (!given) return false;
  const g = Buffer.from(given);
  return g.length === expected.length && timingSafeEqual(g, expected);
}

/** Mock provider URLs are accepted only on this machine (test runs). */
function localUrl(url: string | undefined): string | undefined {
  if (!url) return undefined;
  try {
    const u = new URL(url);
    return u.protocol === 'http:' && (u.hostname === '127.0.0.1' || u.hostname === 'localhost') ? url : undefined;
  } catch {
    return undefined;
  }
}

/** Builds the token-guarded app. Exported for tests. */
export function createDesktopApp(start: DesktopStart, deps: AppDeps = {}) {
  setDesktopMode(true);
  if (typeof start.token !== 'string' || start.token.length < 32) throw new Error('A launch token of at least 32 characters is required.');
  // Only the keys come from the desktop settings. Nothing is read from .env or the environment.
  const config = loadConfig(
    {
      NODE_ENV: 'development', // the desktop shell serves the client itself; the backend serves only /api
      HOST: '127.0.0.1',
      PORT: '0',
      ANTHROPIC_API_KEY: start.keys.anthropic ?? '',
      ELEVENLABS_API_KEY: start.keys.elevenlabs ?? '',
      ELEVENLABS_BASE_URL: localUrl(start.keys.baseUrls?.elevenlabs),
    },
    { readDotenv: false },
  );
  const anthropicBase = localUrl(start.keys.baseUrls?.anthropic);
  if (anthropicBase) process.env.ANTHROPIC_BASE_URL = anthropicBase; // read by the Anthropic SDK
  const expected = Buffer.from(start.token);
  const outer = express();
  outer.disable('x-powered-by');
  outer.use((req: Request, res: Response, next: NextFunction) => {
    if (!sameToken(req.get(TOKEN_HEADER), expected)) {
      res.status(403).json({ error: { code: 'forbidden', message: 'This local server only answers Presentation Studio.', retryable: false } });
      return;
    }
    next();
  });
  outer.use(createApp(config, deps));
  return outer;
}

interface ParentPort {
  on(event: 'message', listener: (e: { data: unknown }) => void): void;
  postMessage(message: unknown): void;
}

function run(port: ParentPort) {
  let server: ReturnType<ReturnType<typeof createDesktopApp>['listen']> | null = null;
  port.on('message', ({ data }) => {
    const msg = data as { type?: string };
    if (msg?.type === 'start' && !server) {
      try {
        const app = createDesktopApp(data as DesktopStart, { log: (m) => console.log(m) });
        server = app.listen(0, '127.0.0.1', () => {
          port.postMessage({ type: 'ready', port: (server!.address() as AddressInfo).port });
        });
        server.on('error', (err) => port.postMessage({ type: 'error', message: `Server error: ${err.message}` }));
      } catch (err) {
        port.postMessage({ type: 'error', message: (err as Error).message });
      }
    } else if (msg?.type === 'shutdown') {
      if (!server) process.exit(0);
      server.close(() => process.exit(0));
      server.closeAllConnections?.();
      setTimeout(() => process.exit(0), 2000).unref();
    }
  });
}

const parentPort = (process as unknown as { parentPort?: ParentPort }).parentPort;
if (parentPort) run(parentPort);
