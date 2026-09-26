#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d /tmp/hydro-consent-sop.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
xcrun --sdk macosx swiftc -target "$(uname -m)-apple-macos15.0" \
  Shared/PlatformCompat.swift Sources/AIConsent.swift Sources/ChatStream.swift \
  Sources/Backend.swift Sources/Gate.swift Tests/ConsentChecks.swift -o "$scratch/check"
"$scratch/check"
