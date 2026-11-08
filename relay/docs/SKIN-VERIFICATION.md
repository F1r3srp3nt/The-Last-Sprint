# Futuristic skin: build, launch and visual verification (Distil and Relay)

The skin has **not been viewed on a Mac yet**: the session that wrote it had no macOS. This file
describes how to build fresh copies, open exactly those copies, and check every screen.

## 1. Build fresh copies and open them by full path

From the root of your `Oslo-Sprint` clone, on the branch that contains the skin:

```bash
cd "$(git rev-parse --show-toplevel)"

# Distil → distil/dist/Distil.app
bash distil/scripts/build-macos.sh   # packaging only; never runs tests
open "$(git rev-parse --show-toplevel)/distil/dist/Distil.app"

# Relay → relay/build/Relay.app
(cd relay && ./scripts/build-app.sh)
open "$(git rev-parse --show-toplevel)/relay/build/Relay.app"
```

Both build scripts print the exact path they built. `open` only brings an already-running copy to the
front, so **quit any running Distil or Relay first**. Alternatively, `distil/scripts/run-latest.sh`
and `relay/scripts/run-latest.sh` quit the running copy and open the fresh one. Nothing is deleted:
older copies elsewhere (Dock, Applications, Downloads, `distil/dist/Token Lab.app`) stay where they
are. Don't launch those.

**Check you are running the fresh copy.** The sidebar's **Build** card shows `version · commit`, and
Settings › *About this build* shows the commit, the build time and "Running from: App bundle: <path>".
The commit must match `git rev-parse --short HEAD`.

## 2. What you should see (both apps, Futuristic appearance)

- Deep navy window with a faint cyan technical grid. No grey title bar or toolbar band.
- Sidebar with a text-only header (**DISTIL** or **RELAY**) and a tagline. The selected row is
  filled teal with a cyan bar on its left and a soft glow. A bordered status card sits at the bottom,
  including the Build row.
- On every page, a cyan monospaced breadcrumb (`DISTIL  /  WORKSPACE`, `RELAY  /  TASKS`) above a bold
  title.
- Navy panels with thin cyan borders.
- Primary buttons: cyan with dark text. Secondary buttons: navy with a cyan border. Text fields: sunken
  navy, with a cyan border while focused.
- Native window controls (close, minimise, zoom), native menus, native alerts, all in dark appearance.

If a Mac set to *Light* mode still shows grey, open Settings › Appearance: it should read
**Futuristic**. Existing installations that were on "Match System" are moved to Futuristic once; an
explicit Light or Dark choice is kept.

## 3. Screen checklist

Check each screen at the default size and at the **minimum window width** (drag the window as
narrow as it goes). Note anything grey, clipped, overlapping or hard to read.

| App | Screen | Check |
|---|---|---|
| Distil | Overview | Breadcrumb and title; panels; empty project state; long project names |
| Distil | Prompt Workspace | Editors (sunken navy, cyan focus); Paste Context sheet is themed; toolbar buttons look native |
| Distil | Comparison | Sidebar still visible and populated (the earlier fix); Run Comparison is cyan; results table readable |
| Distil | Context Library | Search in the toolbar; list has no grey background; select, filter and delete an item |
| Distil | Experiments | List has no grey background; empty state; rename field; segmented picker |
| Distil | Settings | Panels instead of a grey form; Appearance shows Futuristic / Dark / Light / Match System; About this build |
| Relay | Assistant | Input field and push-to-talk; interaction cards; Approve is cyan |
| Relay | Tasks | Add-task field; task rows; Change menu |
| Relay | Warehouse Training | Step card, warnings, language picker, question field |
| Relay | Wybe Runner | Run (cyan) / Stop (red); history scrolls; long messages wrap |
| Relay | Activity | Filter field; channel picker; list has no grey background; long entries |
| Relay | Settings | Appearance segmented picker; readiness; key field (native secure field by design); About this build |

Also check:
- **Relay sidebar width.** Drag the line at the sidebar's edge: the resize cursor appears, and the
  width stays within 200–290 points. Quit and reopen: the width is kept. At the minimum window width
  (980 pt) the sidebar and all its rows stay visible.
- **Keyboard.** Tab through controls: focus is visible on fields and buttons. ↑/↓ moves the sidebar
  selection when it has focus. Menu shortcuts work.
- **Contrast.** System Settings › Accessibility › Display › *Increase contrast* removes the grid and
  glow and strengthens borders. *Reduce motion* removes the selection animation.
- **Appearance switching.** Change Settings › Appearance while the app runs. Dark drops the grid and
  glow; Light switches to the light palette; Futuristic restores them.
- **Long content, empty states, search, selection and scrolling** on each list.

## 4. Screenshots of the running apps

```bash
mkdir -p ~/Desktop/skin-check
screencapture -o -w ~/Desktop/skin-check/distil-overview.png   # then click the Distil window
screencapture -o -w ~/Desktop/skin-check/relay-assistant.png   # then click the Relay window
```

`-w` captures one window after you click it, and `-o` leaves out the shadow. Take one per screen,
plus one at minimum width. Check no API key is visible before sharing any screenshot.

## 5. Known native areas (by design)

- System alerts and confirmation dialogs, open and save panels, menus, the toolbar search field,
  segmented pickers, pop-up menus, steppers and toggles stay native, in the dark appearance.
- Relay's ElevenLabs API-key field stays a native secure field.
- List selection highlights use the system accent colour.
