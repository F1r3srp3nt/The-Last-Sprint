// End-to-end test of the PACKAGED desktop app (not the dev server).
//
// 1. Copies the packaged app to a fresh temporary folder outside the source checkout and hides
//    the checkout's own build output (dist/, build/), so nothing can be loaded from the source.
// 2. Launches it with a clean environment: no Node.js on PATH, no .env, no provider variables.
// 3. Drives its window over the Chrome DevTools protocol (Playwright connectOverCDP) and tests:
//    isolation of the renderer, the token-guarded backend, image import, template deck, save,
//    reopen, PPTX export, provider keys entered in Setup, ElevenLabs narration against a MOCK
//    server with audio playback, narration ZIP export, that keys never reach the window or
//    files, graceful shutdown of the backend, and a second launch that keeps the saved keys.
//
// Native dialogs cannot be clicked over CDP, so the app runs with PRESENTATION_STUDIO_E2E_DIR:
// save dialogs then write into that folder, the open dialog returns PRESENTATION_STUDIO_E2E_OPEN,
// and keys go into a clearly labelled non-secure test store (see docs/DESKTOP.md).
//
// Usage: npm run desktop:pack && npm run desktop:test     (or: node e2e/run-desktop-e2e.mjs --app <path>)
import { chromium } from 'playwright';
import { execFileSync, spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import JSZip from 'jszip';
import { startMockProviders } from './mock-providers.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'test-output', 'desktop-e2e');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const sample = (f) => join(root, 'samples', f);
const ANTHROPIC_KEY = 'e2e-anthropic-key-DO-NOT-LEAK';
const ELEVEN_KEY = 'e2e-elevenlabs-key-DO-NOT-LEAK';
const TITLE = 'Desktop e2e synthetic';
const PROJECT = 'desktop-e2e-synthetic.pstudio';
const results = [];
const step = async (name, fn) => {
  const t = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - t });
    console.log(`  ✓ ${name}`);
  } catch (e) {
    results.push({ name, ok: false, error: String(e?.message ?? e) });
    console.log(`  ✕ ${name}\n    ${String(e?.stack ?? e).split('\n').slice(0, 5).join('\n    ')}`);
    throw e;
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitForFile(path, ms = 15000) {
  for (let t = 0; t < ms; t += 100) {
    if (existsSync(path)) return path;
    await sleep(100);
  }
  throw new Error(`File did not appear: ${path}`);
}

// ---- Locate and copy the packaged app -------------------------------------------------------
const argApp = process.argv.indexOf('--app');
const packaged =
  argApp > 0
    ? process.argv[argApp + 1]
    : process.platform === 'darwin'
      ? join(root, 'release', 'mac-arm64', 'Presentation Studio.app')
      : join(root, 'release', 'linux-unpacked');
if (!existsSync(packaged)) throw new Error(`Packaged app not found at ${packaged}. Run "npm run desktop:pack" first.`);
const tmp = mkdtempSync(join(tmpdir(), 'ps-desktop-e2e-'));
const copy = join(tmp, process.platform === 'darwin' ? 'Presentation Studio.app' : 'app');
if (process.platform === 'darwin') execFileSync('ditto', [packaged, copy]);
else cpSync(packaged, copy, { recursive: true, verbatimSymlinks: true });
const exe = process.platform === 'darwin' ? join(copy, 'Contents', 'MacOS', 'Presentation Studio') : join(copy, 'presentation-studio');
const filesDir = join(tmp, 'files');
const homeDir = join(tmp, 'home');
mkdirSync(filesDir);
mkdirSync(homeDir);
console.log(`Packaged app copied to ${copy}`);

// Hide the checkout's build output while the app runs, so it cannot be what gets loaded.
const hidden = [];
for (const d of ['dist', 'build']) {
  if (existsSync(join(root, d))) {
    renameSync(join(root, d), join(root, `${d}.hidden-by-desktop-e2e`));
    hidden.push(d);
  }
}
const restoreCheckout = () => {
  for (const d of hidden.splice(0)) renameSync(join(root, `${d}.hidden-by-desktop-e2e`), join(root, d));
};
process.on('exit', restoreCheckout);

// ---- Launch ---------------------------------------------------------------------------------
let xvfb = null;
let display = process.env.DISPLAY;
if (process.platform === 'linux' && !display) {
  display = ':99';
  xvfb = spawn('Xvfb', [display, '-screen', '0', '1600x1000x24'], { stdio: 'ignore' });
  await sleep(800);
}
const mocks = await startMockProviders({ anthropicKey: ANTHROPIC_KEY, elevenKey: ELEVEN_KEY });
let cdpPort = 9400;

function launch() {
  cdpPort += 1;
  const env = {
    HOME: homeDir,
    PATH: '/nonexistent', // no Node.js (or anything else) on PATH
    TMPDIR: tmp,
    PRESENTATION_STUDIO_E2E_DIR: filesDir,
    PRESENTATION_STUDIO_E2E_OPEN: join(filesDir, PROJECT),
    PRESENTATION_STUDIO_E2E_TEST_KEYSTORE: '1',
    PRESENTATION_STUDIO_E2E_ANTHROPIC_BASE_URL: mocks.anthropicUrl,
    PRESENTATION_STUDIO_E2E_ELEVENLABS_BASE_URL: mocks.elevenUrl,
    ...(display ? { DISPLAY: display } : {}),
  };
  const args = [`--remote-debugging-port=${cdpPort}`];
  if (process.platform === 'linux' && process.getuid?.() === 0) args.push('--no-sandbox'); // Chromium refuses to sandbox as root (containers)
  const logs = [];
  const child = spawn(exe, args, { cwd: tmp, env, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', (d) => logs.push(String(d)));
  child.stderr.on('data', (d) => logs.push(String(d)));
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  return { child, logs, exited };
}

async function attach() {
  for (let i = 0; i < 120; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${cdpPort}/json/version`)).ok) break;
    } catch {
      /* not up yet */
    }
    await sleep(250);
  }
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${cdpPort}`);
  let page;
  for (let i = 0; i < 80 && !page; i++) {
    page = browser.contexts().flatMap((c) => c.pages()).find((p) => p.url().startsWith('app://studio'));
    if (!page) await sleep(250);
  }
  if (!page) throw new Error('The app window did not open.');
  page.on('dialog', (d) => d.accept());
  await page.locator('[data-testid=file-input]').waitFor({ state: 'attached', timeout: 20000 });
  return { browser, page };
}

const mainLog = () => {
  const p = join(filesDir, 'user-data', 'logs', 'main.log');
  return existsSync(p) ? readFileSync(p, 'utf8') : '';
};
const thumbLabels = (page) => page.locator('[data-testid=slide-thumb] .thumb-select').evaluateAll((els) => els.map((e) => e.getAttribute('aria-label')));
const selectSlide = (page, n) => page.locator('[data-testid=slide-thumb] .thumb-select').nth(n - 1).click();

let run = launch();
let session;
let failed = false;
try {
  console.log('\nLaunch 1 — packaged app, no keys');
  await step('packaged app opens its own window over app://studio (no dev server, no Node on PATH)', async () => {
    session = await attach();
    const { page } = session;
    assert.equal(page.url(), 'app://studio/');
    assert.equal(await page.title(), 'Presentation Studio');
    for (const port of [5173, 8787]) {
      await assert.rejects(fetch(`http://127.0.0.1:${port}/`), `nothing should listen on ${port}`);
    }
    assert.ok(!existsSync(join(root, 'dist')) && !existsSync(join(root, 'build')), 'checkout build output is hidden');
  });
  const { page } = session;

  await step('renderer is isolated: no Node, no ipcRenderer, only the fixed bridge', async () => {
    const view = await page.evaluate(() => ({
      require: typeof window.require,
      process: typeof window.process,
      module: typeof window.module,
      bridge: Object.keys(window.presentationStudioDesktop ?? {}).sort(),
      credentials: Object.keys(window.presentationStudioDesktop?.credentials ?? {}).sort(),
      files: Object.keys(window.presentationStudioDesktop?.files ?? {}).sort(),
      csp: document.querySelector('meta[http-equiv]') ? 'meta' : 'header',
    }));
    assert.deepEqual(view, {
      require: 'undefined',
      process: 'undefined',
      module: 'undefined',
      bridge: ['backend', 'credentials', 'files', 'isDesktop', 'platform'],
      credentials: ['clear', 'save', 'status'],
      files: ['openProject', 'save'],
      csp: 'header',
    });
    // Inline script is blocked by the Content-Security-Policy.
    const inlineRan = await page.evaluate(() => {
      const s = document.createElement('script');
      s.textContent = 'window.__inline = 1';
      document.head.appendChild(s);
      return window.__inline === 1;
    });
    assert.equal(inlineRan, false, 'CSP blocks inline scripts');
    // Invalid payloads are refused by the main process.
    const refused = await page.evaluate(() => window.presentationStudioDesktop.files.save('exe', '../../evil', new Uint8Array([1])).then(() => 'accepted', (e) => e.message));
    assert.match(refused, /Invalid request/);
  });

  await step('backend runs in its own process and refuses requests without the launch token', async () => {
    const m = /backend ready on 127\.0\.0\.1:(\d+)/.exec(mainLog());
    assert.ok(m, 'main.log reports the backend port');
    const direct = await fetch(`http://127.0.0.1:${m[1]}/api/status`);
    assert.equal(direct.status, 403);
    const viaApp = await page.evaluate(async () => (await fetch('/api/status')).status);
    assert.equal(viaApp, 200);
  });

  await step('import PNG, JPEG and WebP images', async () => {
    await page.setInputFiles('[data-testid=file-input]', [sample('fjordlight-harbour-wide.png'), sample('bike-station-portrait.jpg'), sample('workshop-notes-square.webp')]);
    await page.locator('[data-testid=gallery-item]').nth(2).waitFor();
    assert.equal(await page.locator('[data-testid=gallery-item]').count(), 3);
    assert.match(await page.locator('[data-testid=gallery-item]').nth(2).innerText(), /1000×1000 · WEBP/);
    await page.locator('[data-testid=gallery-item]').nth(0).getByPlaceholder('What does this image show?').fill('Synthetic harbour illustration');
  });

  let titlesBefore;
  await step('template deck and edits', async () => {
    await page.click('[data-testid=step-brief]');
    await page.fill('[data-testid=topic]', 'Fjordlight bike-share pilot (synthetic sample)');
    await page.fill('[data-testid=brief]', 'Short trips to the ferry\nStations near ferry stops\nOpen question: winter use\nStart with one district');
    await page.fill('[data-testid=slide-count]', '5');
    await page.click('[data-testid=generate-template]');
    await page.locator('[data-testid=slide-thumb]').nth(4).waitFor();
    await page.fill('[data-testid=project-title]', TITLE); // after the deck: building it names the project after the topic
    await selectSlide(page, 2);
    await page.fill('[data-testid=field-title]', 'Edited title (desktop)');
    await page.fill('[data-testid=field-notes]', 'Synthetic speaker notes for slide two.');
    titlesBefore = await thumbLabels(page);
    await page.screenshot({ path: join(out, '1-editor.png') });
  });

  await step('save project through the save dialog', async () => {
    await page.click('[data-testid=save-project]');
    await waitForFile(join(filesDir, PROJECT));
    await page.getByText(`Project saved as ${PROJECT}`).waitFor();
    const zip = await JSZip.loadAsync(readFileSync(join(filesDir, PROJECT)));
    const webp = await zip.file(/assets\/.*\.webp$/)[0].async('nodebuffer');
    assert.ok(readFileSync(sample('workshop-notes-square.webp')).equals(webp), 'original WebP bytes preserved');
  });

  await step('new project, then reopen the saved file through the open dialog', async () => {
    await page.getByRole('button', { name: 'New', exact: true }).click();
    await page.locator('[data-testid=gallery-item]').first().waitFor({ state: 'detached' });
    await page.click('[data-testid=open-project]');
    await page.locator('[data-testid=slide-thumb]').nth(4).waitFor();
    assert.deepEqual(await thumbLabels(page), titlesBefore);
    await selectSlide(page, 2);
    assert.equal(await page.inputValue('[data-testid=field-title]'), 'Edited title (desktop)');
    assert.equal(await page.inputValue('[data-testid=field-notes]'), 'Synthetic speaker notes for slide two.');
    assert.equal(await page.inputValue('[data-testid=project-title]'), TITLE);
    await page.click('[data-testid=step-sources]');
    assert.equal(await page.locator('[data-testid=gallery-item]').count(), 3);
    assert.equal(await page.locator('[data-testid=gallery-item]').nth(0).getByPlaceholder('What does this image show?').inputValue(), 'Synthetic harbour illustration');
    await page.click('[data-testid=step-editor]');
  });

  let pptx;
  await step('export an editable .pptx through the save dialog', async () => {
    await page.click('[data-testid=export]');
    await page.click('[data-testid=export-pptx]');
    pptx = await waitForFile(join(filesDir, 'desktop-e2e-synthetic.pptx'));
    await page.getByText('PowerPoint exported as desktop-e2e-synthetic.pptx').waitFor();
    const zip = await JSZip.loadAsync(readFileSync(pptx));
    const slides = Object.keys(zip.files).filter((f) => /^ppt\/slides\/slide\d+\.xml$/.test(f));
    assert.equal(slides.length, 5);
    assert.ok(Object.keys(zip.files).filter((f) => f.startsWith('ppt/media/')).length >= 2, 'images embedded');
    const all = (await Promise.all(slides.map((f) => zip.file(f).async('string')))).join('\n');
    assert.match(all, /Edited title \(desktop\)/);
    const notes = (await Promise.all(Object.keys(zip.files).filter((f) => /^ppt\/notesSlides\/notesSlide\d+\.xml$/.test(f)).map((f) => zip.file(f).async('string')))).join('\n');
    assert.match(notes, /Synthetic speaker notes for slide two\./);
    try {
      const report = execFileSync('python3', [join(root, 'scripts', 'inspect-pptx.py'), pptx], { encoding: 'utf8' });
      assert.match(report, /slides: 5/);
      assert.match(report, /Edited title \(desktop\)/);
      writeFileSync(join(out, 'pptx-report.txt'), report);
      console.log('    python-pptx opened the export: ' + report.split('\n')[0]);
    } catch (e) {
      if (/No module named|ENOENT/.test(String(e))) console.log('    (python-pptx not available: structural ZIP checks only)');
      else throw e;
    }
  });

  await step('Setup: keys are entered in the app, validated, stored and the server restarts', async () => {
    await page.click('[data-testid=open-setup]');
    const dialog = page.getByRole('dialog', { name: 'Setup & providers' });
    await dialog.getByText('E2E test store').first().waitFor();
    await page.fill('[data-testid=key-input-elevenlabs]', 'too short');
    await page.click('[data-testid=save-key-elevenlabs]');
    await dialog.getByText('does not look like a complete API key').waitFor().catch(async () => dialog.getByText('spaces or line breaks').waitFor());
    await page.fill('[data-testid=key-input-elevenlabs]', ELEVEN_KEY);
    await page.click('[data-testid=save-key-elevenlabs]');
    await page.locator('[data-testid=desktop-key-elevenlabs]').getByText('saved').first().waitFor();
    await page.fill('[data-testid=key-input-anthropic]', ANTHROPIC_KEY);
    await page.click('[data-testid=save-key-anthropic]');
    await page.locator('[data-testid=desktop-key-anthropic]').getByText('saved').first().waitFor();
    assert.equal(await page.inputValue('[data-testid=key-input-elevenlabs]').catch(() => ''), '', 'key field is cleared');
    await page.click('[data-testid=verify-elevenlabs]');
    await dialog.getByText('Credits used 1,234 / 100,000').waitFor();
    assert.match(await dialog.innerText(), /Verified/);
    await page.screenshot({ path: join(out, '2-setup.png') });
    await page.keyboard.press('Escape');
    const status = await page.evaluate(async () => (await fetch('/api/status')).json());
    assert.equal(status.generation.configured, true);
    assert.equal(status.elevenlabs.configured, true);
  });

  await step('narrate a slide (MOCK ElevenLabs) and play it in presentation mode', async () => {
    await page.getByRole('button', { name: 'Narration', exact: true }).click();
    await page.locator('[data-testid=voice-list] li', { hasText: 'Mock Voice One' }).getByRole('button', { name: 'Use' }).click();
    await page.keyboard.press('Escape');
    await selectSlide(page, 2);
    await page.click('[data-testid=narrate-slide]');
    await page.click('[data-testid=confirm-narrate]');
    await page.locator('[data-testid=narration-status]', { hasText: 'Up to date' }).waitFor();
    const tts = mocks.calls.eleven.filter((c) => c.path.startsWith('/v1/text-to-speech')).at(-1);
    assert.equal(tts.headers['xi-api-key'], ELEVEN_KEY, 'the backend sent the stored key to the provider');
    await page.click('[data-testid=present]');
    await page.locator('.present').waitFor();
    await page.getByText('Play narration').click();
    await page.waitForFunction(() => {
      const a = document.querySelector('.present audio');
      return a && !a.paused && a.currentTime > 0;
    }, null, { timeout: 8000 });
    await page.screenshot({ path: join(out, '3-present.png') });
    await page.keyboard.press('Escape');
  });

  let zipPath;
  await step('export PowerPoint + narration ZIP', async () => {
    await page.click('[data-testid=export]');
    await page.click('[data-testid=export-zip]');
    zipPath = await waitForFile(join(filesDir, 'desktop-e2e-synthetic-with-narration.zip'));
    const zip = await JSZip.loadAsync(readFileSync(zipPath));
    assert.ok(Object.keys(zip.files).some((f) => f.endsWith('.pptx')));
    assert.ok(Object.keys(zip.files).some((f) => f.endsWith('.mp3')));
  });

  await step('keys never reach the window, its storage, saved files or logs', async () => {
    await page.click('[data-testid=save-project]');
    await page.getByText(`Project saved as ${PROJECT}`).last().waitFor();
    await sleep(300);
    const surface = await page.evaluate(() => JSON.stringify({ html: document.documentElement.outerHTML, local: { ...localStorage }, session: { ...sessionStorage } }));
    const files = [join(filesDir, PROJECT), pptx, zipPath].map((p) => readFileSync(p).toString('latin1'));
    for (const key of [ANTHROPIC_KEY, ELEVEN_KEY]) {
      assert.ok(!surface.includes(key), 'not in the DOM or web storage');
      assert.ok(files.every((f) => !f.includes(key)), 'not in project, pptx or zip');
      assert.ok(!mainLog().includes(key), 'not in main.log');
      assert.ok(!run.logs.join('').includes(key), 'not in process output');
    }
  });

  await step('closing the window quits the app and stops the backend', async () => {
    await session.browser.close().catch(() => {}); // detaches CDP only
    // Ask the app to quit the way a user would: close its window (no unsaved changes).
    const cdp = await fetch(`http://127.0.0.1:${cdpPort}/json/list`).then((r) => r.json());
    const target = cdp.find((t) => t.url.startsWith('app://studio'));
    await fetch(`http://127.0.0.1:${cdpPort}/json/close/${target.id}`);
    const result = await Promise.race([run.exited, sleep(20000).then(() => null)]);
    assert.ok(result, 'app exited after its window closed');
    assert.match(mainLog(), /backend stopped; quitting/);
    const leftovers = execFileSync('ps', ['-eo', 'pid,args'], { encoding: 'utf8' }).split('\n').filter((l) => l.includes(copy));
    assert.deepEqual(leftovers, [], 'no app or backend processes left');
  });

  console.log('\nLaunch 2 — keys persist, server starts with them');
  run = launch();
  await step('second launch reads the stored keys; removing one restarts the server without it', async () => {
    session = await attach();
    const p2 = session.page;
    const status = await p2.evaluate(async () => (await fetch('/api/status')).json());
    assert.equal(status.elevenlabs.configured, true);
    assert.equal(status.generation.configured, true);
    await p2.click('[data-testid=open-setup]');
    await p2.click('[data-testid=remove-key-elevenlabs]');
    await p2.locator('[data-testid=key-input-elevenlabs]').waitFor();
    const after = await p2.evaluate(async () => (await fetch('/api/status')).json());
    assert.equal(after.elevenlabs.configured, false);
    assert.equal(after.generation.configured, true);
    await session.browser.close().catch(() => {});
    const cdp = await fetch(`http://127.0.0.1:${cdpPort}/json/list`).then((r) => r.json());
    await fetch(`http://127.0.0.1:${cdpPort}/json/close/${cdp.find((t) => t.url.startsWith('app://studio')).id}`);
    assert.ok(await Promise.race([run.exited, sleep(20000).then(() => null)]), 'second instance exited');
  });
} catch {
  failed = true;
} finally {
  try {
    run.child.kill('SIGKILL');
  } catch {
    /* already gone */
  }
  await Promise.race([run.exited, sleep(5000)]);
  await sleep(500);
  writeFileSync(join(out, 'main.log'), mainLog());
  writeFileSync(join(out, 'app-output.log'), run.logs.join(''));
  for (const f of readdirSync(filesDir).filter((f) => !f.startsWith('user-data'))) cpSync(join(filesDir, f), join(out, f));
  await mocks.close?.();
  xvfb?.kill();
  restoreCheckout();
  try {
    rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
  } catch (e) {
    console.log(`    (could not remove ${tmp}: ${e.code})`);
  }
  writeFileSync(join(out, 'results.json'), JSON.stringify(results, null, 2));
}
const passed = results.filter((r) => r.ok).length;
console.log(`\n${passed}/${results.length} desktop steps passed${failed ? ' — FAILED' : ''}. Output: ${out}`);
process.exit(failed ? 1 : 0);
