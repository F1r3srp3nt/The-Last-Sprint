import type { ApiErrorBody } from '../src/shared/apiTypes';

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public retryable: boolean,
    public hint?: string,
    public details?: string[],
  ) {
    super(message);
  }

  toBody(): ApiErrorBody {
    return { error: { code: this.code, message: this.message, hint: this.hint, retryable: this.retryable, details: this.details } };
  }
}
