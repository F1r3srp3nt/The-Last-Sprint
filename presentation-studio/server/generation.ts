/**
 * Presentation generation with the Anthropic Messages API (structured outputs).
 * The model's JSON is validated twice: by the SDK against the schema, then by
 * validateOutline / validateSlideContent for references and counts.
 */
import Anthropic from '@anthropic-ai/sdk';
import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';
import type { ZodType } from 'zod';
import type { ServerConfig } from './config';
import { ApiError } from './errors';
import { OUTLINE_SYSTEM, SLIDE_SYSTEM, outlineUserContent, slideUserContent } from './prompts';
import {
  OutlineSchema,
  SlideContentSchema,
  validateOutline,
  validateSlideContent,
} from '../src/shared/generationSchemas';
import type { OutlineRequest, OutlineResponse, SlideRequest, SlideResponse } from '../src/shared/apiTypes';
import { isDesktopMode, keyHint } from './hints';

export interface Generator {
  outline(req: OutlineRequest): Promise<OutlineResponse>;
  slide(req: SlideRequest, assetIds: string[]): Promise<SlideResponse>;
  verify(): Promise<void>;
}

export function mapAnthropicError(err: unknown): ApiError {
  if (err instanceof ApiError) return err;
  if (err instanceof Anthropic.AuthenticationError) {
    return new ApiError(401, 'generation_auth', 'The generation provider rejected the API key.', false, keyHint('ANTHROPIC_API_KEY', 'check'));
  }
  if (err instanceof Anthropic.PermissionDeniedError) {
    return new ApiError(403, 'generation_permission', 'The API key is not allowed to use this model.', false, 'Check the key\'s workspace permissions or set ANTHROPIC_MODEL to a model you can use.');
  }
  if (err instanceof Anthropic.NotFoundError) {
    return new ApiError(404, 'generation_model', 'The configured model was not found.', false, isDesktopMode() ? 'The desktop app uses the default model; check that your key can use it.' : 'Check ANTHROPIC_MODEL in .env.');
  }
  if (err instanceof Anthropic.RateLimitError) {
    return new ApiError(429, 'generation_rate_limited', 'The generation provider is rate limiting requests.', true, 'Wait a moment and retry.');
  }
  if (err instanceof Anthropic.BadRequestError) {
    return new ApiError(400, 'generation_bad_request', `The generation provider rejected the request: ${err.message}`, false, 'Large or unusual images can cause this. Try removing an image and retry.');
  }
  if (err instanceof Anthropic.APIConnectionError) {
    return new ApiError(502, 'generation_network', 'Could not reach the generation provider.', true, 'Check your internet connection and retry.');
  }
  if (err instanceof Anthropic.APIError) {
    return new ApiError(502, 'generation_provider_error', `The generation provider returned an error (${err.status ?? 'unknown'}).`, true, 'This is usually temporary. Retry in a moment.');
  }
  return new ApiError(500, 'generation_failed', 'Generation failed unexpectedly.', true);
}

export function createAnthropicGenerator(cfg: ServerConfig['generation'], client?: Anthropic): Generator {
  const anthropic = client ?? new Anthropic({ apiKey: cfg.apiKey ?? undefined, maxRetries: 2 });

  async function call<T>(system: string, content: Anthropic.Beta.BetaContentBlockParam[], schema: ZodType<T>): Promise<unknown> {
    let response;
    try {
      response = await anthropic.beta.messages.parse({
        model: cfg.model,
        max_tokens: 16000,
        ...(cfg.refusalFallback ? { betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' as const } : {}),
        output_config: { effort: cfg.effort, format: betaZodOutputFormat(schema) },
        system,
        messages: [{ role: 'user', content }],
      });
    } catch (err) {
      if (err instanceof Anthropic.APIError || err instanceof ApiError) throw mapAnthropicError(err);
      // The SDK throws a plain error when the model's JSON does not match the schema.
      throw new ApiError(502, 'invalid_output', 'The model returned content that is not valid slide JSON.', true, 'Retry. Nothing was changed in your deck.');
    }
    if (response.stop_reason === 'refusal') {
      throw new ApiError(422, 'refused', 'The model declined to write this content.', false, 'Review the brief and images, then retry, or write this slide by hand.');
    }
    if (response.stop_reason === 'max_tokens') {
      throw new ApiError(502, 'truncated', 'The model ran out of space before finishing.', true, 'Retry, or ask for fewer slides.');
    }
    if (response.parsed_output == null) {
      throw new ApiError(502, 'invalid_output', 'The model returned content that is not valid slide JSON.', true, 'Retry. Nothing was changed in your deck.');
    }
    return response.parsed_output;
  }

  return {
    async outline(req) {
      const raw = await call(OUTLINE_SYSTEM, outlineUserContent(req.brief, req.images), OutlineSchema);
      const preferred = Object.fromEntries(req.images.filter((i) => i.preferredSlide).map((i) => [i.id, i.preferredSlide as number]));
      const result = validateOutline(raw, { slideCount: req.brief.slideCount, assetIds: req.images.map((i) => i.id), preferred });
      if (!result.ok || !result.value) {
        throw new ApiError(502, 'invalid_output', 'The generated outline failed validation.', true, 'Retry generation.', result.errors);
      }
      return { outline: result.value, notices: result.notices, model: cfg.model };
    },
    async slide(req, assetIds) {
      const raw = await call(SLIDE_SYSTEM, slideUserContent(req), SlideContentSchema);
      const result = validateSlideContent(raw, { assetIds });
      if (!result.ok || !result.value) {
        throw new ApiError(502, 'invalid_output', 'The generated slide failed validation.', true, 'Retry this slide.', result.errors);
      }
      return { content: result.value, notices: result.notices, model: cfg.model };
    },
    async verify() {
      try {
        await anthropic.models.retrieve(cfg.model);
      } catch (err) {
        throw mapAnthropicError(err);
      }
    },
  };
}
