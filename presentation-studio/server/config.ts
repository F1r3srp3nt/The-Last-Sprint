/**
 * Server configuration from environment variables (.env in presentation-studio/).
 * Keys stay in this process. They are never sent to the browser, written to
 * project files or exports, or logged.
 */
import { config as loadDotenv } from 'dotenv';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

export interface ServerConfig {
  port: number;
  host: string;
  production: boolean;
  rootDir: string;
  generation: {
    provider: 'anthropic' | 'none';
    apiKey: string | null;
    model: string;
    effort: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
    refusalFallback: boolean;
  };
  elevenlabs: {
    apiKey: string | null;
    baseUrl: string;
    ttsModel: string;
    sttModel: string;
  };
}

function clean(v: string | undefined): string | null {
  const s = (v ?? '').trim();
  if (!s || /^(your|replace|changeme|xxx|<)/i.test(s)) return null;
  return s;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env, opts: { readDotenv?: boolean } = {}): ServerConfig {
  if (opts.readDotenv !== false) loadDotenv({ path: join(root, '.env'), quiet: true });
  const anthropicKey = clean(env.ANTHROPIC_API_KEY);
  const requested = (env.GENERATION_PROVIDER ?? '').trim().toLowerCase();
  const provider: 'anthropic' | 'none' = requested === 'none' ? 'none' : anthropicKey ? 'anthropic' : 'none';
  const effort = (env.ANTHROPIC_EFFORT ?? 'medium').trim() as ServerConfig['generation']['effort'];
  return {
    port: Number(env.PORT ?? 8787),
    host: env.HOST ?? '127.0.0.1',
    production: env.NODE_ENV === 'production',
    rootDir: root,
    generation: {
      provider,
      apiKey: provider === 'anthropic' ? anthropicKey : null,
      model: (env.ANTHROPIC_MODEL ?? '').trim() || 'claude-opus-5-5',
      effort: ['low', 'medium', 'high', 'xhigh', 'max'].includes(effort) ? effort : 'medium',
      refusalFallback: (env.ANTHROPIC_REFUSAL_FALLBACK ?? 'default').trim().toLowerCase() !== 'off',
    },
    elevenlabs: {
      apiKey: clean(env.ELEVENLABS_API_KEY),
      baseUrl: ((env.ELEVENLABS_BASE_URL ?? '').trim() || 'https://api.elevenlabs.io').replace(/\/+$/, ''),
      ttsModel: (env.ELEVENLABS_TTS_MODEL ?? '').trim() || 'eleven_multilingual_v2',
      sttModel: (env.ELEVENLABS_STT_MODEL ?? '').trim() || 'scribe_v2',
    },
  };
}
