# ElevenLabs — speech input and output

ElevenLabs is used **only** to turn speech into text and text into speech. It is not Relay's
reasoning engine; interpretation is done by `RuleBasedReasoner` and the procedure answerer.

## Contract source

Re-verified against **elevenlabs.io/docs on 2026-11-07**. These pages were read: API authentication, API Keys (workspace administration), Errors, the help-center pages for errors 400/401/422/429, "How do I authorize myself using an API key?", "How do I find the voice ID…", Default voices, Models, and the speech-to-text, text-to-speech, user/get and service-account create-key API references. The first version of this file used ElevenLabs' official Python SDK instead, because the docs host was blocked at the time.

| Use | Request | Notes |
|---|---|---|
| Auth | header `xi-api-key: <key>` | never in a URL |
| Base URL | `https://api.elevenlabs.io` | regional variants exist |
| Transcribe | `POST /v1/speech-to-text`, multipart: `model_id` (required), `file`, optional `language_code` | response: `text`, `language_code`, … |
| Speak | `POST /v1/text-to-speech/{voice_id}?output_format=mp3_44100_128`, JSON `text`, `model_id`, `language_code` | `language_code` is "not supported for multilingual_v2 models", so Relay omits it for them |
| Account check | `GET /v1/user` | used only by Settings › *Check account* |

## Guided setup (Settings)

1. **API key.** Dashboard › Developers › API Keys (`https://elevenlabs.io/app/api/api-keys`). Keys are restricted by default, and the full key is shown only when it is created. Minimum permissions, using ElevenLabs' identifiers:
   - `speech_to_text`: push-to-talk and *Test speech input*.
   - `text_to_speech`: spoken replies and *Test voice*.
   - `user_read`: optional, only for *Check account*.

   The key is stored in the Keychain and can be saved, replaced or removed.
2. **Voice.** My Voices (`/app/voice-lab`) › More actions (three dots) › Copy voice ID. The Voice Library (`/app/voice-library`) is for finding new voices. *Use example voice* fills in `JBFqnCBsd6RMkjVDRZzb`, the voice used in ElevenLabs' own examples. It is not guaranteed to be available: ElevenLabs' Default voices are only available to accounts created before March 2026, and they expire on 31 December 2026. The voice-ID field refuses anything that looks like an API key, so a key is never stored as a voice or put into a URL.
3. **Microphone and speech input.** Shows the macOS permission state and can request access or open System Settings. *Test speech input* records 3 seconds and transcribes them.
4. **Models.** Plain-language pickers, with custom IDs under Advanced:
   - Speech recognition: `scribe_v2`.
   - Speech generation: **`eleven_flash_v2_5`**, now the default instead of `eleven_multilingual_v2`. Per the models page, Multilingual v2's 29 languages do not include Norwegian, while Flash v2.5 supports all of them plus Norwegian.
   - Output: `mp3_44100_128`, the API default. Only MP3 is offered because Relay plays replies through the system MP3 decoder.

Network and paid requests run **only** from explicit buttons (*Check account*, *Test voice*, *Test speech input*) or real use (push-to-talk, spoken replies).

## Readiness: five separate facts

| Line | Becomes "passed" only when |
|---|---|
| Key saved | A key is stored in the Keychain. This verifies nothing. |
| Account / credential check | `GET /v1/user` returned 2xx. This proves nothing about speech. |
| Speech input tested | A transcription request succeeded (the test, or real push-to-talk). |
| Speech output tested | A speech-generation request returned audio (*Test voice*, or a real reply). |
| Microphone permission | macOS reports it as authorised. |

Saving or replacing a key resets all request-based checks. Changing the voice resets the output test, and changing a model or format resets the matching test.

## Error handling

Responses are classified by documented `detail.code` (or the legacy `detail.status`), then by `detail.type`, then by HTTP status:

- **Invalid credentials:** 401, `invalid_api_key`.
- **Reported missing permission:** only when the response carries the explicit `insufficient_permissions` code (or the legacy `missing_permissions`). A specific permission is named only if ElevenLabs' own message names one. Otherwise Relay states which permission its request uses, as a requirement rather than a diagnosis. On the optional account check this is shown as *needs attention*.
- **Inconclusive access errors:** a bare 403 (no code, or `forbidden` / `authorization_error`) is shown as "refused access; the cause is not stated". Relay does not claim the key is valid or that a particular permission is missing.
- **Unavailable voice:** `voice_not_found` / `voice_access_denied`.
- **Unavailable model:** `model_not_found` / `unsupported_model` / `model_access_denied`.
- **Exhausted credits:** 402, `insufficient_credits`, legacy `quota_exceeded`.
- **Rate limiting:** 429.
- **Network failures:** shown as "could not reach", with no claim about whether the request arrived.
- **Ambiguous responses:** a 404 without a code is not given a guessed cause either. ElevenLabs' message and request ID are shown, redacted.

## What was exercised

- **Real ElevenLabs requests: none.** No API key was available. Docs pages were read with plain GETs.
- Request building, error classification, readiness transitions, link validity and secret handling are covered by tests against a fake transport (`Tests/RelayAdaptersTests/`).

## Credentials

- Entered in Settings and stored in the **macOS Keychain** (generic password, service
  `com.oslosprint.relay`, account `elevenlabs.api-key`, this device only).
- Relay reads only that item. It never searches other apps' credentials or environment
  variables.
- Every loaded key is registered with the `Redactor`, so it is removed from log entries,
  error messages and exports. Pattern rules also catch `xi-api-key:`, `Bearer …`,
  `api_key=…` and `sk_…`-style strings.
- `scripts/check-no-secrets.sh` checks tracked files before committing.

## Privacy and cost

Audio is captured only while the push-to-talk button is held. It is saved to a temporary
`.m4a` file, sent to `POST /v1/speech-to-text` and deleted afterwards. Reply text is sent to
text-to-speech only when speech output is configured. Spoken text is capped at 1,200
characters per request.
