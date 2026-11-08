import type {
  ApiErrorBody,
  OutlineRequest,
  OutlineResponse,
  ProviderStatus,
  SlideRequest,
  SlideResponse,
  TranscriptResponse,
  Voice,
} from '../shared/apiTypes';
import { validateOutline, validateSlideContent } from '../shared/generationSchemas';
import { desktop } from './desktop';

const START_HINT = desktop
  ? 'The built-in server is not responding. Use "Restart server" in the banner, or quit and reopen Presentation Studio.'
  : 'Start it with "npm run dev" in presentation-studio/, then retry.';

export class ClientApiError extends Error {
  constructor(
    public code: string,
    message: string,
    public retryable: boolean,
    public hint?: string,
    public details?: string[],
  ) {
    super(message);
  }
}

async function handle(res: Response): Promise<Response> {
  if (res.ok) return res;
  let body: ApiErrorBody | null = null;
  try {
    body = (await res.json()) as ApiErrorBody;
  } catch {
    /* ignore */
  }
  if (body?.error) throw new ClientApiError(body.error.code, body.error.message, body.error.retryable, body.error.hint, body.error.details);
  throw new ClientApiError('http_error', `The local server returned ${res.status}.`, res.status >= 500, START_HINT);
}

async function request(path: string, init?: RequestInit): Promise<Response> {
  let res: Response;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ClientApiError('server_unreachable', 'Cannot reach the Presentation Studio server.', true, START_HINT);
  }
  return handle(res);
}

const json = (body: unknown): RequestInit => ({ method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

export const api = {
  async status(): Promise<ProviderStatus> {
    return (await request('/api/status')).json();
  },
  async verifyGeneration(): Promise<ProviderStatus> {
    return (await request('/api/generation/verify', { method: 'POST' })).json();
  },
  async verifyElevenLabs(): Promise<ProviderStatus> {
    return (await request('/api/elevenlabs/verify', { method: 'POST' })).json();
  },
  async outline(req: OutlineRequest): Promise<OutlineResponse> {
    const res: OutlineResponse = await (await request('/api/generate/outline', json(req))).json();
    // Validate again in the browser before anything is rendered.
    const v = validateOutline(res.outline, { slideCount: req.brief.slideCount, assetIds: req.images.map((i) => i.id) });
    if (!v.ok || !v.value) throw new ClientApiError('invalid_output', 'The outline failed validation.', true, 'Retry generation.', v.errors);
    return { ...res, outline: v.value, notices: [...res.notices, ...v.notices] };
  },
  async slide(req: SlideRequest, assetIds: string[]): Promise<SlideResponse> {
    const res: SlideResponse = await (await request('/api/generate/slide', json({ ...req, assetIds }))).json();
    const v = validateSlideContent(res.content, { assetIds });
    if (!v.ok || !v.value) throw new ClientApiError('invalid_output', 'The slide failed validation.', true, 'Retry this slide.', v.errors);
    return { ...res, content: v.value, notices: [...res.notices, ...v.notices] };
  },
  async voices(): Promise<Voice[]> {
    return (await (await request('/api/elevenlabs/voices')).json()).voices;
  },
  async tts(voiceId: string, text: string, modelId?: string): Promise<{ blob: Blob; model: string }> {
    const res = await request('/api/elevenlabs/tts', json({ voiceId, text, modelId }));
    return { blob: await res.blob(), model: res.headers.get('X-Narration-Model') ?? modelId ?? '' };
  },
  async transcribe(audio: Blob, filename: string): Promise<TranscriptResponse> {
    const form = new FormData();
    form.append('audio', audio, filename);
    return (await request('/api/elevenlabs/transcribe', { method: 'POST', body: form })).json();
  },
};

export function describeError(err: unknown): { message: string; hint?: string; retryable: boolean; details?: string[]; code?: string } {
  if (err instanceof ClientApiError) return { message: err.message, hint: err.hint, retryable: err.retryable, details: err.details, code: err.code };
  if (err instanceof Error) return { message: err.message, retryable: true };
  return { message: 'Something went wrong.', retryable: true };
}
