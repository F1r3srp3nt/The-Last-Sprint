export interface MockCall {
  method: string;
  path: string;
  query?: string;
  headers: Record<string, string | string[] | undefined>;
  body: any;
  bytes?: number;
}
export interface MockProviders {
  anthropicUrl: string;
  elevenUrl: string;
  calls: { anthropic: MockCall[]; eleven: MockCall[] };
  state: { anthropicMode: 'ok' | 'invalid' | 'rate_limit' };
  close(): Promise<unknown>;
}
export function startMockProviders(opts?: { anthropicKey?: string; elevenKey?: string }): Promise<MockProviders>;
