import { loadConfig } from './config';
import { createApp } from './app';

const config = loadConfig();
const app = createApp(config);

app.listen(config.port, config.host, () => {
  const gen = config.generation.provider === 'anthropic' ? `Anthropic (${config.generation.model})` : 'not configured — template mode only';
  const el = config.elevenlabs.apiKey ? 'key configured (not yet verified)' : 'not configured — typing and export still work';
  console.log(`Presentation Studio API on http://${config.host}:${config.port}`);
  console.log(`  Generation: ${gen}`);
  console.log(`  ElevenLabs: ${el}`);
  if (config.production) console.log(`  Open http://${config.host}:${config.port} in your browser.`);
  else console.log('  Open http://127.0.0.1:5173 in your browser (Vite dev server).');
});
