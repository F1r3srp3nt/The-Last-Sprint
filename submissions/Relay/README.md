# Relay: packaged submissions

Packaged builds of Relay, one folder per operating system. These folders hold uploaded packages only, never source code.

**A folder existing does not mean a build exists or that the platform is supported.** Each folder's README says whether a build has been uploaded and what was verified.

| Operating system | Folder |
|---|---|
| macOS | [`MacOS/`](MacOS/README.md) |
| Windows | [`Windows/`](Windows/README.md) |
| Linux | [`Linux/`](Linux/README.md) |
| Android | [`Android/`](Android/README.md) |
| iOS | [`iOS/`](iOS/README.md) |

## Source

The source in [`relay/`](../../relay/README.md) builds a macOS 14+ SwiftUI app (`Relay.app`) and a command-line runner, `relay-runner`, that also builds on Linux. There is no Windows, Android or iOS app.

Back to [all submissions](../README.md).
