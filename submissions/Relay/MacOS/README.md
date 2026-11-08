# Relay: macOS

Packaged Relay build for macOS, made with HCG Executable Maker. It is in
[`Relay-1.0.0-osx-arm64/`](Relay-1.0.0-osx-arm64/).

| File | Version | Architecture | Build date | Source commit | Verification status |
|---|---|---|---|---|---|
| `Relay-1.0.0-osx-arm64/Relay-1.0.0-osx-arm64.app.zip` | 1.0.0 (1) | arm64 | 2026-11-08 | unknown | SHA-256 matches `SHA256SUMS.txt`; not launched |
| `Relay-1.0.0-osx-arm64/Relay-1.0.0-osx-arm64.dmg` | 1.0.0 (1) | arm64 | 2026-11-08 | unknown | SHA-256 matches `SHA256SUMS.txt`; not mounted or launched |
| `Relay-1.0.0-osx-arm64/Relay.app` (unpacked) | 1.0.0 (1) | arm64 (Mach-O) | 2026-11-08 | unknown | Every file matches `Relay.app.manifest.sha256.txt`; not launched |

What the files themselves say:

- **Signing:** `.hcg-build.json` records `"signed": false, "notarized": false`. That means no Developer ID signature and no notarization. The bundle has a `_CodeSignature` seal, probably ad hoc, but `codesign --verify` has not been run. macOS asks for confirmation on first open (Control-click › Open).
- **Identity:** the bundle identifier is `com.hakmicapitalgroup.relay`, version 1.0.0 (1). The source's own script, `relay/scripts/build-app.sh`, uses `com.oslosprint.relay` 0.2.0 (2). Settings saved by a build from that script therefore do not carry over to this one.
- **Source commit:** unknown. The Info.plist has no `RelayGitCommit`, and `.hcg-build.json` records none.
- **Checking:** these checks were made in a Linux container. Nobody has launched this build on a Mac yet.

Back to [Relay submissions](../README.md).
