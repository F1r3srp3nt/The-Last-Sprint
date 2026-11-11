// Renders the synthetic three-slide deck (samples/three-slide-deck.json) in the real app and
// exports it, without any provider: the server runs with no API keys.
//
//   npx tsx scripts/render-sample-deck.ts [--app-root DIR] [--label NAME] [--restyle] [--out DIR]
//
// --app-root  run another checkout of presentation-studio (e.g. the previous version) for a comparison
// --restyle   after the first screenshots, apply "Restyle deck" (--theme, default futuristic-cyan) through the UI
//
// Output: <out>/<label>-slide-N.png (the editor preview), <label>-restyled-slide-N.png, <label>.pptx
import { chromium } from 'playwright';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { emptyProject, newSlide, type Slide } from '../src/shared/model';
import { saveProject } from '../src/project/projectFile';

const here = join(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name: string, fallback: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const appRoot = resolve(arg('app-root', here));
const label = arg('label', 'current');
const out = resolve(arg('out', join(here, 'test-output', 'sample-deck')));
const restyle = process.argv.includes('--restyle');
const theme = arg('theme', 'futuristic-cyan');
const port = Number(arg('port', '8899'));
mkdirSync(out, { recursive: true });

// 1. The synthetic deck as a .pstudio project file (basic layouts, as a plain generation would choose them).
const raw = JSON.parse(readFileSync(join(here, 'samples', 'three-slide-deck.json'), 'utf8')) as { title: string; slides: Partial<Slide>[] };
const project = emptyProject();
project.title = raw.title;
project.themeId = 'futuristic-cyan';
project.slides = raw.slides.map((s, i) => newSlide(`deck${i + 1}`, s.layout!, 'ai', s));
const projectPath = join(out, `${label}-input.pstudio`);
writeFileSync(projectPath, await saveProject(project, new Map()));

// 2. Build and serve the app with no provider keys.
execFileSync(process.execPath, [join(appRoot, 'node_modules', 'vite', 'bin', 'vite.js'), 'build', '--logLevel', 'error'], { cwd: appRoot, stdio: 'inherit' });
const server = spawn(process.execPath, [join(appRoot, 'node_modules', 'tsx', 'dist', 'cli.mjs'), 'server/index.ts'], {
  cwd: appRoot,
  env: { ...process.env, NODE_ENV: 'production', PORT: String(port), HOST: '127.0.0.1', ANTHROPIC_API_KEY: '', ELEVENLABS_API_KEY: '' },
  stdio: 'ignore',
});
const url = `http://127.0.0.1:${port}`;
for (let i = 0; i < 100; i++) {
  try {
    if ((await fetch(url)).ok) break;
  } catch {
    /* starting */
  }
  await new Promise((r) => setTimeout(r, 150));
}

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, acceptDownloads: true });
  page.on('dialog', (d) => d.accept());
  await page.goto(url);
  await page.setInputFiles('[data-testid=open-input]', projectPath);
  await page.locator('[data-testid=slide-thumb]').nth(2).waitFor();

  const shoot = async (prefix: string) => {
    for (let n = 1; n <= 3; n++) {
      await page.locator('[data-testid=slide-thumb] .thumb-select').nth(n - 1).click();
      await page.waitForTimeout(150);
      await page.locator('.main-canvas').screenshot({ path: join(out, `${prefix}-slide-${n}.png`) });
    }
  };
  await shoot(label);
  if (restyle) {
    await page.click('[data-testid=restyle-open]');
    await page.click(`[data-testid=restyle-theme-${theme}]`);
    await page.screenshot({ path: join(out, `${label}-restyle-dialog.png`) });
    await page.click('[data-testid=restyle-apply]');
    await page.locator('[data-testid=restyle-banner]').waitFor();
    await shoot(`${label}-restyled`);
  }
  await page.click('[data-testid=export]');
  const [download] = await Promise.all([page.waitForEvent('download'), page.click('[data-testid=export-pptx]')]);
  await download.saveAs(join(out, `${label}.pptx`));
  console.log(`Wrote screenshots and ${label}.pptx to ${out}`);
} finally {
  await browser.close();
  server.kill();
}
