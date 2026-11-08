// Builds everything the desktop app needs into build/desktop/ and dist/:
//   dist/                     the React client (vite build), served over app://studio
//   build/desktop/main.cjs    Electron main process
//   build/desktop/preload.cjs the sandboxed preload bridge
//   build/desktop/backend.cjs the Express backend with all of its dependencies bundled in,
//                             run by Electron's own Node runtime (no node_modules are shipped)
// Usage: node scripts/build-desktop.mjs [--skip-client]
import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'build', 'desktop');
rmSync(out, { recursive: true, force: true });

if (!process.argv.includes('--skip-client')) {
  console.log('Building the client (vite)…');
  execFileSync(process.execPath, [join(root, 'node_modules', 'vite', 'bin', 'vite.js'), 'build', '--logLevel', 'warn'], { cwd: root, stdio: 'inherit' });
}

const common = {
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node22',
  sourcemap: false,
  legalComments: 'linked',
  logLevel: 'warning',
};
// server/config.ts uses import.meta.url; give the CommonJS backend bundle a real value for it.
// (Not for the preload: a sandboxed preload may require nothing but "electron".)
const importMetaShim = {
  define: { 'import.meta.url': '__ps_import_meta_url' },
  banner: { js: 'const __ps_import_meta_url = require("node:url").pathToFileURL(__filename).href;' },
};

console.log('Bundling main, preload and backend (esbuild)…');
await Promise.all([
  build({ ...common, entryPoints: [join(root, 'desktop', 'main.ts')], outfile: join(out, 'main.cjs'), external: ['electron'] }),
  build({ ...common, entryPoints: [join(root, 'desktop', 'preload.ts')], outfile: join(out, 'preload.cjs'), external: ['electron'] }),
  build({ ...common, ...importMetaShim, entryPoints: [join(root, 'server', 'desktop.ts')], outfile: join(out, 'backend.cjs') }),
]);
console.log('Desktop build ready in build/desktop/ and dist/.');
