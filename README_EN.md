[中文](README.md) | **English**

<p align="center"><img src="Resources/icon-1024.png" width="96" alt="Water Assistant"></p>

# Water Assistant · hydro-deck



**Ask a water-engineering question and receive a cited answer in a little over ten seconds.**

![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white) ![SwiftUI](https://img.shields.io/badge/SwiftUI-0D84FF?logo=swift&logoColor=white) ![Platform](https://img.shields.io/badge/iOS%2018.0%2B%20·%20macOS%2015.0%2B-000?logo=apple) ![TestFlight](https://img.shields.io/badge/TestFlight-内测中-0D84FF) ![License](https://img.shields.io/badge/License-MIT-green)

The mobile client for a self-hosted domain agent: streaming text, live step and tool progress, cited answers, and honest display of seven final states, including qualified answers and refusals. No business logic runs locally; backend capabilities can grow without changing the app.

<table><tr>
<td align="center" width="25%"><img src="docs/screenshots/01-live-early.png" alt="Ask how 2026 water-source requirements differ from earlier ones: conclusion first, evidence table next"><br><sub>Ask how 2026 water-source requirements differ from earlier ones: conclusion first, evidence table next</sub></td>
<td align="center" width="25%"><img src="docs/screenshots/02-live-end.png" alt="Answers include limitations and warnings, proactively stating when indicators from two editions cannot be converted item by item"><br><sub>Answers include limitations and warnings, proactively stating when indicators from two editions cannot be converted item by item</sub></td>
<td align="center" width="25%"><img src="docs/screenshots/03-live-final2.png" alt="A real online conversation: old/new standards comparison, limitations, and 5 citations in 16.8 seconds"><br><sub>A real online conversation: old/new standards comparison, limitations, and 5 citations in 16.8 seconds</sub></td>
</tr></table>

## What it does

| Feature | Description |
|---|---|
| **SSE streaming with visible steps** | Answers stream like a typewriter while retrieval and comparison progress appears live. During the ten-plus-second wait, you can see what it is doing instead of guessing at a spinner. |
| **Answers include citations and limitations** | Conclusions are followed by evidence tables and citation lists. Incompatible measurement conventions or inability to convert indicators item by item are stated in the answer. Seven final states are displayed honestly, including qualified answers and refusals. |
| **No local business logic** | All intelligence lives in the backend agent; the app is a thin shell. Adding a backend capability or revising a prompt requires no mobile-code changes, which is the purpose of the shell. |

## Availability

In private TestFlight testing (first released 2026-09-02); the backend is private and no trial is available.

A thin shell with all intelligence in the private backend `hydro-agent.tianli.cyou`, behind access control. The code can be read and built, but conversations require a backend account.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme HydroDeck -destination 'generic/platform=iOS Simulator' build
```

- The repository's `*.sh` files are shims for the author's local fleet scripts (three-platform builds / device installation / TestFlight). They depend on HQ tools under `~/Dev` that are not in this repository; without them, the scripts exit explicitly.
- `Shared/PlatformCompat.swift` is a byte-for-byte copy of a shared HQ file (iOS-only SwiftUI modifiers become same-named no-ops on macOS). Do not edit it here.

See [DEVELOPING.md](DEVELOPING.md) for development details, including regression checks, validation channels, and constraints.

## Related

- Product page: <https://apps.tianli.cyou/p/hydro-deck-ios.html>
- Fleet overview (how the 10 apps came about): <https://apps.tianli.cyou/ios.html>
- Tutorial: [From zero to TestFlight: the complete path to building iPhone apps solo](https://blog-ai.tianli.cyou/nine-ios-apps-in-two-weeks)

## License

MIT © 2026 Tianli Zeng
