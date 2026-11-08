# Relay architecture

```
relay/
├── Package.swift                 SwiftPM; no third-party dependencies
├── Sources/
│   ├── RelayCore/                Foundation only — builds and tests on macOS and Linux
│   │   ├── Foundation/           ExecutionMode/LabeledScore, Redactor, EventLog,
│   │   │                         clock, timeout, RetryPolicy, RateLimiter, StopSignal, seeded RNG
│   │   ├── Tasks/                TaskQueue with validated state transitions
│   │   ├── Assistant/            interfaces (speech, reasoning, planning, tools),
│   │   │                         RuleBasedReasoner, DefaultTaskPlanner, ToolRegistry,
│   │   │                         AssistantRuntime, VoiceSession state machine
│   │   ├── Warehouse/            Procedure model, DemoProcedure, renderer, answerer, session
│   │   └── Wybe/                 ChallengeAdapter, SimulatedNightShift, LiveNightShiftAdapter
│   │                             (placeholder), ShiftPolicy, AutonomousRunner
│   ├── RelayAdapters/            ElevenLabs REST (STT, TTS, key check), HTTPTransport,
│   │                             CredentialStore (Keychain on macOS, in-memory for tests)
│   ├── RelayRunner/              `relay-runner` CLI — headless, no UI, no speech
│   └── RelayApp/                 macOS 14 SwiftUI app (only added to the package on macOS)
├── Tests/                        XCTest: RelayCoreTests, RelayAdaptersTests
├── docs/                         this file, WYBE.md, ELEVENLABS.md, WAREHOUSE.md, demo-procedure.json
└── scripts/                      check-prereqs.sh, test.sh, build-app.sh, run-latest.sh, verify-macos.sh, demo-warehouse.sh, check-no-secrets.sh
```

## Pipeline (Assistant)

```
audio ──SpeechTranscriber──▶ transcript ──(user reviews/edits)──▶ HeardInput
typed text / button ──────────────────────────────────────────────▶ HeardInput
HeardInput ──Reasoner──▶ Understanding(intent, confidence, explanation, engine)
           ──TaskPlanner──▶ Plan(steps: tool + arguments + rationale)
           ──ToolExecuting──▶ ToolAttempt(s)   (approval enforced here)
           ──▶ Interaction(heard, understood, plan, attempts, reply, status) ──SpeechSynthesizer──▶ audio
```

Each stage writes to the event log (`heard`, `understood`, `planned`, `attempted`, then
`succeeded`/`failed`/`needsAttention`). The Assistant view shows exactly these five rows.

Interfaces (all in `RelayCore/Assistant/Interfaces.swift` unless noted):

| Concern | Interface | Implementation(s) |
|---|---|---|
| Speech transcription | `SpeechTranscriber` | `ElevenLabsTranscriber` |
| Speech synthesis | `SpeechSynthesizer` | `ElevenLabsSynthesizer` |
| Reasoning | `Reasoner` | `RuleBasedReasoner` (deterministic) |
| Task planning | `TaskPlanner` | `DefaultTaskPlanner` |
| Tool execution | `Tool`, `ToolExecuting` | `ToolRegistry` + `ClosureTool` |
| Challenge adapters | `ChallengeAdapter`, `ShiftPolicy` (Wybe/) | `SimulatedNightShift`, `LiveNightShiftAdapter`, `SimulatedShiftPolicy` |
| Event logging | `EventLogging` (Foundation/EventLog.swift) | `InMemoryEventLog` |

## Safety boundaries

- **Fixed tool set:** warehouse navigation and Q&A, add task, run the Wybe *simulation*
  (needs approval), stop the runner, help. There is no shell, file-system or system-settings
  tool, and unknown tool names are refused.
- **User-approved vs autonomous:** in the assistant, tools marked `requiresApproval` wait for
  Approve/Decline. The Wybe runner is separate: it acts autonomously, but only within
  `RunnerConfiguration.allowedActions` ∩ discovered commands. It never uses the assistant's tools.
- **Truthful logging:** entries are immutable and redacted on write. Blocked actions are
  recorded as blocked, not as failures of the environment. Ambiguous outcomes are recorded
  as unknown.
- **No faked connections:** speech status becomes "Connected" only after a real request
  succeeds. The live Wybe adapter throws `contractUnavailable` and has no score.
