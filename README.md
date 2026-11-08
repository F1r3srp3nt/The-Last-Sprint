# The-Last-Sprint
Because of sickness I wasn't able to complete what in really would be able to prove as Oslo-Sprint was only worked on for around 15 hours and not 48 Hours

This repository contains the full Oslo-Sprint project, including its commit history, merged from [F1r3srp3nt/Oslo-Sprint](https://github.com/F1r3srp3nt/Oslo-Sprint).

---

![HCG × Oslo Sprint 2026 banner: "Distil + Relay — one weekend, two builds", over the Oslo waterfront at night](docs/assets/hcg-oslo-sprint-2026.png)

## Oslo-Sprint

Programs made during Oslo Sprint 2026. Each product is self-contained in its own folder, and the products share no code. Distil and Relay are Swift packages; Presentation Studio is a TypeScript web app.

| Folder | Product | What it is |
|---|---|---|
| [`distil/`](distil/README.md) | **Distil** | macOS app that selects the context a model needs for a task. It shows every decision and compares answers from the full and the reduced prompt. [Read the Distil README](distil/README.md) · [screenshots](distil/README.md#screenshots) |
| [`relay/`](relay/README.md) | **Relay** | macOS technical assistant for the Wybe Night Shift, Holio warehouse and ElevenLabs side challenges, with a headless runner. [Read the Relay README](relay/README.md) · [screenshots](relay/README.md#screenshots) |
| [`presentation-studio/`](presentation-studio/README.md) | **Presentation Studio** | Web app that turns uploaded images and a brief into an editable PowerPoint deck, with an optional spoken brief and slide narration through ElevenLabs. [Read the Presentation Studio README](presentation-studio/README.md) |

All names are working names.

## Submissions

Packaged competition builds go in [`submissions/`](submissions/README.md), one folder per product ([Distil](submissions/Distil/README.md), [Relay](submissions/Relay/README.md), [Presentation Studio](submissions/Presentation%20Studio/README.md)) and per operating system. Each folder says whether a build has been uploaded and what was verified. A folder existing does not mean that platform is supported.

## Requirements

- macOS 14 or later and Xcode 15 or later (Swift 5.9+) for the macOS apps.
- The core libraries and tests of Distil and Relay also build with any Swift 5.9+ toolchain on Linux.
- Distil and Relay use no third-party packages.
- Presentation Studio needs Node.js 22.12 or newer and npm. Its dependencies are listed in `presentation-studio/package.json`.

## Build and test

Each command works from any folder, and on a Mac each one starts by checking the developer tools. Testing and packaging are separate: packaging never compiles the test targets.

**1. Check this Mac** (read-only; it prints the exact fix for anything missing and never changes your developer-tool selection):

```sh
bash distil/scripts/check-prereqs.sh --tests
bash relay/scripts/check-prereqs.sh --tests
```

**2. Build and open the apps** (each packages a fresh, ad-hoc-signed bundle, quits a running copy, and opens exactly the new one only if every step succeeded; add `--test` to run the tests first):

```sh
bash distil/scripts/run-latest.sh      # → distil/dist/Distil.app
bash relay/scripts/run-latest.sh       # → relay/build/Relay.app
```

**Separate steps**

| | Distil | Relay |
|---|---|---|
| Tests (need full Xcode on a Mac; also run on Linux) | `bash distil/scripts/test.sh` | `bash relay/scripts/test.sh` |
| Package only | `bash distil/scripts/build-macos.sh` | `bash relay/scripts/build-app.sh` |
| Run from SwiftPM (no bundle) | `cd distil && swift run Distil` | `cd relay && swift run Relay` |
| Headless runner | — | `cd relay && swift run relay-runner help` |

In Xcode, open `distil/Package.swift` (scheme **Distil**) or `relay/Package.swift` (scheme **Relay**). Distil's package and modules keep their internal names (`TokenLab*`); its executable product is `Distil`. Both bundle identifiers are unchanged, so preferences and saved data carry over.

**Troubleshooting**

| Message | What failed | Fix |
|---|---|---|
| `no such module 'XCTest'` (often followed by `fatalError`) | Compiling the **tests**, not the app: the selected developer tools are the Command Line Tools, which usually lack XCTest | Run the check above. Use Xcode for that command (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash distil/scripts/test.sh`) or select it yourself (`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`). Packaging works without it. |
| `Tests did NOT run: the package's own sources failed to compile` | `scripts/test.sh` stage 1: a compile error in the app or a library. Nothing was launched | The first errors are printed; the full log is in `.build/test.log` |
| `Tests did NOT run: the test targets failed to compile` | `scripts/test.sh` stage 2: a compile error in the tests. Nothing was launched | Same |
| `no executable product named 'TokenLab'` | The command asked for an old product name | Distil's product is `Distil` (since 0.5); `TokenLab` is only the package name |
| HCG Executable Maker shows **Unrecognized** | That Maker build predates its Swift support | See [`docs/EXECUTABLE-MAKER.md`](docs/EXECUTABLE-MAKER.md) |
| The app opens but closes at once | A launch crash | `run-latest.sh` reports it; look in Console › Crash Reports |

CI also opens each packaged app with `--self-check`: the running app reports its bundle identifier, the commit in its Info.plist and its visible windows, and the check fails if any of them is wrong (`.github/scripts/self-check.sh`). Ordinary launches never pass that option.

Downloadable test builds of both apps (zipped `.app`, ad hoc signed, kept 14 days) are attached to each macOS CI run under *Artifacts*. They are not releases; macOS asks for confirmation the first time (Control-click › Open).

**Presentation Studio**

```sh
cd presentation-studio
npm install
cp .env.example .env              # optional: add provider keys
npm run dev                       # open http://127.0.0.1:5173
npm test                          # unit and API tests
npm run test:e2e                  # browser end-to-end test (Playwright + Chromium)
```

Each product's README has full instructions, its verification status, its limitations and a first-launch checklist.

## Status

- **Linux:** the core libraries and tests of both products build and pass on Linux.
- **macOS:** GitHub Actions also builds both macOS apps on a macOS 15 runner, launches them and saves window screenshots ([`.github/workflows/`](.github/workflows/)). The screenshots in each product README come from those runs.
- **Not yet tested on a Mac:** interaction, speech, and accessibility have not been checked by a person on a Mac.
- **Presentation Studio:** unit, API and browser end-to-end tests pass on Linux against mock providers, and GitHub Actions runs them on every change to `presentation-studio/` ([`presentation-studio.yml`](.github/workflows/presentation-studio.yml)). Real Anthropic and ElevenLabs calls, and opening exports in Microsoft PowerPoint, have not been verified yet.

See each product's README for details.

## Working here

- All Distil work goes in `distil/`, all Relay work goes in `relay/`, and all Presentation Studio work goes in `presentation-studio/`.
- Keep each product's source, tests, scripts and documentation inside its folder. Shared repository files belong at the root.
- Never commit credentials, build output (`.build/`, `build/`, `dist/`, `node_modules/`) or local settings (such as `presentation-studio/.env`). For Relay, run `relay/scripts/check-no-secrets.sh` before committing.
