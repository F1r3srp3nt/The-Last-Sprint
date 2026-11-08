// electron-builder afterPack hook.
// 1. Flip Electron fuses: no ELECTRON_RUN_AS_NODE, no NODE_OPTIONS, no --inspect, app code only
//    from the (integrity-checked) asar, encrypted cookies.
// 2. On macOS, ad-hoc sign the whole .app afterwards. Apple Silicon refuses to run code whose
//    signature is broken, and flipping fuses or editing Info.plist breaks Electron's original one.
//    A Developer ID signature and notarisation can replace this later (docs/DESKTOP.md).
const { execFileSync } = require('node:child_process');
const { join } = require('node:path');
const { FuseV1Options, FuseVersion } = require('@electron/fuses');

exports.default = async function afterPack(context) {
  await context.packager.addElectronFuses(context, {
    version: FuseVersion.V1,
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableCookieEncryption]: true,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true,
    [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
  });
  if (context.electronPlatformName !== 'darwin') return;
  const app = join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`);
  if (process.platform !== 'darwin') {
    console.log(`  • not on macOS: skipping ad-hoc signing of ${app}`);
    return;
  }
  console.log(`  • ad-hoc signing ${app}`);
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'inherit' });
  execFileSync('codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], { stdio: 'inherit' });
};
