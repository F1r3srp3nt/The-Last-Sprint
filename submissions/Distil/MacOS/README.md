# Distil: macOS

**Build uploaded: Distil 1.0.0 for Apple silicon (arm64).** Everything is in [`Distil-1.0.0-osx-arm64/`](Distil-1.0.0-osx-arm64/).

| File | Version | Architecture | Build date | Source commit | Verification status |
|---|---|---|---|---|---|
| [`Distil-1.0.0-osx-arm64.app.zip`](Distil-1.0.0-osx-arm64/Distil-1.0.0-osx-arm64.app.zip) (recommended download) | 1.0.0 (build 1) | arm64 (Apple silicon) | 2026-11-08, 12:42 UTC | Unknown (not recorded in the build) | SHA-256 matches `SHA256SUMS.txt`; contains the same `Distil.app` as below. **Not launched.** |
| [`Distil-1.0.0-osx-arm64.dmg`](Distil-1.0.0-osx-arm64/Distil-1.0.0-osx-arm64.dmg) | 1.0.0 (build 1) | arm64 | 2026-11-08, 12:42 UTC | Unknown | SHA-256 matches `SHA256SUMS.txt`. **Not mounted or launched.** |
| [`Distil.app/`](Distil-1.0.0-osx-arm64/Distil.app/) (unpacked bundle) | 1.0.0 (build 1) | arm64 | 2026-11-08, 12:42 UTC | Unknown | Every file matches `Distil.app.manifest.sha256.txt`; the executable keeps its executable permission. **Not launched.** |

## Details

- **Built by:** HCG Executable Maker. See `.hcg-build.json`: build `7bfe7b15-5cd3-40b6-9977-87bf63f316ed`, project `TokenLab`, product `Distil`, `osx-arm64`.
- **Bundle:**
  - Bundle identifier: `com.hakmicapitalgroup.distil`.
  - Minimum macOS 14.0; built against the macOS 14.0 SDK.
  - Includes an app icon. No other resources.
- **Signing:** the bundle carries a code signature. Maker records it as not signed with a certificate and not notarized, so macOS asks for confirmation the first time (Control-click › Open).
- **Differences from builds made by `distil/scripts/build-macos.sh`:**
  - Bundle identifier: `com.hakmicapitalgroup.distil` instead of `dev.tokenlab.prototype`. Preferences and imported tokenizer files from development builds therefore don't carry over. Saved project files are unaffected.
  - Version: 1.0.0 instead of 0.5.0.
  - No `DistilGitCommit` key, so the sidebar's Build card shows "1.0.0 · dev" instead of a commit.

## What was checked, and what wasn't

Checked on Linux, when the build was added on 2026-11-08:
- the SHA-256 checksums and the per-file manifest;
- `Info.plist`;
- the executable: a Mach-O arm64 binary for macOS 14.0 or later;
- that the `.app.zip` holds a bundle identical to `Distil.app`;
- that the executable contains no credential-shaped strings. It does contain Maker's build paths, which include the macOS user name of the build machine.

**Not yet verified:**
- launching the app;
- `codesign --verify` and Gatekeeper behaviour;
- mounting the DMG.

These need a Mac. Update this table when they are done.

## Adding another build

Upload a `.app` bundle as a ZIP archive, so its bundle structure, executable permissions and signature survive. `ditto` does this; Finder's *Compress* does too:

```bash
ditto -c -k --keepParent "Distil.app" "<name>-<version>-<arch>.zip"
```

Add one row per file to the table above. Only list what was actually checked; write "not verified" otherwise.

Back to [Distil submissions](../README.md).
