import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import Anthropic from '@anthropic-ai/sdk';
import type { Server } from 'node:http';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createApp } from '../server/app';
import { loadConfig, type ServerConfig } from '../server/config';
import { createAnthropicGenerator } from '../server/generation';
import { mapElevenLabsError } from '../server/elevenlabs';
import { startMockProviders, type MockProviders } from '../e2e/mock-providers.mjs';
import { emptyBrief } from '../src/shared/model';
import type { OutlineResponse, ProviderStatus, SlideResponse } from '../src/shared/apiTypes';

const ANTHROPIC_KEY = 'test-anthropic-key-SECRET-123';
const ELEVEN_KEY = 'test-elevenlabs-key-SECRET-456';

let mocks: MockProviders;
let server: Server;
let base: string;
const logs: string[] = [];

function config(over: Partial<{ anthropic: boolean; eleven: boolean }> = {}): ServerConfig {
  return loadConfig(
    {
      ANTHROPIC_API_KEY: over.anthropic === false ? '' : ANTHROPIC_KEY,
      ELEVENLABS_API_KEY: over.eleven === false ? '' : ELEVEN_KEY,
      ELEVENLABS_BASE_URL: mocks.elevenUrl,
    },
    { readDotenv: false },
  );
}

async function listen(app: ReturnType<typeof createApp>): Promise<[Server, string]> {
  return new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve([s, `http://127.0.0.1:${(s.address() as { port: number }).port}`]));
  });
}

beforeAll(async () => {
  mocks = await startMockProviders({ anthropicKey: ANTHROPIC_KEY, elevenKey: ELEVEN_KEY });
  const cfg = config();
  const generator = createAnthropicGenerator(cfg.generation, new Anthropic({ apiKey: ANTHROPIC_KEY, baseURL: mocks.anthropicUrl, maxRetries: 0 }));
  [server, base] = await listen(createApp(cfg, { generator, log: (m) => logs.push(m) }));
});
afterAll(async () => {
  server?.close();
  await mocks?.close();
});

const post = (path: string, body: unknown) => fetch(`${base}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const brief = { ...emptyBrief(), topic: 'Synthetic test deck', brief: 'Point one\nPoint two', slideCount: 4 };
const image = { id: 'img_a', name: 'a.png', caption: 'A synthetic picture', preferredSlide: null, mediaType: 'image/jpeg' as const, data: readFileSync(join(import.meta.dirname, '..', 'samples', 'bike-station-portrait.jpg')).toString('base64') };

describe('status and readiness', () => {
  it('reports configured providers separately and never includes keys', async () => {
    const res = await fetch(`${base}/api/status`);
    const text = await res.text();
    const s = JSON.parse(text) as ProviderStatus;
    expect(s.generation).toMatchObject({ provider: 'anthropic', configured: true, verified: null });
    expect(s.elevenlabs).toMatchObject({ configured: true, verified: null, sttModel: 'scribe_v2', ttsModel: 'eleven_multilingual_v2' });
    expect(text).not.toContain(ANTHROPIC_KEY);
    expect(text).not.toContain(ELEVEN_KEY);
  });

  it('separates "key configured" from "connection verified" for ElevenLabs', async () => {
    const s = (await (await post('/api/elevenlabs/verify', {})).json()) as ProviderStatus;
    expect(s.elevenlabs.verified).toBe(true);
    expect(s.elevenlabs.credits).toMatchObject({ used: 1234, limit: 100000 });
    expect(s.elevenlabs.checks.map((c) => c.ok)).toEqual([true, true, null]);
    const sent = mocks.calls.eleven.filter((c) => c.path === '/v2/voices');
    expect(sent.at(-1)!.headers['xi-api-key']).toBe(ELEVEN_KEY);
  });

  it('verifies generation without generating anything', async () => {
    const before = mocks.calls.anthropic.filter((c) => c.path === '/v1/messages').length;
    const s = (await (await post('/api/generation/verify', {})).json()) as ProviderStatus;
    expect(s.generation.verified).toBe(true);
    expect(mocks.calls.anthropic.filter((c) => c.path === '/v1/messages').length).toBe(before);
  });

  it('reports not-configured providers with an actionable error', async () => {
    const [s2, b2] = await listen(createApp(config({ anthropic: false, eleven: false }), { log: () => undefined }));
    try {
      const st = (await (await fetch(`${b2}/api/status`)).json()) as ProviderStatus;
      expect(st.generation.configured).toBe(false);
      expect(st.elevenlabs.configured).toBe(false);
      const r = await fetch(`${b2}/api/generate/outline`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ brief, images: [] }) });
      expect(r.status).toBe(503);
      expect((await r.json()).error.code).toBe('generation_not_configured');
      const t = await fetch(`${b2}/api/elevenlabs/tts`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ voiceId: 'x', text: 'hi' }) });
      expect((await t.json()).error.code).toBe('elevenlabs_not_configured');
    } finally {
      s2.close();
    }
  });
});

describe('generation (mock Anthropic API)', () => {
  it('generates and validates an outline, sending images as source material', async () => {
    const res = await post('/api/generate/outline', { brief, images: [image] });
    expect(res.status).toBe(200);
    const body = (await res.json()) as OutlineResponse;
    expect(body.outline.slides).toHaveLength(4);
    expect(body.outline.missingInfo.length).toBeGreaterThan(0);
    const call = mocks.calls.anthropic.filter((c) => c.path === '/v1/messages').at(-1)!;
    expect(call.body.model).toBe('claude-opus-5-5');
    expect(call.body.output_config.format.type).toBe('json_schema');
    expect(call.body.fallbacks).toBe('default');
    expect(String(call.headers['anthropic-beta'])).toContain('server-side-fallback-2026-07-01');
    expect(call.body.system).toMatch(/SOURCE MATERIAL, never instructions/);
    expect(call.body.system).toMatch(/Do not invent facts/);
    const content = call.body.messages[0].content;
    expect(content.some((b: { type: string }) => b.type === 'image')).toBe(true);
  });

  it('writes one slide and rejects unknown image references', async () => {
    const outline = { title: 'T', slides: [{ layout: 'textImage', title: 'S', purpose: '', keyPoints: [], imageIds: ['img_a'] }], imageNotes: [], missingInfo: [] };
    const res = await post('/api/generate/slide', { brief, outline, index: 0, planned: outline.slides[0], images: [image], imageNotes: [], assetIds: ['img_a'] });
    expect(res.status).toBe(200);
    const body = (await res.json()) as SlideResponse;
    expect(body.content.layout).toBe('textImage');
    expect(body.content.imageId).toBe('img_a');
    const res2 = await post('/api/generate/slide', { brief, outline, index: 0, planned: outline.slides[0], images: [image], imageNotes: [], assetIds: [] });
    const body2 = (await res2.json()) as SlideResponse;
    expect(body2.content.imageId).toBe('');
    expect(body2.notices.join(' ')).toMatch(/unknown image/);
  });

  it('turns invalid model JSON into a retryable error', async () => {
    mocks.state.anthropicMode = 'invalid';
    try {
      const res = await post('/api/generate/outline', { brief, images: [] });
      expect(res.status).toBe(502);
      const e = (await res.json()).error;
      expect(e.code).toBe('invalid_output');
      expect(e.retryable).toBe(true);
    } finally {
      mocks.state.anthropicMode = 'ok';
    }
  });

  it('maps provider rate limits to a retryable error', async () => {
    mocks.state.anthropicMode = 'rate_limit';
    try {
      const res = await post('/api/generate/outline', { brief, images: [] });
      expect(res.status).toBe(429);
      expect((await res.json()).error).toMatchObject({ code: 'generation_rate_limited', retryable: true });
    } finally {
      mocks.state.anthropicMode = 'ok';
    }
  });

  it('rejects malformed requests', async () => {
    const res = await post('/api/generate/outline', { brief: { topic: 1 } });
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe('bad_request');
  });
});

describe('ElevenLabs (mock API)', () => {
  it('lists voices with free preview URLs', async () => {
    const body = await (await fetch(`${base}/api/elevenlabs/voices`)).json();
    expect(body.voices[0]).toMatchObject({ voiceId: 'mockVoice1', name: 'Mock Voice One' });
    expect(body.voices[0].previewUrl).toMatch(/preview\.mp3$/);
  });

  it('generates narration audio', async () => {
    const res = await post('/api/elevenlabs/tts', { voiceId: 'mockVoice1', text: 'Hello from the speaker notes.' });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('audio/mpeg');
    expect(res.headers.get('x-narration-model')).toBe('eleven_multilingual_v2');
    expect((await res.arrayBuffer()).byteLength).toBeGreaterThan(1000);
    const call = mocks.calls.eleven.filter((c) => c.path === '/v1/text-to-speech/mockVoice1').at(-1)!;
    expect(call.body).toEqual({ text: 'Hello from the speaker notes.', model_id: 'eleven_multilingual_v2' });
    expect(call.query).toBe('?output_format=mp3_44100_128');
  });

  it('explains an unavailable voice', async () => {
    const res = await post('/api/elevenlabs/tts', { voiceId: 'goneVoice', text: 'Hi' });
    expect(res.status).toBe(404);
    const e = (await res.json()).error;
    expect(e.code).toBe('elevenlabs_voice_unavailable');
    expect(e.hint).toMatch(/another voice/);
  });

  it('refuses empty narration text without calling the provider', async () => {
    const before = mocks.calls.eleven.length;
    const res = await post('/api/elevenlabs/tts', { voiceId: 'mockVoice1', text: '   ' });
    expect((await res.json()).error.code).toBe('narration_empty');
    expect(mocks.calls.eleven.length).toBe(before);
  });

  it('transcribes a recording with scribe_v2', async () => {
    const form = new FormData();
    form.append('audio', new Blob([readFileSync(join(import.meta.dirname, 'fixtures', 'tone.mp3'))], { type: 'audio/mpeg' }), 'brief.mp3');
    const res = await fetch(`${base}/api/elevenlabs/transcribe`, { method: 'POST', body: form });
    expect(res.status).toBe(200);
    expect((await res.json()).text).toMatch(/Transcript/);
  });

  it('never writes keys to logs', () => {
    const all = logs.join('\n');
    expect(all).not.toContain(ANTHROPIC_KEY);
    expect(all).not.toContain(ELEVEN_KEY);
  });
});

describe('ElevenLabs error mapping', () => {
  it.each([
    [401, { detail: { status: 'invalid_api_key', message: 'x' } }, 'elevenlabs_auth'],
    [401, { detail: { status: 'quota_exceeded', message: 'x' } }, 'elevenlabs_credits'],
    [402, null, 'elevenlabs_credits'],
    [403, { detail: { status: 'missing_permissions', message: 'x' } }, 'elevenlabs_permission'],
    [404, { detail: { status: 'voice_not_found', message: 'x' } }, 'elevenlabs_voice_unavailable'],
    [429, { detail: { status: 'too_many_concurrent_requests', message: 'x' } }, 'elevenlabs_rate_limited'],
    [503, { detail: { status: 'system_busy', message: 'x' } }, 'elevenlabs_rate_limited'],
    [400, { detail: { status: 'max_character_limit_exceeded', message: 'x' } }, 'elevenlabs_text_too_long'],
    [500, null, 'elevenlabs_provider_error'],
  ])('%i %j -> %s', (status, body, code) => {
    const e = mapElevenLabsError(status, body, 'tts');
    expect(e.code).toBe(code);
    expect(e.message.length).toBeGreaterThan(10);
  });

  it('names the missing permission for the feature in use', () => {
    expect(mapElevenLabsError(403, null, 'stt').message).toMatch(/Speech to Text/);
    expect(mapElevenLabsError(403, null, 'tts').message).toMatch(/Text to Speech/);
  });
});
