// Local MOCK servers that imitate the Anthropic Messages API and the ElevenLabs API.
// Used only by tests, so the whole pipeline (browser -> server -> SDK/HTTP -> provider)
// can be exercised without real keys or credits. Output is labelled "[MOCK]".
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const TONE = readFileSync(join(here, '..', 'tests', 'fixtures', 'tone.mp3'));

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}
function send(res, status, body, type = 'application/json') {
  res.writeHead(status, { 'Content-Type': type });
  res.end(type === 'application/json' ? JSON.stringify(body) : body);
}
function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`)));
}

const LAYOUTS = ['title', 'textImage', 'imageCaption', 'comparison', 'takeaway', 'closing'];

function textOf(content) {
  return (Array.isArray(content) ? content : [{ type: 'text', text: content }]).filter((b) => b.type === 'text').map((b) => b.text).join('\n');
}

function message(model, json) {
  return {
    id: `msg_mock_${Math.random().toString(36).slice(2)}`,
    type: 'message',
    role: 'assistant',
    model,
    content: [{ type: 'text', text: JSON.stringify(json) }],
    stop_reason: 'end_turn',
    stop_sequence: null,
    usage: { input_tokens: 100, output_tokens: 100 },
  };
}

export async function startMockProviders({ anthropicKey = 'test-anthropic-key', elevenKey = 'test-elevenlabs-key' } = {}) {
  const calls = { anthropic: [], eleven: [] };
  const state = { anthropicMode: 'ok' }; // 'ok' | 'invalid' | 'rate_limit'

  const anthropic = createServer(async (req, res) => {
    const body = await readBody(req);
    const url = new URL(req.url, 'http://x');
    calls.anthropic.push({ method: req.method, path: url.pathname, headers: req.headers, body: body.length ? JSON.parse(body.toString()) : null });
    // SDK 1.x sends the key as "Authorization: Bearer"; older clients use x-api-key.
    const presented = req.headers['x-api-key'] ?? (req.headers.authorization ?? '').replace(/^Bearer /, '');
    if (presented !== anthropicKey) return send(res, 401, { type: 'error', error: { type: 'authentication_error', message: 'invalid api key' } });
    if (req.method === 'GET' && url.pathname.startsWith('/v1/models/')) {
      const id = decodeURIComponent(url.pathname.split('/').pop());
      return send(res, 200, { id, type: 'model', display_name: id, created_at: '2026-01-01T00:00:00Z' });
    }
    if (req.method === 'POST' && url.pathname === '/v1/messages') {
      if (state.anthropicMode === 'rate_limit') return send(res, 429, { type: 'error', error: { type: 'rate_limit_error', message: 'slow down' } });
      const req2 = JSON.parse(body.toString());
      const system = typeof req2.system === 'string' ? req2.system : textOf(req2.system);
      const user = textOf(req2.messages[0].content);
      if (state.anthropicMode === 'invalid') {
        return send(res, 200, { ...message(req2.model, {}), content: [{ type: 'text', text: '{"not":"the schema"' }] });
      }
      if (system.startsWith('You plan slide decks')) {
        const count = Number(/<slide_count>(\d+)<\/slide_count>/.exec(user)?.[1] ?? 5);
        const topic = /<topic>([^<]*)<\/topic>/.exec(user)?.[1] ?? 'Mock deck';
        const imageIds = [...user.matchAll(/<source_image id="([^"]+)"/g)].map((m) => m[1]);
        const slides = Array.from({ length: count }, (_, i) => {
          const layout = i === 0 ? 'title' : i === count - 1 ? 'closing' : LAYOUTS[1 + ((i - 1) % 4)];
          const img = (layout === 'textImage' || layout === 'imageCaption') && imageIds.length ? [imageIds[(i - 1) % imageIds.length]] : [];
          return { layout, title: i === 0 ? `[MOCK] ${topic}` : `[MOCK] Slide ${i + 1}`, purpose: 'mock', keyPoints: ['From the brief'], imageIds: img };
        });
        return send(res, 200, message(req2.model, {
          title: `[MOCK] ${topic}`,
          slides,
          imageNotes: imageIds.map((id) => ({ imageId: id, description: 'Mock description of a synthetic image.', visibleText: '' })),
          missingInfo: ['[MOCK] No figures were provided.'],
        }));
      }
      // Slide writer
      const plan = JSON.parse(/<deck_plan>\s*([\s\S]*?)\s*<\/deck_plan>/.exec(user)?.[1] ?? '{}');
      const regenerate = /<current_slide_content>/.test(user);
      const request = /<user_request>([\s\S]*?)<\/user_request>/.exec(user)?.[1] ?? '';
      const p = plan.planned ?? { layout: 'textImage', title: 'Slide', imageIds: [] };
      const n = plan.slideNumber ?? 1;
      return send(res, 200, message(req2.model, {
        layout: p.layout,
        title: regenerate ? `[MOCK] Rewritten slide ${n}${request ? ` (${request})` : ''}` : p.title,
        body: p.layout === 'title' ? '[MOCK] Subtitle' : p.layout === 'closing' ? '[MOCK] Questions?' : '[MOCK] First point\n[MOCK] Second point',
        caption: p.layout === 'imageCaption' ? '[MOCK] Caption' : '',
        leftHeading: p.layout === 'comparison' ? '[MOCK] Option A' : '',
        leftBody: p.layout === 'comparison' ? '[MOCK] A1\n[MOCK] A2' : '',
        rightHeading: p.layout === 'comparison' ? '[MOCK] Option B' : '',
        rightBody: p.layout === 'comparison' ? '[MOCK] B1\n[MOCK] B2' : '',
        imageId: p.imageIds?.[0] ?? '',
        notes: `[MOCK] Speaker notes for slide ${n}.`,
        flags: n === 2 ? ['[MOCK] No source was given for this claim.'] : [],
      }));
    }
    send(res, 404, { type: 'error', error: { type: 'not_found_error', message: 'mock: unknown route' } });
  });

  const voices = [
    { voice_id: 'mockVoice1', name: 'Mock Voice One', category: 'premade', description: 'Calm (mock)', labels: { accent: 'neutral' } },
    { voice_id: 'mockVoice2', name: 'Mock Voice Two', category: 'premade', description: 'Bright (mock)', labels: { accent: 'british' } },
    { voice_id: 'goneVoice', name: 'Unavailable voice (mock)', category: 'cloned', description: 'Returns voice_not_found', labels: {} },
  ];
  const eleven = createServer(async (req, res) => {
    const body = await readBody(req);
    const url = new URL(req.url, 'http://x');
    const base = `http://127.0.0.1:${eleven.address().port}`;
    calls.eleven.push({ method: req.method, path: url.pathname, query: url.search, headers: req.headers, bytes: body.length, body: req.headers['content-type']?.includes('json') ? JSON.parse(body.toString()) : null });
    if (url.pathname === '/preview.mp3') return send(res, 200, TONE, 'audio/mpeg');
    if (req.headers['xi-api-key'] !== elevenKey) return send(res, 401, { detail: { status: 'invalid_api_key', message: 'Invalid API key' } });
    if (req.method === 'GET' && url.pathname === '/v2/voices') {
      return send(res, 200, { voices: voices.map((v) => ({ ...v, preview_url: `${base}/preview.mp3` })), has_more: false, next_page_token: null, total_count: voices.length });
    }
    if (req.method === 'GET' && url.pathname === '/v1/user/subscription') {
      return send(res, 200, { tier: 'mock', character_count: 1234, character_limit: 100000, next_character_count_reset_unix: 1893456000, status: 'active' });
    }
    if (req.method === 'POST' && url.pathname.startsWith('/v1/text-to-speech/')) {
      const voiceId = url.pathname.split('/').pop();
      if (voiceId === 'goneVoice') return send(res, 404, { detail: { status: 'voice_not_found', message: 'A voice with that id was not found.' } });
      return send(res, 200, TONE, 'audio/mpeg');
    }
    if (req.method === 'POST' && url.pathname === '/v1/speech-to-text') {
      const ok = body.includes(Buffer.from('name="model_id"')) && body.includes(Buffer.from('name="file"'));
      if (!ok) return send(res, 422, { detail: [{ msg: 'model_id and file are required' }] });
      return send(res, 200, { text: '[MOCK] Transcript: a pilot for short bike trips to the ferry.', language_code: 'en', language_probability: 0.99, words: [] });
    }
    send(res, 404, { detail: { status: 'not_found', message: 'mock: unknown route' } });
  });

  const anthropicUrl = await listen(anthropic);
  const elevenUrl = await listen(eleven);
  return {
    anthropicUrl,
    elevenUrl,
    calls,
    state,
    close: () => Promise.all([new Promise((r) => anthropic.close(r)), new Promise((r) => eleven.close(r))]),
  };
}
