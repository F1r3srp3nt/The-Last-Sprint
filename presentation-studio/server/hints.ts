/**
 * Where the user puts provider keys. The web version reads them from presentation-studio/.env;
 * the desktop app stores them through its own Setup dialog (encrypted by the OS keychain).
 */
let desktop = false;

export function setDesktopMode(on: boolean): void {
  desktop = on;
}

export function isDesktopMode(): boolean {
  return desktop;
}

/** "Put the key in …" instruction for one provider key. */
export function keyHint(envVar: 'ANTHROPIC_API_KEY' | 'ELEVENLABS_API_KEY', verb: 'add' | 'check' | 'replace'): string {
  const provider = envVar === 'ANTHROPIC_API_KEY' ? 'Anthropic' : 'ElevenLabs';
  if (desktop) {
    const action = verb === 'add' ? 'Add' : verb === 'check' ? 'Check' : 'Replace';
    return `${action} the ${provider} key in Setup (the AI / Voice button), then click "Verify connection".`;
  }
  const action = verb === 'add' ? 'Add' : verb === 'check' ? 'Check' : 'Put the new key in';
  return verb === 'replace'
    ? `${action} presentation-studio/.env as ${envVar} and restart the server.`
    : `${action} ${envVar} in presentation-studio/.env and restart the server.`;
}
