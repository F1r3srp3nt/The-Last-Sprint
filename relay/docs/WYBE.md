# Wybe Night Shift — connection setup and runner design

## Event code and team key are two different things

- The **event code** is shown on the screen at the venue. It is typed once, into the organisers'
  registration page (<https://nightshift-board.wybe.me/join>), to register the team. Relay never
  asks for it, stores it or sends it, and no event code is written anywhere in this repository.
- Registration then shows the **team key** once. It starts with `ns_`. That key is the credential
  Relay sends to the endpoint, as `Authorization: Bearer <key>`. No team key is written anywhere
  in this repository either; tests use obvious fakes such as `ns_FAKEtestKEY…`.
- If the key is lost, an organiser at the venue can issue a new one. Keep it secret: one key per team.

Relay registered nothing; registering is the team's decision.

## What is known (organiser material and observed responses only)

**Registration page** (`https://nightshift-board.wybe.me/join`), read on 2026-11-07 and again on
2026-11-08 without submitting anything:
- The form asks for a team name (shown on the leaderboard), the event code from the screen at the
  venue, 1–6 member names, and an optional contact e-mail.
- On success the page shows the team key **once** (keys start with `ns_`) and a key card:
  - Endpoint: `https://nightshift.wybe.me/`
  - "Send it as: Authorization: Bearer <key>"
  - "Score as high as you can before Sunday 13:00." — "Anything goes, as long as it talks to the endpoint."
- Teams can practise right away; organisers approve teams before the final.
- The page also has a "Registration is closed — talk to an organizer at the venue" state.

**Endpoint**: an unauthenticated `GET https://nightshift.wybe.me/` (2026-11-07, repeated once on
2026-11-08) returned HTTP 200, `content-type: application/json`:
`{"ok":true,"result":"Hotel Wybe night shift terminal. Speak JSON. Most things start with help."}`.
Nothing else was sent: no key, and no guessed paths.

## Still unresolved

These can only be learned from the service with a team key. Relay keeps them explicitly open
(`WybeIntegration.requirements`, shown in Settings and by `relay-runner wybe-live`):

1. **How to send a help request.** "Speak JSON. Most things start with help." does not say which
   path, method or JSON body. Relay does not guess it; the team records the form the service or
   the organisers describe (see setup step 4).
2. **The robot's command list** (expected in the help answer).
3. **The task and observation format.**
4. **Whether actions are safe to retry**, or can be status-checked after a lost response.
5. **Rate limits, penalties and scoring** for practice and final shifts.
6. **A reviewed command mapping and a live policy** (`WybeProtocolMapping`, `ShiftPolicy`).
   `WybeProtocolMappings.reviewed` is `nil`, so the live runner refuses to start.

## Setup steps

Every request below is read-only and starts only when you ask for it. None of them starts a shift.

### In Relay.app (Settings › Wybe Night Shift)

1. **Register** on the organisers' page with the event code (button *Open challenge registration*).
   Copy the team key at once.
2. **Team key**: paste it into the masked field and choose *Save to Keychain*. It is stored as a
   generic password under service `com.oslosprint.relay.wybe`, account `wybe.team-key` —
   a separate entry from the ElevenLabs key (`com.oslosprint.relay` / `elevenlabs.api-key`).
   *Replace…* and *Remove* work on that entry only. The field refuses text that doesn't start with
   `ns_` (for example an event code), text with spaces, and a leading "Bearer". The saved key is
   shown as `ns_•••••••• (hidden)`: no character of the key appears on screen, so screenshots are safe.
   Saving does **not** mark anything as working.
3. **Check connection** sends one `GET https://nightshift.wybe.me/` with the key — the only request
   whose form has been observed — and shows the service's reply. Because the anonymous reply to
   the same request is already known, an identical reply is reported as "reachable, key not
   refused", not as proof that the key is accepted. HTTP 401 means the key was refused; HTTP 403
   is reported without guessing the cause (wrong key or team not yet approved).
4. **Discover the protocol**: record the help request exactly as the service describes it (method,
   path relative to the endpoint, JSON body for POST, and where you saw that form), then choose
   *Discover protocol*. It is sent once and never retried automatically. Relay refuses to send a
   request that doesn't mention "help", contains a key, contains words such as "start" or "shift",
   or points anywhere but the endpoint host. The answer is shown verbatim and is not turned into
   commands automatically.
5. The **readiness panel** keeps four facts apart: *Key saved*, *Connection verified*, *Protocol
   discovered*, *Live runner ready*. Replacing or removing the key resets the later facts, and
   changing the help request resets discovery. An answer that arrives after such a change is
   discarded (logged as "Discarded …") and never marks the new settings as working.

### From the command line (`relay-runner`)

```bash
cd relay
swift build
# The key is never passed as an argument (it would show in the process list). Use one of:
#   WYBE_TEAM_KEY in the environment, --key-file PATH (outside the repository), or --keychain (macOS).
read -rs WYBE_TEAM_KEY && export WYBE_TEAM_KEY            # paste the key; nothing is echoed
swift run relay-runner wybe-connect                       # one authenticated GET /
swift run relay-runner wybe-help --method POST --path / \
  --body '<the JSON body exactly as the service describes it>' \
  --source '<where you saw this form>'                    # sends the help request once
swift run relay-runner wybe-live                          # readiness summary; sends nothing; exit 2
swift run relay-runner wybe-live --start                  # refused in this build; sends nothing; exit 2
```

Exit codes: 0 success, 1 network/server/format problem, 3 key refused (401/403), 64 not sent
(no key, invalid key or invalid help request), 2 for `wybe-live`.

### What was verified, and how

| Step | Verified | How |
|---|---|---|
| Registration page content, key card, `ns_` prefix | Yes, 2026-11-08 | Read the page's HTML and script without submitting |
| Unauthenticated `GET /` reply | Yes, 2026-11-08 | One `curl` request; same reply as on 2026-11-07 |
| Request form, Bearer header, host restriction, size and time bounds, rate limiting, error classification, stale-result rejection, redaction | Yes, against a scripted transport | `swift test` (Linux, Swift 6.0.3) |
| `wybe-live`, `wybe-live --start`, and refusal of a missing key, an event code and invalid help requests | Yes, offline | Ran `relay-runner` in the CI image; nothing was sent |
| `wybe-connect` / `wybe-help` with a real team key | **No** | No team key was available |
| The Settings panel in Relay.app | **No** | Not built or run on a Mac in this change; the macOS CI job compiles it |
| Any live shift | **No, by design** | Nothing starts a shift |

## Live adapter (implemented, waiting for a reviewed mapping)

`WybeClient` (RelayAdapters) talks to the endpoint:
- Sends the key only as `Authorization: Bearer <key>`, never in a URL or body, and registers it
  with the redactor first. Requests can only go to `nightshift.wybe.me`; relative paths only.
- Every request is rate limited (at most one per second by default; a 429 pauses further requests
  for its Retry-After, or 10 s), time bounded (10 s), size bounded (256 KB) and cancellable.
- An answer counts only if it is a JSON object with a boolean `ok` — the only shape observed.
  Anything else is "unexpected format" and nothing is assumed from it.
- The client never retries by itself.

`LiveNightShiftAdapter` (RelayAdapters) implements `ChallengeAdapter` for the runner. Without a key
or without a reviewed `WybeProtocolMapping` every call throws `contractUnavailable` before
anything is sent. With a mapping:
- **Reads** (capabilities, observe, status, score) map timeouts and network/server/format problems
  to `.transient`, so the runner may retry them within its bounds.
- **Actions**: a timeout, network error, server error, malformed answer, rate limit (whether a
  rate-limited action was applied is not documented), or an answer that arrives after the key or
  settings changed are all `.ambiguous`. The runner then never blindly repeats a consequential
  action. `ok:false` is recorded as the service declining the action.
- A refused key (401/403) or a settings change stops the run.
- Commands starting with `sim.` are refused, so simulator vocabulary never reaches the live
  service, and the only live score is one the service reports, labelled LIVE.

### Adding the reviewed mapping later

1. Obtain the help answer (step 4). Write a `WybeProtocolMapping` that uses only the names, fields
   and request forms that answer documents, and mark every command that changes the world as
   `consequential`. Set `WybeProtocolMappings.reviewed` to it.
2. Write a `ShiftPolicy` for the real command vocabulary.
3. Configure `RunnerConfiguration(expectedMode: .live, allowedActions: [...exact names...])` with a
   `minRequestInterval` that respects the published limits.
4. Let `relay-runner wybe-live --start` (and only an explicit operator action) start a run.

## Runner architecture (implemented)

```
ChallengeAdapter (protocol)        ShiftPolicy (protocol)
  discoverCapabilities()             decide(observation, usable, excluded) -> act | finish
  observe()                          reconcile(request, before, after) -> applied | notApplied | unknown
  perform(request)
  status(of: idempotencyKey)
  scoreReport() -> LabeledScore?     AutonomousRunner (actor) — headless
                                       allow-list ∩ discovered commands
                                       precondition check against the latest observation
                                       rate limiter (min interval + server pause)
                                       timeout on every request
                                       bounded retries with exponential backoff
                                       ambiguous-failure reconciliation
                                       stop signal checked before every request
                                       stops at once if the contract becomes unavailable
                                       action history + mode-labelled log
```

- **Allowed actions and preconditions:** `ActionSpec` (with `consequential` flag and
  `Precondition`s) plus `RunnerConfiguration.allowedActions`. A command that wasn't discovered,
  isn't in the allow-list, or whose preconditions fail is recorded as blocked and never sent.
- **Ambiguous failures:** after a timeout or lost response, a *consequential* action is never
  simply resent. The runner asks `status(of:)` if the service supports it, otherwise compares
  observations. Applied → confirmed. Definitely not applied → retry (same idempotency key,
  bounded). Unknown → the task is set aside and the action is **not** repeated.
- **Stop control:** `StopSignal` is checked before every request, including retries. CLI: Ctrl-C
  (second press exits), `--stop-file PATH`, `--stop-after N`. App: Stop button / ⌘. An in-flight
  request cannot be recalled; if it is interrupted, its outcome is recorded as unknown.
- **Separation of simulation and live:** every report, record and log entry carries an
  `ExecutionMode`. The runner refuses to start when the adapter's mode differs from the configured
  one. Simulated scores say "SIMULATED — … not a challenge result".

## The simulator (clearly not Wybe)

`SimulatedNightShift` is deterministic per seed. Its hotel layout, `sim.`-prefixed commands
(`sim.move`, `sim.pickup`, `sim.deliver`, `sim.inspect`, `sim.defer`), task values, penalties and
fault injection (refused, rate-limited, hung, applied-but-response-lost) were all invented to
exercise the runner. Its scores do not predict challenge performance.
