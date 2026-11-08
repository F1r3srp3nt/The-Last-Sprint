/**
 * Provider keys for the desktop app, encrypted with the operating system's credential store
 * (Electron safeStorage: the macOS Keychain on a Mac). Lives in the main process only; keys
 * are handed to the backend process over its private channel and never to the renderer.
 */
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export const PROVIDERS = ['anthropic', 'elevenlabs'] as const;
export type Provider = (typeof PROVIDERS)[number];

/** The parts of Electron's safeStorage the store needs (injected so tests run without Electron). */
export interface Encryptor {
  /** True only when encryption is backed by a real OS credential store. */
  secure(): boolean;
  /** Human-readable name of the backing store, e.g. "macOS Keychain". */
  backendName(): string;
  encrypt(plain: string): Buffer;
  decrypt(cipher: Buffer): string;
}

export interface CredentialStatus {
  storage: { secure: boolean; name: string };
  providers: Record<Provider, { saved: boolean }>;
}

export class CredentialError extends Error {}

/** Returns a problem with a pasted key, or null. Never echoes the key. */
export function keyProblem(provider: Provider, raw: unknown): string | null {
  if (typeof raw !== 'string') return 'The key must be text.';
  const key = raw.trim();
  if (!key) return 'Paste the key first.';
  if (key.length < 16 || key.length > 512) return 'This does not look like a complete API key. Copy the whole key.';
  if (/\s/.test(key)) return 'The pasted text contains spaces or line breaks. Copy just the key.';
  if (!/^[\x21-\x7e]+$/.test(key)) return 'The key contains unexpected characters.';
  if (provider === 'anthropic' && key.startsWith('sk_')) return 'This looks like an ElevenLabs key. Paste it under Voice · ElevenLabs instead.';
  if (provider === 'elevenlabs' && key.startsWith('sk-ant-')) return 'This looks like an Anthropic key. Paste it under Slide generation · Anthropic instead.';
  return null;
}

interface FileShape {
  version: 1;
  keys: Partial<Record<Provider, string>>; // base64 of the encrypted bytes
}

export class CredentialStore {
  constructor(
    private readonly file: string,
    private readonly encryptor: Encryptor,
  ) {}

  private load(): FileShape {
    if (!existsSync(this.file)) return { version: 1, keys: {} };
    try {
      const parsed = JSON.parse(readFileSync(this.file, 'utf8')) as FileShape;
      if (parsed?.version !== 1 || typeof parsed.keys !== 'object' || parsed.keys === null) return { version: 1, keys: {} };
      return parsed;
    } catch {
      return { version: 1, keys: {} };
    }
  }

  private write(data: FileShape) {
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
    renameSync(tmp, this.file);
    try {
      chmodSync(this.file, 0o600);
    } catch {
      /* best effort on filesystems without modes */
    }
  }

  status(): CredentialStatus {
    const data = this.load();
    const providers = Object.fromEntries(PROVIDERS.map((p) => [p, { saved: typeof data.keys[p] === 'string' }])) as CredentialStatus['providers'];
    return { storage: { secure: this.encryptor.secure(), name: this.encryptor.backendName() }, providers };
  }

  /** Decrypted key, or null when none is saved or it can no longer be decrypted. */
  read(provider: Provider): string | null {
    const stored = this.load().keys[provider];
    if (typeof stored !== 'string' || !this.encryptor.secure()) return null;
    try {
      return this.encryptor.decrypt(Buffer.from(stored, 'base64'));
    } catch {
      return null;
    }
  }

  save(provider: Provider, raw: unknown): void {
    const problem = keyProblem(provider, raw);
    if (problem) throw new CredentialError(problem);
    if (!this.encryptor.secure()) {
      throw new CredentialError(`Keys can only be saved when the system credential store is available (${this.encryptor.backendName()}). Nothing was saved.`);
    }
    const data = this.load();
    data.keys[provider] = this.encryptor.encrypt((raw as string).trim()).toString('base64');
    this.write(data);
  }

  clear(provider: Provider): void {
    const data = this.load();
    delete data.keys[provider];
    this.write(data);
  }
}
