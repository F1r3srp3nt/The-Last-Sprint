/**
 * ElevenLabs REST client (speech-to-text and text-to-speech).
 * Endpoints (checked against elevenlabs.io/docs, November 2026):
 *   GET  /v2/voices                     list voices (preview_url is free to play)
 *   GET  /v1/user/subscription          character usage / limit
 *   POST /v1/speech-to-text             multipart: model_id (scribe_v2), file, language_code
 *   POST /v1/text-to-speech/{voice_id}  JSON: text, model_id; ?output_format=mp3_44100_128
 * Auth header: xi-api-key. The key is only read here and is never logged or returned.
 */
import type { ServerConfig } from './config';
import { ApiError } from './errors';
import type { Voice } from '../src/shared/apiTypes';
import { keyHint } from './hints';

export type FetchLike = typeof fetch;

const KEYS_URL = 'https://elevenlabs.io/app/settings/api-keys';
const VOICES_URL = 'https://elevenlabs.io/app/voice-library';
const BILLING_URL = 'https://elevenlabs.io/app/subscription';

/** Characters allowed per request, from the ElevenLabs models page. */
export const TTS_CHAR_LIMITS: Record<string, number> = {
  eleven_v4: 10000,
  eleven_v3: 5000,
  eleven_multilingual_v2: 10000,
  eleven_flash_v2_5: 40000,
  eleven_flash_v2: 30000,
};

function detailOf(body: unknown): { status: string; message: string } {
  const b = body as { detail?: unknown } | null;
  const d = b?.detail;
  if (d && typeof d === 'object' && !Array.isArray(d)) {
    const o = d as Record<string, unknown>;
    return { status: String(o.status ?? o.code ?? o.type ?? ''), message: String(o.message ?? '') };
  }
  if (typeof d === 'string') return { status: '', message: d };
  if (Array.isArray(d)) return { status: 'validation_error', message: d.map((x) => (x as { msg?: string }).msg ?? '').join('; ') };
  return { status: '', message: '' };
}

/** Maps an ElevenLabs error response to a user-facing error with a next step. */
export function mapElevenLabsError(httpStatus: number, body: unknown, context: 'voices' | 'tts' | 'stt' | 'subscription'): ApiError {
  const { status, message } = detailOf(body);
  const s = status.toLowerCase();
  const m = message.toLowerCase();
  const permissionFor: Record<typeof context, string> = {
    voices: 'Voices (read)',
    tts: 'Text to Speech',
    stt: 'Speech to Text',
    subscription: 'User (read)',
  };
  if (s.includes('quota') || s.includes('credit') || m.includes('quota') || m.includes('credits') || httpStatus === 402) {
    return new ApiError(402, 'elevenlabs_credits', 'Your ElevenLabs credits are used up for this billing period (or the key\'s credit limit was reached).', false, `Check usage at ${BILLING_URL}, or raise the key's credit limit at ${KEYS_URL}.`);
  }
  if (s.includes('permission') || httpStatus === 403) {
    return new ApiError(403, 'elevenlabs_permission', `The ElevenLabs API key does not have the "${permissionFor[context]}" permission.`, false, `Edit the key's permissions at ${KEYS_URL}, then click "Verify connection" again.`);
  }
  if (httpStatus === 401) {
    return new ApiError(401, 'elevenlabs_auth', 'ElevenLabs rejected the API key (invalid, disabled or expired).', false, `Create a new key at ${KEYS_URL}. ${keyHint('ELEVENLABS_API_KEY', 'replace')}`);
  }
  if (s.includes('voice_not_found') || (httpStatus === 404 && context === 'tts')) {
    return new ApiError(404, 'elevenlabs_voice_unavailable', 'The selected voice is not available to this account.', false, `Pick another voice from the list, or add it to "My Voices" at ${VOICES_URL}.`);
  }
  if (httpStatus === 429 || s.includes('too_many') || s.includes('rate') || s.includes('system_busy')) {
    return new ApiError(429, 'elevenlabs_rate_limited', 'ElevenLabs is busy or the plan\'s concurrent request limit was reached.', true, 'Wait a few seconds and retry. Deck narration runs one slide at a time.');
  }
  if (s.includes('max_character') || m.includes('character limit')) {
    return new ApiError(400, 'elevenlabs_text_too_long', 'The speaker notes are too long for one narration request.', false, 'Shorten the speaker notes for this slide.');
  }
  if (httpStatus === 400 || httpStatus === 422) {
    return new ApiError(400, 'elevenlabs_bad_request', `ElevenLabs could not process the request${message ? `: ${message}` : '.'}`, false, context === 'stt' ? 'Try recording again; very short or silent recordings cannot be transcribed.' : undefined);
  }
  return new ApiError(502, 'elevenlabs_provider_error', `ElevenLabs returned an error (${httpStatus}).`, true, 'This is usually temporary. Retry in a moment.');
}

export class ElevenLabsClient {
  constructor(
    private cfg: ServerConfig['elevenlabs'],
    private fetchImpl: FetchLike = fetch,
  ) {}

  get configured() {
    return Boolean(this.cfg.apiKey);
  }

  private async request(path: string, init: RequestInit, context: 'voices' | 'tts' | 'stt' | 'subscription'): Promise<Response> {
    if (!this.cfg.apiKey) {
      throw new ApiError(503, 'elevenlabs_not_configured', 'ElevenLabs is not configured.', false, keyHint('ELEVENLABS_API_KEY', 'add'));
    }
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.cfg.baseUrl}${path}`, {
        ...init,
        headers: { ...(init.headers as Record<string, string> | undefined), 'xi-api-key': this.cfg.apiKey },
        signal: AbortSignal.timeout(context === 'tts' || context === 'stt' ? 120_000 : 20_000),
      });
    } catch (err) {
      const timeout = err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError');
      throw new ApiError(502, 'elevenlabs_network', timeout ? 'ElevenLabs did not respond in time.' : 'Could not reach ElevenLabs.', true, 'Check your internet connection and retry.');
    }
    if (!res.ok) {
      let body: unknown = null;
      try {
        body = await res.json();
      } catch {
        /* non-JSON error body */
      }
      throw mapElevenLabsError(res.status, body, context);
    }
    return res;
  }

  async listVoices(): Promise<Voice[]> {
    const voices: Voice[] = [];
    let token: string | null = null;
    for (let page = 0; page < 5; page++) {
      const qs = new URLSearchParams({ page_size: '100' });
      if (token) qs.set('next_page_token', token);
      const res = await this.request(`/v2/voices?${qs}`, { method: 'GET' }, 'voices');
      const json = (await res.json()) as {
        voices?: { voice_id: string; name?: string; category?: string; description?: string | null; preview_url?: string | null; labels?: Record<string, string> | null }[];
        has_more?: boolean;
        next_page_token?: string | null;
      };
      for (const v of json.voices ?? []) {
        voices.push({
          voiceId: v.voice_id,
          name: v.name ?? v.voice_id,
          category: v.category ?? '',
          description: v.description ?? '',
          previewUrl: v.preview_url ?? null,
          labels: v.labels ?? {},
        });
      }
      if (!json.has_more || !json.next_page_token) break;
      token = json.next_page_token;
    }
    return voices;
  }

  async subscription(): Promise<{ used: number; limit: number; resetsAt: string | null; tier: string }> {
    const res = await this.request('/v1/user/subscription', { method: 'GET' }, 'subscription');
    const j = (await res.json()) as { character_count?: number; character_limit?: number; next_character_count_reset_unix?: number | null; tier?: string };
    return {
      used: j.character_count ?? 0,
      limit: j.character_limit ?? 0,
      resetsAt: j.next_character_count_reset_unix ? new Date(j.next_character_count_reset_unix * 1000).toISOString() : null,
      tier: j.tier ?? 'unknown',
    };
  }

  async textToSpeech(voiceId: string, text: string, modelId?: string): Promise<{ audio: ArrayBuffer; mime: string; model: string }> {
    const model = modelId || this.cfg.ttsModel;
    const limit = TTS_CHAR_LIMITS[model] ?? 5000;
    if (!text.trim()) throw new ApiError(400, 'narration_empty', 'This slide has no speaker notes to narrate.', false, 'Write speaker notes first.');
    if (text.length > limit) {
      throw new ApiError(400, 'elevenlabs_text_too_long', `The speaker notes are ${text.length} characters; ${model} accepts up to ${limit} per request.`, false, 'Shorten the speaker notes for this slide.');
    }
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(voiceId)) throw new ApiError(400, 'elevenlabs_voice_unavailable', 'Invalid voice id.', false);
    const res = await this.request(
      `/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=mp3_44100_128`,
      { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'audio/mpeg' }, body: JSON.stringify({ text, model_id: model }) },
      'tts',
    );
    return { audio: await res.arrayBuffer(), mime: 'audio/mpeg', model };
  }

  async speechToText(audio: Buffer, mime: string, filename: string, languageCode?: string): Promise<{ text: string; languageCode: string | null }> {
    const form = new FormData();
    form.append('model_id', this.cfg.sttModel);
    form.append('file', new Blob([new Uint8Array(audio)], { type: mime || 'application/octet-stream' }), filename);
    if (languageCode) form.append('language_code', languageCode);
    form.append('tag_audio_events', 'false');
    const res = await this.request('/v1/speech-to-text', { method: 'POST', body: form }, 'stt');
    const j = (await res.json()) as { text?: string; language_code?: string | null };
    return { text: (j.text ?? '').trim(), languageCode: j.language_code ?? null };
  }
}
