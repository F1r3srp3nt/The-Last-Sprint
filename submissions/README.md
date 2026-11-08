![HCG × Oslo Sprint 2026 Submissions banner: Distil, Relay and Presentation Studio above the Oslo waterfront at night, with the platform categories macOS, Windows, Linux, Android and iOS](assets/submissions-banner.png)

# Submissions

Packaged builds of the three Oslo Sprint 2026 products, uploaded for the competition. Source code stays in each product's own folder; these folders hold packages only.

| Product | Submissions | Source |
|---|---|---|
| **Distil** | [`Distil/`](Distil/README.md) | [`distil/`](../distil/README.md) |
| **Relay** | [`Relay/`](Relay/README.md) | [`relay/`](../relay/README.md) |
| **Presentation Studio** | [`Presentation Studio/`](Presentation%20Studio/README.md) | [`presentation-studio/`](../presentation-studio/README.md) |

Each product has one folder per operating system: `MacOS/`, `Windows/`, `Linux/`, `Android/` and `iOS/`. **A folder existing does not mean a build exists or that the platform is supported.** Likewise, the platform names in the banner are categories, not proof that builds exist. Every folder starts as "No build uploaded yet."

## Adding a build

1. Put the package in the matching folder. Upload only a real build that came from the product's source. Don't rename a file to suggest it runs on another platform.
2. macOS: upload a `.app` bundle as a ZIP archive (`ditto -c -k --keepParent Name.app Name-<version>-<arch>.zip`), so its bundle structure, executable permissions and signature survive.
3. In that folder's README, replace "No build uploaded yet." with the file name, version, architecture, build date, source commit (if known) and verification status. Write "not verified" if it wasn't tested.
4. Keep files under 100 MB: GitHub rejects larger files in a normal push and warns above 50 MB.

## Never commit

Credentials or `.env` files, signing certificates and provisioning profiles, keystores, caches, `node_modules/`, or intermediate build output (`.build/`, `DerivedData/`, object files). [`.gitignore`](.gitignore) blocks the common ones in this folder.
