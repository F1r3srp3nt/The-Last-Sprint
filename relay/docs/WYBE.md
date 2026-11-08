# Wybe Night Shift — status and runner design

## What is known (from the event briefing only)

- Join page: `https://nightshift-board.wybe.me/join`
- The agent must discover which commands the robot understands.
- Tasks include towels, lost items and room checks; there are more tasks than the robot can finish.
- Good judgement earns points; careless actions lose points.
- Practice closes Sunday 8 November, 11:45 Oslo time. Final: 12:00–13:00, ten secret shifts,
  highest average final score wins. The agent runs autonomously in the final.
- Do not attack or overload the server.

## What the organisers publish (read 2026-11-07, read-only)

**Registration page** (`https://nightshift-board.wybe.me/join`), read without submitting anything:
- The form asks for a team name (shown on the leaderboard), the event code from the screen at the venue, 1–6 member names, and an optional contact e-mail.
- On success the page shows a team key **once**. Keys start with `ns_`, and an organiser at the venue can issue a new one if it is lost.
- It also shows a key card:
  - Endpoint: `https://nightshift.wybe.me/`
  - "Send it as: Authorization: Bearer <key>"
  - "Score as high as you can before Sunday 13:00."
  - "Anything goes, as long as it talks to the endpoint."
- Teams can practise right away, and organisers approve teams before the final.
- The page also has a "Registration is closed — talk to an organizer at the venue" state.

**Endpoint**: one unauthenticated `GET https://nightshift.wybe.me/` returned
`{"ok":true,"result":"Hotel Wybe night shift terminal. Speak JSON. Most things start with help."}`.
Nothing else was sent: no key, and no guessed paths.

## Still missing

Relay registered nothing; registering is your decision. These must be discovered with the team key and are shown as a checklist in Settings (`WybeIntegration.requirements`):

1. The exact JSON request and response format ("Speak JSON").
2. The robot's command list ("most things start with help").
3. The task and observation format.
4. Whether actions are safe to retry, or can be status-checked after a lost response.
5. Rate limits, penalties, and how practice and final shifts are scored.
6. **Relay's live adapter itself.** `LiveNightShiftAdapter` is still a placeholder that sends nothing. Entering a team key will not connect Relay; the adapter has to be written once the format is known.

## Runner architecture (implemented, simulated)

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
                                       action history + mode-labelled log
```

- **Observations and task state:** `Observation` / `ChallengeTask`.
- **Allowed actions and preconditions:** `ActionSpec` (with `consequential` flag and
  `Precondition`s) plus `RunnerConfiguration.allowedActions`. A command that wasn't discovered,
  or isn't in the allow-list, or whose preconditions fail, is recorded as blocked and never sent.
- **Prioritisation:** `SimulatedShiftPolicy` estimates value per minute from kind, priority and
  deadline, skips infeasible tasks, finishes carried items first, and never enters a
  do-not-disturb room (it defers those instead). It uses only what the observation shows.
- **Timeouts, retries, backoff:** every request has a timeout. A transient or rate-limited
  failure is retried at most `retry.maxAttempts` times in total, with exponential backoff.
- **Ambiguous failures:** after a timeout or lost response, a *consequential* action is never
  simply resent. The runner asks `status(of:)` if the service supports it, otherwise compares
  observations. If it was applied → recorded as confirmed. If it definitely wasn't → retry
  (same idempotency key, still bounded). If unknown → the task is set aside and the action is
  **not** repeated.
- **Stop control:** `StopSignal` is checked before every request, including retries. CLI:
  Ctrl-C (second press exits), `--stop-file PATH`, `--stop-after N`. App: Stop button / ⌘.
  An in-flight request cannot be recalled; if it is interrupted, its outcome is recorded as
  unknown and not repeated.
- **Separation of simulation and live:** every report, record and log entry carries an
  `ExecutionMode`. The runner refuses to start when the adapter's mode differs from the
  configured one. Scores are `LabeledScore`s whose only text form says "SIMULATED — … not a
  challenge result". The live placeholder returns no score.

## The simulator (clearly not Wybe)

`SimulatedNightShift` is deterministic per seed. Its hotel layout, `sim.`-prefixed commands
(`sim.move`, `sim.pickup`, `sim.deliver`, `sim.inspect`, `sim.defer`), task values, penalties
(unknown command, failed precondition, repeating a finished task, entering a do-not-disturb
room) and fault injection (refused, rate-limited, hung, applied-but-response-lost) were all
invented to exercise the runner. Its scores do not predict challenge performance.

## Adding the live adapter later

1. Implement `ChallengeAdapter` against the official contract (`mode = .live`). Map the
   service's errors onto `ChallengeError` carefully: only report `.transient` when the
   service guarantees the action was not applied.
2. Write a `ShiftPolicy` for the real command vocabulary.
3. Configure `RunnerConfiguration(expectedMode: .live, allowedActions: [...exact names...])`
   with a conservative `minRequestInterval` that matches the published rate limits.
4. Add a CLI command that requires an explicit flag to start a live run. Practice and
   final runs must not start unless you say so.
