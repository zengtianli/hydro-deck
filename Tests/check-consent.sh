#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d /tmp/hydro-consent-sop.XXXXXX)"
# UserDefaults 按进程名落在 ~/Library/Preferences；用专属名并在退出时删除，不留残留。
bin="hydro-deck-consent-check"
trap 'rm -f "$HOME/Library/Preferences/$bin.plist"; rm -rf "$scratch"' EXIT
xcrun --sdk macosx swiftc -target "$(uname -m)-apple-macos15.0" \
  Shared/PlatformCompat.swift Sources/AIConsent.swift Sources/ChatStream.swift \
  Sources/Backend.swift Sources/Gate.swift Tests/ConsentChecks.swift -o "$scratch/$bin"
"$scratch/$bin"
