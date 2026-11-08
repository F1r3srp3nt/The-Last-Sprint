# Building Distil and Relay with HCG Executable Maker

This is a handoff for the separate [HCG-Executable-Maker](https://github.com/F1r3srp3nt/HCG-Executable-Maker)
project. Nothing here changes Maker; all Maker changes belong in that repository.

**Status:** Maker's Swift support was read, not run. Nobody has yet built current Oslo-Sprint with Maker.
The findings below come from Maker's source and docs at commit `8cd38ae` (2026-11-08, "Merge feature/swift-macos").

## Why Maker showed both projects as "Unrecognized", and why `TokenLab` failed

| Symptom | Cause | Fix |
|---|---|---|
| Both projects **Unrecognized** | That status only appears when no inspector matches. It comes with the text "No supported project files were found. M0.1 builds .NET projects". The Swift inspector, which matches any `Package.swift` outside build folders, arrived with `8cd38ae`. Older Maker builds (0.1.0, 0.2.0 and anything before that merge) don't have it. | Use a Maker build that includes `8cd38ae` or later. |
| `no executable product named 'TokenLab'` | Distil's executable product was renamed from `TokenLab` to `Distil` in Oslo-Sprint `97b5526` (Distil 0.5). The package itself is still named `TokenLab`. Maker's docs and CI still use `--product TokenLab` against the old pinned commit `4543125`. | Choose product **`Distil`**. In Maker: see "Changes needed in Maker" below. |

## What to detect

Oslo-Sprint has two independent Swift packages. Neither is at the repository root.

| | Distil | Relay |
|---|---|---|
| Package root | `distil/` (`distil/Package.swift`) | `relay/` (`relay/Package.swift`) |
| Package name | `TokenLab` (kept for continuity) | `Relay` |
| Tools version / minimum macOS | 5.9 / macOS 14 | 5.9 / macOS 14 |
| GUI executable product → target | **`Distil`** → `TokenLabApp` (SwiftUI) | **`Relay`** → `RelayApp` (SwiftUI) |
| Command-line executable | — | `relay-runner` → `RelayRunner` |
| Libraries | `TokenLabCore` | `RelayCore`, `RelayAdapters` |
| Test targets | `TokenLabCoreTests` | `RelayCoreTests`, `RelayAdaptersTests` |
| Conditional products | Yes: the GUI products are declared under `#if os(macOS)`, so `swift package dump-package` lists them only on a Mac | Same |
| Package dependencies | None | None |
| SwiftPM resources | None | None |
| App icon | None | None |

## How to build (exactly what the repository's own scripts do)

```sh
# Distil — packaging only (never compiles test targets)
cd distil && swift build -c release --product Distil
# Relay
cd relay && swift build -c release --product Relay
cd relay && swift build -c release --product relay-runner   # CLI
```

The executable is at `$(swift build -c release --show-bin-path)/<product>`. Tests are separate (`swift test`) and need
full Xcode: with only the Command Line Tools selected they usually fail with `no such module 'XCTest'`. That failure
is in the test build; it says nothing about whether the app compiles or launches.

## Expected bundles

| | Distil.app | Relay.app |
|---|---|---|
| `Contents/MacOS/` | `Distil` only | `Relay` only |
| `CFBundleExecutable` | `Distil` | `Relay` |
| `CFBundleName` / display name | Distil | Relay |
| `CFBundleIdentifier` (**keep**; user data depends on it) | `dev.tokenlab.prototype` | `com.oslosprint.relay` |
| Version / build | 0.5.0 / 5 | 0.2.0 / 2 |
| `LSMinimumSystemVersion` | 14.0 | 14.0 |
| `LSApplicationCategoryType` | `public.app-category.developer-tools` | (none set) |
| Privacy keys | none | `NSMicrophoneUsageDescription`: "Relay records only while you hold the push-to-talk button, and sends that recording to ElevenLabs for transcription." (Maker's scanner detects the microphone use in `RelayApp/Support/Audio.swift`.) |
| Optional build identity | `DistilGitCommit`, `DistilBuildDate` | `RelayGitCommit`, `RelayBuildDate` |
| Signing | ad hoc (`codesign --sign -`) | ad hoc |

The build-identity keys are optional. Without them the app's Build card shows the version and "dev" instead of a commit.

The reference bundles are produced by `distil/scripts/build-macos.sh` and `relay/scripts/build-app.sh`. Compare
Maker's output with those.

## Changes needed in Maker (for its own project)

1. **`docs/SWIFT-MACOS.md`:** Distil's product is `Distil`, not `TokenLab`. The executable and the bundle are both
   `Distil`.
2. **`.github/workflows/build.yml` (`swift-macos` job):**
   - Pin `OSLO_COMMIT` to a current Oslo-Sprint `main` commit (any commit from `97b5526` on).
   - Use `--product Distil --expect-products Distil`.
   - Use Distil 0.5.0 (5) and Relay 0.2.0 (2).
   - Keeping the old pin builds an outdated Distil (0.4). Moving the pin but keeping `TokenLab` fails with
     "no executable product named 'TokenLab'".
3. **`tools/ui-driver/Program.cs`:** the usage comments name `TokenLab`.
4. **`CHANGELOG.md`:** still says `feature/swift-macos` is "not merged".
5. **Unrecognized text:** "M0.1 builds .NET projects" no longer describes what Maker supports.

Maker has no configuration file that lives in a project repository: package, product, bundle ID and the rest are chosen
in its wizard. So this repository contains no Maker configuration.

## Acceptance check for Maker

1. On a Mac with Xcode selected, use Maker built from `8cd38ae` or later.
2. Import Oslo-Sprint `main`.
3. Inspect: both `distil/` and `relay/` should be listed, with neither pre-selected.
4. Evaluate `distil/`: products `Distil` (executable), `TokenLabCore` (library), tests `TokenLabCoreTests`.
5. Build `Distil` as above.
6. Expected result: `Distil.app` launches and its Build card shows 0.5.0.
7. Repeat for `relay/` with product `Relay` and the microphone text.
