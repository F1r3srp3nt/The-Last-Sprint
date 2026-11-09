// End-to-end test in a real browser (Playwright + Chromium).
//
// Run A: no providers configured (template mode). Upload, reorder, brief,
//        create/edit/reorder/duplicate/delete slides, overflow warning,
//        save project, reopen it, export .pptx and validate the file.
// Run B: MOCK Anthropic + MOCK ElevenLabs servers (e2e/mock-providers.mjs).
//        Spoken brief (fake microphone), AI generation, single-slide regenerate,
//        connection check, voice selection, narration per slide and per deck,
//        outdated detection, unavailable-voice error, presentation mode with
//        audio, ZIP export, and checks that keys never reach the browser or files.
//
// Usage: npm run test:e2e   (builds the client first)
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import JSZip from 'jszip';
import { startMockProviders } from './mock-providers.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'test-output', 'e2e');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const sample = (f) => join(root, 'samples', f);
const ANTHROPIC_KEY = 'e2e-anthropic-key-DO-NOT-LEAK';
const ELEVEN_KEY = 'e2e-elevenlabs-key-DO-NOT-LEAK';
const results = [];
const step = async (name, fn) => {
  const t = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - t });
    console.log(`  ✓ ${name}`);
  } catch (e) {
    results.push({ name, ok: false, error: String(e?.message ?? e) });
    console.log(`  ✕ ${name}\n    ${String(e?.stack ?? e).split('\n').slice(0, 4).join('\n    ')}`);
    throw e;
  }
};

function startServer(port, env) {
  const logs = [];
  const child = spawn(process.execPath, [join(root, 'node_modules', 'tsx', 'dist', 'cli.mjs'), 'server/index.ts'], {
    cwd: root,
    env: { ...process.env, NODE_ENV: 'production', PORT: String(port), HOST: '127.0.0.1', ANTHROPIC_API_KEY: '', ELEVENLABS_API_KEY: '', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', (d) => logs.push(String(d)));
  child.stderr.on('data', (d) => logs.push(String(d)));
  return { child, logs, url: `http://127.0.0.1:${port}` };
}
async function waitFor(url) {
  for (let i = 0; i < 100; i++) {
    try {
      if ((await fetch(url)).ok) return;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`Server did not start: ${url}`);
}
async function download(page, click, file) {
  const [dl] = await Promise.all([page.waitForEvent('download'), click()]);
  const path = join(out, file);
  await dl.saveAs(path);
  return path;
}
const thumbLabels = (page) => page.locator('[data-testid=slide-thumb] .thumb-select').evaluateAll((els) => els.map((e) => e.getAttribute('aria-label')));
const selectSlide = (page, n) => page.locator('[data-testid=slide-thumb] .thumb-select').nth(n - 1).click();

console.log('Building client…');
execFileSync(process.execPath, [join(root, 'node_modules', 'vite', 'bin', 'vite.js'), 'build', '--logLevel', 'error'], { cwd: root, stdio: 'inherit' });

const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
const mocks = await startMockProviders({ anthropicKey: ANTHROPIC_KEY, elevenKey: ELEVEN_KEY });
const serverA = startServer(8796, {});
const serverB = startServer(8797, { ANTHROPIC_API_KEY: ANTHROPIC_KEY, ANTHROPIC_BASE_URL: mocks.anthropicUrl, ELEVENLABS_API_KEY: ELEVEN_KEY, ELEVENLABS_BASE_URL: mocks.elevenUrl });
let failed = false;

try {
  await Promise.all([waitFor(`${serverA.url}/api/status`), waitFor(`${serverB.url}/api/status`)]);

  // ------------------------------------------------------------------ Run A
  console.log('\nRun A — no providers (template mode)');
  const ctxA = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true });
  const page = await ctxA.newPage();
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(String(e)));
  page.on('dialog', (d) => d.accept());
  await page.goto(serverA.url);

  await step('upload PNG, JPEG, WebP (+1 extra) images', async () => {
    await page.setInputFiles('[data-testid=file-input]', [sample('fjordlight-harbour-wide.png'), sample('bike-station-portrait.jpg'), sample('workshop-notes-square.webp'), sample('poster-with-embedded-instruction.png')]);
    await page.locator('[data-testid=gallery-item]').nth(3).waitFor();
    assert.equal(await page.locator('[data-testid=gallery-item]').count(), 4);
    assert.match(await page.locator('[data-testid=gallery-item]').nth(2).innerText(), /1000×1000 · WEBP/);
  });
  await step('reorder, caption and remove images', async () => {
    await page.getByRole('button', { name: 'Move fjordlight-harbour-wide.png later' }).click();
    assert.match(await page.locator('[data-testid=gallery-item] .name').first().innerText(), /bike-station-portrait/);
    await page.locator('[data-testid=gallery-item]').nth(0).getByPlaceholder('What does this image show?').fill('Synthetic sketch of a bike dock');
    await page.getByRole('button', { name: 'Remove poster-with-embedded-instruction.png' }).click();
    assert.equal(await page.locator('[data-testid=gallery-item]').count(), 3);
    await page.screenshot({ path: join(out, 'a1-images.png') });
  });
  await step('brief: AI disabled without provider, template mode available, spoken brief off', async () => {
    await page.click('[data-testid=step-brief]');
    await page.fill('[data-testid=topic]', 'Fjordlight bike-share pilot (synthetic sample)');
    await page.fill('[data-testid=brief]', 'Short trips to the ferry are hard without a car\nStations near ferry stops\nOpen question: winter use\nOpen question: pricing\nStart with one district');
    await page.fill('[data-testid=slide-count]', '6');
    assert.equal(await page.isDisabled('[data-testid=generate-ai]'), true);
    assert.match(await page.locator('.spoken').innerText(), /not configured/);
  });
  await step('slide count: typing replaces the value; a count in the brief must be resolved first', async () => {
    // Clearing the box used to store 1, so typing "3" gave 13.
    await page.fill('[data-testid=slide-count]', '');
    await page.locator('[data-testid=slide-count]').pressSequentially('3');
    assert.equal(await page.inputValue('[data-testid=slide-count]'), '3');
    await page.fill('[data-testid=slide-count]', '6');
    const brief = await page.inputValue('[data-testid=brief]');
    await page.fill('[data-testid=brief]', `${brief}\nKeep it to three slides`);
    await page.locator('[data-testid=slide-count-conflict]').waitFor();
    assert.match(await page.locator('[data-testid=slide-count-conflict]').innerText(), /three slides/);
    assert.equal(await page.isDisabled('[data-testid=generate-template]'), true);
    await page.click('[data-testid=use-count-3]');
    assert.equal(await page.inputValue('[data-testid=slide-count]'), '3');
    assert.equal(await page.locator('[data-testid=slide-count-conflict]').count(), 0);
    await page.fill('[data-testid=slide-count]', '6');
    await page.click('[data-testid=keep-count]');
    assert.equal(await page.locator('[data-testid=slide-count-conflict]').count(), 0);
    assert.equal(await page.isDisabled('[data-testid=generate-template]'), false);
    await page.fill('[data-testid=brief]', brief);
  });
  await step('build template deck (labelled, no AI)', async () => {
    await page.click('[data-testid=generate-template]');
    await page.locator('[data-testid=slide-thumb]').nth(5).waitFor();
    assert.equal(await page.locator('[data-testid=slide-thumb]').count(), 6);
    assert.equal(await page.locator('[data-testid=slide-thumb] .origin-badge.template').count(), 6);
    assert.match(await page.locator('.mode-banner').innerText(), /without AI/);
  });
  await step('edit title, notes, image fill + crop on slide 2', async () => {
    await selectSlide(page, 2);
    await page.fill('[data-testid=field-title]', 'Edited title (synthetic)');
    await page.fill('[data-testid=field-notes]', 'Synthetic speaker notes for slide two.');
    await page.getByRole('radio', { name: 'Fill (crop to frame)' }).click();
    await page.locator('.crop-controls input[type=range]').first().fill('1.6');
    await page.locator('.crop-controls input[type=range]').nth(1).fill('0.2');
    assert.match(await page.locator('.main-canvas [data-role=title]').innerText(), /Edited title/);
  });
  await step('change layout to comparison and fill its fields', async () => {
    await selectSlide(page, 3);
    await page.selectOption('[data-testid=layout-select]', 'comparison');
    await page.fill('[data-testid=field-leftHeading]', 'Docks');
    await page.fill('[data-testid=field-leftBody]', 'Fixed stations\nEasy to find');
    await page.fill('[data-testid=field-rightHeading]', 'Free-floating');
    await page.fill('[data-testid=field-rightBody]', 'Park anywhere\nHarder to manage');
    assert.equal(await page.locator('.main-canvas [data-role=rightHeading]').innerText(), 'Free-floating');
  });
  await step('add, duplicate, delete and reorder slides', async () => {
    await page.click('[data-testid=add-slide]');
    await page.getByRole('menuitem', { name: 'Key takeaway' }).click();
    await page.fill('[data-testid=field-title]', 'Start small and measure');
    assert.equal(await page.locator('[data-testid=slide-thumb]').count(), 7);
    await page.getByRole('button', { name: 'Duplicate slide 2' }).click({ force: true });
    assert.equal(await page.locator('[data-testid=slide-thumb]').count(), 8);
    await page.getByRole('button', { name: 'Delete slide 3' }).click({ force: true });
    assert.equal(await page.locator('[data-testid=slide-thumb]').count(), 7);
    await page.getByRole('button', { name: 'Move slide 2 down' }).click({ force: true });
    const labels = await thumbLabels(page);
    assert.match(labels[2], /Edited title/);
    assert.doesNotMatch(labels[1], /Edited title/);
  });
  await step('too much text shows an overflow warning', async () => {
    await selectSlide(page, 3);
    const long = Array.from({ length: 30 }, (_, i) => `Bullet ${i + 1} with a lot of words so that it wraps over several lines in the column`).join('\n');
    await page.selectOption('[data-testid=layout-select]', 'textImage');
    await page.fill('[data-testid=field-body]', long);
    await page.locator('[data-testid=overflow-warning]').first().waitFor();
    assert.match(await page.locator('[data-testid=overflow-warning]').first().innerText(), /too much text/);
    assert.ok((await page.locator('[data-testid=slide-thumb]').nth(2).locator('.mini.warn').count()) > 0);
    await page.fill('[data-testid=field-body]', 'Short trips to the ferry\nFewer car trips');
    assert.equal(await page.locator('[data-testid=overflow-warning]').count(), 0);
    await page.screenshot({ path: join(out, 'a2-editor.png') });
  });
  let titlesBefore;
  let projectPath;
  await step('save project file', async () => {
    titlesBefore = await thumbLabels(page);
    projectPath = await download(page, () => page.click('[data-testid=save-project]'), 'run-a.pstudio');
    const zip = await JSZip.loadAsync(readFileSync(projectPath));
    assert.ok(zip.file('project.json'));
    assert.equal(Object.values(zip.files).filter((f) => !f.dir && f.name.startsWith('assets/')).length, 3);
    const original = readFileSync(sample('workshop-notes-square.webp'));
    const stored = await zip.file(/assets\/.*\.webp$/)[0].async('nodebuffer');
    assert.ok(original.equals(stored), 'original WebP bytes preserved');
  });
  await step('reopen saved project in a fresh page', async () => {
    const page2 = await ctxA.newPage();
    page2.on('dialog', (d) => d.accept());
    await page2.goto(serverA.url);
    await page2.setInputFiles('[data-testid=open-input]', projectPath);
    await page2.locator('[data-testid=slide-thumb]').nth(6).waitFor();
    assert.deepEqual(await thumbLabels(page2), titlesBefore);
    await selectSlide(page2, 3);
    assert.equal(await page2.inputValue('[data-testid=field-title]'), 'Edited title (synthetic)');
    assert.equal(await page2.inputValue('[data-testid=field-notes]'), 'Synthetic speaker notes for slide two.');
    assert.equal(await page2.getByRole('radio', { name: 'Fill (crop to frame)' }).getAttribute('aria-checked'), 'true');
    await page2.click('[data-testid=step-sources]');
    assert.equal(await page2.locator('[data-testid=gallery-item]').count(), 3);
    assert.equal(await page2.locator('[data-testid=gallery-item]').nth(0).getByPlaceholder('What does this image show?').inputValue(), 'Synthetic sketch of a bike dock');
    await page2.close();
  });
  await step('restyle deck without AI, then undo: text and notes unchanged', async () => {
    const titles = await thumbLabels(page);
    await selectSlide(page, 3);
    const notes = await page.inputValue('[data-testid=field-notes]');
    await page.click('[data-testid=restyle-open]');
    await page.click('[data-testid=restyle-theme-executive-dark]');
    await page.click('[data-testid=restyle-apply]');
    await page.locator('[data-testid=restyle-banner]').waitFor();
    assert.deepEqual(await thumbLabels(page), titles);
    await selectSlide(page, 3);
    assert.equal(await page.inputValue('[data-testid=field-notes]'), notes);
    await page.screenshot({ path: join(out, 'a3-restyled.png') });
    await page.click('[data-testid=restyle-undo]');
    assert.equal(await page.locator('[data-testid=restyle-banner]').count(), 0);
    assert.deepEqual(await thumbLabels(page), titles);
  });
  let pptxA;
  await step('export .pptx (narration ZIP not offered without narration)', async () => {
    await page.click('[data-testid=export]');
    assert.equal(await page.locator('[data-testid=export-zip]').count(), 0);
    pptxA = await download(page, () => page.click('[data-testid=export-pptx]'), 'run-a.pptx');
  });
  await step('exported .pptx opens in python-pptx with text, images and notes', async () => {
    const report = execFileSync('python3', [join(root, 'scripts', 'inspect-pptx.py'), pptxA], { encoding: 'utf8' });
    mkdirSync(join(out, 'lo'), { recursive: true });
    assert.match(report, /slides: 7/);
    assert.match(report, /Edited title \(synthetic\)/);
    assert.match(report, /notes: 'Synthetic speaker notes for slide two\.'/);
    assert.match(report, /image .* crop\(l,r,t,b\)=\((?!0\.0, 0\.0, 0\.0, 0\.0)/);
    assert.match(report, /leftHeading .*Docks/);
    assert.ok((report.match(/^\s+image /gm) ?? []).length >= 2);
    assert.match(report, /image .* image\/png \(1000, 1000\)/); // WebP exported as PNG
    console.log(report.split('\n').slice(0, 3).join('\n'));
  });
  await step('exported .pptx converts with LibreOffice', async () => {
    try {
      execFileSync('soffice', ['--headless', '--convert-to', 'pdf', '--outdir', join(out, 'lo'), pptxA], { stdio: 'ignore', timeout: 120000 });
    } catch {
      /* checked below */
    }
    assert.ok(existsSync(join(out, 'lo', 'run-a.pdf')), 'LibreOffice produced a PDF');
  });
  assert.deepEqual(pageErrors, [], 'no uncaught page errors in run A');
  await ctxA.close();

  // ------------------------------------------------------------------ Run B
  console.log('\nRun B — MOCK Anthropic + MOCK ElevenLabs');
  const ctxB = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true, permissions: ['microphone'] });
  const b = await ctxB.newPage();
  const errorsB = [];
  b.on('pageerror', (e) => errorsB.push(String(e)));
  b.on('dialog', (d) => d.accept());
  await b.goto(serverB.url);
  await b.setInputFiles('[data-testid=file-input]', [sample('fjordlight-harbour-wide.png'), sample('bike-station-portrait.jpg')]);
  await b.locator('[data-testid=gallery-item]').nth(1).waitFor();

  await step('provider readiness: key configured vs connection verified', async () => {
    await b.click('[data-testid=open-setup]');
    const dialog = b.getByRole('dialog', { name: 'Setup & providers' });
    assert.match(await dialog.innerText(), /Not checked/);
    await b.click('[data-testid=verify-elevenlabs]');
    await dialog.getByText('Credits used 1,234 / 100,000').waitFor();
    assert.match(await dialog.innerText(), /Verified/);
    await b.screenshot({ path: join(out, 'b1-setup.png') });
    await b.keyboard.press('Escape');
  });
  await step('spoken brief: record (fake mic) → stop → transcribe → edit → use', async () => {
    await b.click('[data-testid=step-brief]');
    await b.fill('[data-testid=topic]', 'Fjordlight pilot (synthetic)');
    const before = mocks.calls.eleven.filter((c) => c.path === '/v1/speech-to-text').length;
    await b.getByRole('button', { name: '● Start recording' }).click();
    await b.getByText(/Recording 0:0[1-9]/).waitFor({ timeout: 5000 });
    assert.equal(mocks.calls.eleven.filter((c) => c.path === '/v1/speech-to-text').length, before, 'nothing sent while recording');
    await b.getByRole('button', { name: '■ Stop' }).click();
    await b.getByRole('button', { name: 'Transcribe (uses credits)' }).click();
    await b.locator('[data-testid=transcript]').waitFor();
    await b.fill('[data-testid=transcript]', (await b.inputValue('[data-testid=transcript]')) + '\nStations near ferry stops');
    await b.getByRole('button', { name: 'Use as brief (replace)' }).click();
    assert.match(await b.inputValue('[data-testid=brief]'), /\[MOCK\] Transcript[\s\S]*Stations near ferry stops/);
    const sttCall = mocks.calls.eleven.filter((c) => c.path === '/v1/speech-to-text').at(-1);
    assert.ok(sttCall.bytes > 1000, 'audio was uploaded');
  });
  await step('AI generation with disclosure, progress and validation', async () => {
    assert.match(await b.locator('[data-testid=data-notice]').innerText(), /sent to\s+Anthropic/);
    await b.fill('[data-testid=slide-count]', '5');
    const brief = await b.inputValue('[data-testid=brief]');
    await b.fill('[data-testid=brief]', `${brief}\nA 3-slide deck is enough`);
    await b.locator('[data-testid=slide-count-conflict]').waitFor();
    assert.equal(await b.isDisabled('[data-testid=generate-ai]'), true, 'no paid request while the count is unresolved');
    assert.equal(mocks.calls.anthropic.filter((c) => c.path === '/v1/messages').length, 0);
    await b.fill('[data-testid=brief]', brief);
    assert.equal(await b.locator('[data-testid=slide-count-conflict]').count(), 0);
    await b.click('[data-testid=generate-ai]');
    await b.getByText('Write slides (5/5)').waitFor({ timeout: 20000 });
    await b.screenshot({ path: join(out, 'b2-generated.png') });
    await b.getByRole('button', { name: 'Open editor →' }).click();
    assert.equal(await b.locator('[data-testid=slide-thumb]').count(), 5);
    assert.equal(await b.locator('[data-testid=slide-thumb] .origin-badge.ai').count(), 5);
    await selectSlide(b, 2);
    assert.match(await b.locator('.flags').innerText(), /No source was given/);
    const outlineCall = mocks.calls.anthropic.find((c) => c.path === '/v1/messages');
    assert.equal(outlineCall.body.messages[0].content.filter((x) => x.type === 'image').length, 2);
  });
  await step('regenerate one slide without touching the others', async () => {
    const before = await thumbLabels(b);
    await selectSlide(b, 3);
    await b.locator('.inspector textarea').filter({ hasText: '' }).last().fill('shorter');
    await b.click('[data-testid=regenerate-slide]');
    await b.waitForFunction(() => document.querySelector('[data-testid=field-title]')?.value.includes('Rewritten'));
    const after = await thumbLabels(b);
    assert.match(after[2], /Rewritten slide 3 \(shorter\)/);
    after.forEach((l, i) => i !== 2 && assert.equal(l, before[i]));
  });
  await step('choose a voice and preview it (free sample)', async () => {
    await b.getByRole('button', { name: 'Narration', exact: true }).click();
    await b.locator('[data-testid=voice-list] li').first().waitFor();
    await b.getByRole('button', { name: 'Preview Mock Voice One' }).click();
    await b.locator('[data-testid=voice-list] li', { hasText: 'Mock Voice One' }).getByRole('button', { name: 'Use' }).click();
    await b.screenshot({ path: join(out, 'b3-narration.png') });
    await b.keyboard.press('Escape');
  });
  await step('narrate one slide after explicit confirmation', async () => {
    await selectSlide(b, 2);
    const before = mocks.calls.eleven.filter((c) => c.path.startsWith('/v1/text-to-speech')).length;
    await b.click('[data-testid=narrate-slide]');
    assert.equal(mocks.calls.eleven.filter((c) => c.path.startsWith('/v1/text-to-speech')).length, before, 'no paid call before confirming');
    await b.click('[data-testid=confirm-narrate]');
    await b.locator('[data-testid=narration-status]', { hasText: 'Up to date' }).waitFor();
    assert.equal(await b.locator('[data-testid=slide-audio]').count(), 1);
    const tts = mocks.calls.eleven.filter((c) => c.path.startsWith('/v1/text-to-speech')).at(-1);
    assert.equal(tts.body.text, '[MOCK] Speaker notes for slide 2.');
  });
  await step('editing notes marks narration outdated; regenerate fixes it', async () => {
    await b.fill('[data-testid=field-notes]', '[MOCK] Speaker notes for slide 2, edited.');
    await b.locator('[data-testid=narration-status]', { hasText: 'Outdated' }).waitFor();
    await b.click('[data-testid=narrate-slide]');
    await b.click('[data-testid=confirm-narrate]');
    await b.locator('[data-testid=narration-status]', { hasText: 'Up to date' }).waitFor();
  });
  await step('unavailable voice shows an actionable error; editing still works', async () => {
    await b.getByRole('button', { name: 'Narration', exact: true }).click();
    await b.locator('[data-testid=voice-list] li', { hasText: 'Unavailable voice' }).getByRole('button', { name: 'Use' }).click();
    await b.keyboard.press('Escape');
    await selectSlide(b, 4);
    await b.click('[data-testid=narrate-slide]');
    await b.click('[data-testid=confirm-narrate]');
    await b.locator('.narration .alert.error').waitFor();
    assert.match(await b.locator('.narration .alert.error').innerText(), /not available to this account[\s\S]*another voice/);
    await b.fill('[data-testid=field-title]', 'Still editable after an audio error');
    assert.match((await thumbLabels(b))[3], /Still editable/);
  });
  await step('narrate the whole deck (missing/outdated only) after confirmation', async () => {
    await b.getByRole('button', { name: 'Narration', exact: true }).click();
    await b.locator('[data-testid=voice-list] li', { hasText: 'Mock Voice One' }).getByRole('button', { name: 'Use' }).click();
    await b.click('[data-testid=narrate-deck]');
    await b.click('[data-testid=confirm-narrate-deck]');
    await b.getByRole('button', { name: /Narrate 0 slide/ }).waitFor({ timeout: 15000 });
    await b.keyboard.press('Escape');
    assert.equal(await b.locator('[data-testid=slide-thumb] .mini.ok').count(), 5);
  });
  await step('presentation mode plays narration, pauses and navigates', async () => {
    await selectSlide(b, 1);
    await b.click('[data-testid=present]');
    await b.locator('.present').waitFor();
    await b.getByText('Play narration').click();
    await b.waitForFunction(() => {
      const a = document.querySelector('.present audio');
      return a && !a.paused && a.currentTime > 0;
    }, null, { timeout: 5000 });
    await b.getByRole('button', { name: '❚❚ Pause' }).click();
    assert.equal(await b.evaluate(() => document.querySelector('.present audio').paused), true);
    await b.keyboard.press('ArrowRight');
    await b.getByText('2 / 5').waitFor();
    await b.screenshot({ path: join(out, 'b4-present.png') });
    await b.keyboard.press('Escape');
    assert.equal(await b.locator('.present').count(), 0);
  });
  let zipPath;
  await step('export PowerPoint + narration ZIP with mapping', async () => {
    await b.click('[data-testid=export]');
    zipPath = await download(b, () => b.click('[data-testid=export-zip]'), 'run-b.zip');
    const zip = await JSZip.loadAsync(readFileSync(zipPath));
    const names = Object.keys(zip.files);
    assert.ok(names.some((n) => n.endsWith('.pptx')));
    for (let i = 1; i <= 5; i++) assert.ok(zip.file(`narration/slide-0${i}.mp3`), `slide-0${i}.mp3`);
    const mapping = JSON.parse(await zip.file('narration/mapping.json').async('string'));
    assert.equal(mapping.slides.length, 5);
    assert.ok(mapping.slides.every((s) => s.status === 'ready'));
    const mp3 = await zip.file('narration/slide-01.mp3').async('nodebuffer');
    assert.ok(mp3.equals(readFileSync(join(root, 'tests', 'fixtures', 'tone.mp3'))));
    const pptxBuf = await zip.file(names.find((n) => n.endsWith('.pptx'))).async('nodebuffer');
    const pptx = await JSZip.loadAsync(pptxBuf);
    const notes = await Promise.all(Object.keys(pptx.files).filter((n) => /notesSlide\d+\.xml$/.test(n)).map((n) => pptx.file(n).async('string')));
    assert.ok(notes.some((n) => n.includes('[MOCK] Speaker notes for slide 2, edited.')));
    assert.equal(Object.keys(pptx.files).filter((n) => /^ppt\/media\/.*\.(mp3|m4a|wav)$/.test(n)).length, 0, 'no audio embedded in pptx');
  });
  await step('API keys never reach the browser, storage, files or logs', async () => {
    const projectB = await download(b, () => b.click('[data-testid=save-project]'), 'run-b.pstudio');
    const html = await b.content();
    const storage = await b.evaluate(() => JSON.stringify({ l: { ...localStorage }, s: { ...sessionStorage } }));
    const status = await (await fetch(`${serverB.url}/api/status`)).text();
    const haystacks = { html, storage, status, project: readFileSync(projectB).toString('latin1'), zip: readFileSync(zipPath).toString('latin1'), serverLog: serverB.logs.join('') };
    for (const [where, text] of Object.entries(haystacks)) {
      assert.ok(!text.includes(ANTHROPIC_KEY), `Anthropic key found in ${where}`);
      assert.ok(!text.includes(ELEVEN_KEY), `ElevenLabs key found in ${where}`);
    }
    const proj = await JSZip.loadAsync(readFileSync(projectB));
    assert.equal(Object.values(proj.files).filter((f) => !f.dir && f.name.startsWith('audio/')).length, 5, 'narration saved with project');
  });
  assert.deepEqual(errorsB, [], 'no uncaught page errors in run B');
  await ctxB.close();
} catch {
  failed = true;
} finally {
  await browser.close();
  serverA.child.kill();
  serverB.child.kill();
  await mocks.close();
  const ok = results.filter((r) => r.ok).length;
  console.log(`\n${ok}/${results.length} e2e steps passed. Artifacts: ${out}`);
  process.exitCode = failed || ok !== results.length ? 1 : 0;
}
