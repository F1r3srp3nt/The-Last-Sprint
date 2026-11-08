# Presentation Studio desktop app

Presentation Studio also runs as a standalone desktop app (Electron). On the user's Mac it is a
normal `Presentation Studio.app`: double-click to open. No Terminal, browser tab, npm command or
separately installed Node.js is needed. The editor, image import, project save/open, editable
PowerPoint export, AI generation and the ElevenLabs voice features are the same as in the web
version.

## How it is put together

| Part | What it is | Where |
|---|---|---|
| Main process | Window, menus, dialogs, key storage, starts and stops the backend | `desktop/main.ts` → `build/desktop/main.cjs` |
| Backend | The existing Express server (`server/`), bundled with all of its dependencies into one file and run in an Electron **utility process** on Electron's own Node runtime | `server/desktop.ts` → `build/desktop/backend.cjs` |
| Renderer | The existing React client (`src/client`), built by Vite | `dist/` |
| Bridge | The only API the window gets from the main process | `desktop/preload.ts` |

All of it is packed into `app.asar` inside the app. No `node_modules` folder is shipped.

**Startup.** The main process opens the window and starts the backend at the same time. The
backend gets a per-launch random token and the saved keys over its private message channel (not
environment variables or the command line), listens on `127.0.0.1` on a random free port and
reports `ready`. Requests that arrive before that wait for it (up to 20 seconds).

**Requests.** The window loads `app://studio/`, a private scheme served from the app bundle with
a strict Content-Security-Policy. When the client calls `/api/…`, the main process forwards the
request to the backend and adds the token. The backend refuses every request without the token,
so other programs on the computer cannot use it or the stored keys.

**Errors.** If the backend fails to start or stops, the window shows a banner with **Restart
server**. A crash is restarted automatically twice. Editing, saving and PowerPoint export keep
working without the backend; only AI generation and voice need it.

**Shutdown.** Closing the window quits the app. The main process asks the backend to stop, waits
for it (3 seconds at most, then kills it) and exits. Closing with unsaved changes asks first.

## Security model

- The renderer runs **sandboxed**, with **context isolation** and **no Node integration**. It
  cannot use `require`, `process`, Electron or `ipcRenderer`.
- The bridge (`window.presentationStudioDesktop`) has a fixed set of functions:
  `credentials.status/save/clear`, `files.save/openProject` and `backend.status/restart/onChange`.
  The main process checks that every call comes from `app://studio` and validates its payload
  (Zod schemas in `desktop/ipc.ts`). Anything else is refused. **No function returns a key.**
- Navigation away from the app is blocked. `https` links open in the default browser. New
  windows, `<webview>` and downloads are blocked (files are written only through the save dialog).
  The only permission granted is the microphone, for the spoken brief.
- Electron fuses (set in `desktop/build/after-pack.cjs`): no `ELECTRON_RUN_AS_NODE`, no
  `NODE_OPTIONS`, no `--inspect`, app code only from the integrity-checked `app.asar`, encrypted
  cookies. DevTools are off in packaged builds.

## Provider keys

Keys are entered in the app: **AI / Voice** button → *Setup & providers* → paste the key →
**Save key**. **Replace…** and **Remove** are next to a saved key.

- Keys are encrypted with Electron `safeStorage`. On a Mac its encryption key lives in the
  **macOS Keychain** (an item named "Presentation Studio Safe Storage"). The encrypted values are
  stored in `~/Library/Application Support/Presentation Studio/credentials.json` (file mode 600).
- If no secure OS store is available (for example Linux without a keyring), keys are **not
  saved** and Setup says so. There is no plain-text fallback.
- Keys stay in the main process and the backend process. They are never sent to the window,
  written into projects or exports, or logged. `.env` files and environment variables are not
  read by the desktop app.
- Saving a key does not check it: use **Verify connection**.

## Development

Requires Node.js 22.12+ and npm on the developer's machine only.

```bash
cd presentation-studio
```

```bash
npm install
```

| Script | What it does |
|---|---|
| `npm run desktop:dev` | Builds everything and opens the app unpackaged (`electron .`), with DevTools available |
| `npm run desktop:build` | Builds `dist/` and `build/desktop/` only |
| `npm run desktop:pack` | Builds and packages an unpacked app for the current platform into `release/` |
| `npm run desktop:dist:mac` | On a Mac: builds `release/mac-arm64/Presentation Studio.app` and `release/Presentation-Studio-<version>-arm64.dmg` |
| `npm run desktop:test` | End-to-end test of the **packaged** app (run `desktop:pack` first) |

The web scripts (`npm run dev`, `npm start`, `npm test`, `npm run test:e2e`) are unchanged.

## Packaging for macOS (Apple Silicon)

The app icon is the HCG logo: `desktop/resources/icon.icns` (macOS) and `icon.png`, generated with
the in-app mark and favicon by `docs/assets/hcg/make_hcg_assets.py` at the repository root.

On a Mac with Apple Silicon (or any Mac with Xcode command line tools):

```bash
npm run desktop:dist:mac
```

The `.app` is ad-hoc signed (`codesign --sign -`) after the fuses are flipped, so it runs on
Apple Silicon. There is **no Developer ID signature and no notarisation**: a DMG downloaded from
the internet is blocked by Gatekeeper the first time. Open it with Control-click › *Open*, or
remove the quarantine flag (`xattr -dr com.apple.quarantine "/Applications/Presentation Studio.app"`).
To distribute it normally, set `mac.identity` to a Developer ID Application certificate, enable
`hardenedRuntime` (with `com.apple.security.device.audio-input`) and notarise.

The GitHub workflow's `desktop-macos` job builds the `.app` and DMG on an Apple Silicon runner,
checks the signature, bundle and fuses, runs the packaged-app test and keeps the DMG for 14 days
as a build artifact. It does not publish a release.

A DMG cannot be built on Linux (it needs `hdiutil`). `npx electron-builder --mac dir --arm64`
does build the `.app` folder on Linux, without signing, which is useful for inspecting it.

## The packaged-app test

`e2e/run-desktop-e2e.mjs` copies the packaged app to a temporary folder outside the checkout,
hides the checkout's `dist/` and `build/`, and starts it with an empty environment (no Node.js on
`PATH`). It drives the window over the Chrome DevTools protocol, then checks:

- the window, isolation, the bridge, the CSP and refused IPC payloads;
- that the backend refuses requests without the token;
- image import, a template deck, save, new project, reopen, PPTX export (checked with
  python-pptx when available);
- keys entered in Setup, ElevenLabs verify and narration against a **mock** server, audio
  playback in presentation mode, and the narration ZIP export;
- that keys never reach the window, web storage, saved files or logs;
- that closing the window stops the backend and leaves no processes;
- a second launch with the saved keys, then removing one.

Native dialogs cannot be clicked over CDP, so the test sets these variables. They are honoured
only when `PRESENTATION_STUDIO_E2E_DIR` is set:

| Variable | Effect |
|---|---|
| `PRESENTATION_STUDIO_E2E_DIR` | User data lives here; save dialogs write files here without asking |
| `PRESENTATION_STUDIO_E2E_OPEN` | The file the open dialog returns |
| `PRESENTATION_STUDIO_E2E_TEST_KEYSTORE=1` | Keys go into a labelled **non-secure** test store instead of the OS store |
| `PRESENTATION_STUDIO_E2E_ANTHROPIC_BASE_URL`, `…_ELEVENLABS_BASE_URL` | Local mock providers (only `http://127.0.0.1` or `localhost` URLs are accepted) |

Setting environment variables for the app already requires the user's own account, so these
hooks give nothing to anyone who doesn't already control that account.

## Not done yet

- Developer ID signing and notarisation (needs an Apple Developer account).
- Windows and Linux installers (Linux is packaged only for testing).
- Automatic updates.
