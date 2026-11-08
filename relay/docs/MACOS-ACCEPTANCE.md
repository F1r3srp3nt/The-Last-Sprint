# macOS acceptance: build and guided speech setup

Run on a Mac with macOS 14+ and Xcode 15.3+. Keep your ElevenLabs key out of chat, logs,
screenshots and files: paste it only into Relay's Settings field. Real speech requests start only
from buttons in the app (*Check account*, *Test voice*, *Test speech input*), from push-to-talk, or
from spoken replies.

## A. Build verification (automated)

```bash
cd relay
./scripts/verify-macos.sh --launch-check
```

This writes `relay/build/verify-macos.log` with toolchain versions and the output of each stage,
each reported separately:
- the prerequisite check (`scripts/check-prereqs.sh --tests`);
- `scripts/test.sh`: source build, test compilation, test run;
- `scripts/build-app.sh`: `Relay.app`, signature and Info.plist checks;
- the launch check: the app keeps running, and with `--self-check` it reports the bundle, commit and
  windows it loaded.

A failure to compile the tests is reported as such, not as a failure of the app. The log contains no
keys. **Send that file back.** If a stage fails, its compiler errors are in the log.

## B. Guided setup (manual, in the app)

Open `build/Relay.app` and go to **Settings**. "Readiness" is the panel at the top.

| # | Do | Expected |
|---|---|---|
| 1 | Look at Readiness with no key saved. | Key saved: **No**. All checks *Not tested*. Assistant pills: "Not configured — text only". Typing in Assistant works. |
| 2 | Step 1 › *Open API Keys*. | Browser opens `elevenlabs.io/app/api/api-keys`. |
| 3 | Create a key with **Speech to Text** and **Text to Speech** (leave User (read) off for now). Paste it and choose *Save to Keychain*. | Key saved: **Yes**, shown as `••••••••` plus the last 4 characters. Account check, speech input and speech output all stay *Not tested*. The step 1 pill reads "Saved · not verified". |
| 4 | Activity: filter by "settings". | "…saved to the Keychain (not verified yet)". The key itself appears nowhere. |
| 5 | Step 1 › *Check account*. | With User (read) off, Relay shows what ElevenLabs returns. With a permission code (`insufficient_permissions` or `missing_permissions`, on 401 or 403): "reports insufficient permissions" or "reports a missing permission: …" as *needs attention*, naming a permission only if ElevenLabs' message names it. A 403 with no code: "refused access; the cause is not stated". A 401 with no permission code: "did not accept this API key". Speech input and output stay *Not tested* in every case. Note the exact title you saw. |
| 6 | Enable User (read) on the key in ElevenLabs, then *Check account* again. | Account check *Passed*, with the note "This does not test speech". Speech lines stay *Not tested*. |
| 7 | Step 2 › *Open My Voices*. Copy a voice ID (More actions › Copy voice ID), paste it, *Save voice ID*. | "Current voice ID" updates. Speech output *Not tested*. |
| 8 | Paste your API key into the voice-ID field and *Save voice ID*. | Refused ("looks like an API key"). The voice ID is unchanged, and the key appears nowhere in Activity. Clear the field afterwards. |
| 9 | Step 2 › *Test voice*. | One short sentence plays. Speech output tested: *Passed*. *Stop playback* stops it if pressed during playback. |
| 10 | Step 3: the microphone line. Use *Allow microphone…*, or *Open Privacy & Security › Microphone* if denied. | The permission prompt names Relay. Afterwards Microphone permission: *Allowed*. |
| 11 | Step 3 › *Test speech input*, and speak during the 3-second countdown. | "Preparing microphone…", a countdown, then "Transcribing…". Speech input tested: *Passed* with "heard “…”". |
| 12 | *Test speech input*, *Cancel* during the countdown, then **immediately** *Test speech input* again and speak. | The second test completes normally. The cancelled test never overwrites it (Activity: "Discarded a speech-input test result: the test was cancelled or replaced", or nothing if it was cancelled before sending). |
| 13 | Step 4 › Advanced: turn on **Testing aid: wait 5 seconds before each ElevenLabs request**. | Activity: "Testing aid ON". |
| 14 | *Check account*, then within 5 s use *Replace…* to save the same key again. | Account check returns to *Not tested* and stays there. Activity: "Discarded an account-check result: the key changed while the request was pending". |
| 15 | *Test voice*, then within 5 s change **Speech generation model** (step 4). | Speech output stays *Not tested*. Activity: "Discarded a speech-output result…". |
| 16 | *Test speech input*. During "Transcribing…" (the 5-second wait), change **Speech recognition model**. | Speech input stays *Not tested*. Activity: "Discarded a speech-input test result: settings changed…". |
| 17 | *Test voice*, then within 5 s *Use example voice* (or paste another ID). | Speech output stays *Not tested* for the new voice. |
| 18 | Turn the testing aid off. Set both models back with *Reset to recommended*, run *Test voice* and *Test speech input* again. | Both *Passed*. |
| 19 | Assistant: hold the mic, say "start", release, review and edit the transcript, *Send transcript*. | The card shows "Transcribed by ElevenLabs … (edited)" if you edited. The reply is spoken; *Stop playback* works. |
| 20 | Quit Relay (⌘Q) and reopen it. | Key saved: **Yes** (same last 4). Voice ID and models as you left them. Test results are back to *Not tested* (they are kept per session, by design). The testing aid is off. |
| 21 | Terminal: `security find-generic-password -s com.oslosprint.relay -a elevenlabs.api-key` (no `-w`, so the key isn't printed). | One item, labelled "Relay — elevenlabs.api-key". |
| 22 | Step 1 › *Remove* › confirm. Quit and reopen. | Key saved: **No**. Step 21 now reports that the item could not be found. |
| 23 | Make the window as narrow as it allows (minimum 980 pt wide), with the sidebar both shown and hidden. Scroll through Settings. | No clipped or overlapping text. Button rows and readiness lines wrap or stack, and help sections expand. |
| 24 | Activity › *Export…*, then open the file. | No API key anywhere in the file. |

### Model default (check while doing step 4)

- If you used an earlier build and saved settings, the speech generation model stays as saved. For example, "You are using Multilingual v2 from an earlier setup. It is kept as saved…".
- The "About the default" box explains that new setups use Flash v2.5 and why. It also says availability, languages and credit use depend on ElevenLabs and your account or plan, and that Relay never switches models by itself.
- Choose an unavailable model under Advanced (e.g. `eleven_nonexistent`) and run *Test voice*. An error is shown and the model is **not** changed automatically.

### Wybe Night Shift (Settings › Wybe Night Shift)

None of these steps starts a shift. Steps W4–W7 need a real team key; skip them without one.

| # | Do | Expect |
|---|---|---|
| W1 | Open Settings and scroll to *Wybe Night Shift*. | Readiness shows four rows: Key saved, Connection verified, Protocol discovered, Live runner ready — all not done. Step 1 explains that the event code is for the registration page only. |
| W2 | Paste a made-up event code (e.g. `ABC123`) into the team-key field and *Save to Keychain*. | Not saved. The message says team keys start with “ns_” and the event code is only for the registration page. |
| W3 | Paste a key starting with `ns_` and save. | Key saved: done. Connection verified: still not done. The field shows `ns_•••••••• (hidden)` with no key characters. Keychain Access shows an item for service `com.oslosprint.relay.wybe`; the ElevenLabs item is unchanged. |
| W4 | *Check connection*. | The service's reply is shown. If it equals the anonymous greeting, the text says this does not prove the key is accepted. A wrong key shows “refused this team key (HTTP 401)”. |
| W5 | Start *Check connection*, then *Replace…* the key before it finishes (use a slow network or press quickly). | The result is discarded (Activity: “Discarded a connection result …”); Connection verified stays not done. |
| W6 | Record a help request copied from the service's own instructions, with its source, then *Discover protocol*. | Sent once. The answer is shown verbatim; Protocol discovered: done; Live runner ready: not done, “No reviewed command mapping…”. |
| W7 | Try to record a help request containing “start” or no “help”. | Not recorded, with the reason. |
| W8 | *Remove* the Wybe key. | All four rows go back to not done. The ElevenLabs key is still saved. |
| W9 | Activity › *Export…*. | No `ns_` key anywhere in the file. |

## C. What to report back

Send `relay/build/verify-macos.log` and fill in:

```
Core tests passed:            yes / no
macOS app compiled:           yes / no
App launched:                 yes / no
UI checks completed:          list step numbers that passed / failed (with what you saw)
Real transcription succeeded: yes / no / not tried
Real speech playback succeeded: yes / no / not tried
```

For failures, a screenshot of Settings and the matching Activity lines help. Check that no key is
visible before sharing anything.
