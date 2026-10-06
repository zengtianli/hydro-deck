#!/bin/bash
# 后台覆盖项（改说明文字、状态名、阈值不用发版）的三条验收，全部走生产解码路径：
#   ③ 接入之前的客户端解新后端的出网字节，照常能用（先跑）；
#   ① 后台写一个键，客户端不改就变；② 后台写坏，整段回落、其余数据照常解出。
# 帧样本 Tests/fixtures/remote-ui/*.sse 是后端生产出网路径导出的真实字节，重新生成：
#   cd ~/Apps/hydro-assistant/service && uv run python scripts/dump_ui_frames.py <本仓>/Tests/fixtures/remote-ui
# 也可以用 HYDRO_UI_FRAMES_DIR 指到另一份刚导出的。
set -euo pipefail
cd "$(dirname "$0")/.."
# 接入后台覆盖项之前的最后一个提交：旧客户端的源码从这里取。
BASE=010380436a0ff1b4824710bec4a70df6ddcd17fa
frames="$(cd "${HYDRO_UI_FRAMES_DIR:-Tests/fixtures/remote-ui}" && pwd)"
scratch="$(mktemp -d /tmp/hydro-remote-ui.XXXXXX)"
old="hydro-deck-remote-ui-old"; new="hydro-deck-remote-ui-new"
# UserDefaults 按进程名落在 ~/Library/Preferences；用专属名并在退出时删除，不留残留。
trap 'for b in "$old" "$new"; do defaults delete "$b" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$b.plist"; done; rm -rf "$scratch"' EXIT
swiftc=(xcrun --sdk macosx swiftc -target "$(uname -m)-apple-macos15.0" -parse-as-library)

mkdir "$scratch/base"
for f in Shared/PlatformCompat.swift Sources/AIConsent.swift Sources/ChatStream.swift Sources/Backend.swift Sources/Gate.swift; do
  git show "$BASE:$f" > "$scratch/base/$(basename "$f")"
done
"${swiftc[@]}" "$scratch"/base/*.swift Tests/FrameTransport.swift Tests/RemoteUIOldClient.swift -o "$scratch/$old"
"$scratch/$old" "$frames"

"${swiftc[@]}" Shared/PlatformCompat.swift Shared/RemoteUI.swift Sources/AIConsent.swift Sources/ChatStream.swift \
  Sources/Backend.swift Sources/Gate.swift Sources/Store.swift Sources/ChatModel.swift Sources/Speaker.swift \
  Sources/MarkdownView.swift Sources/LaneDemo.swift Tests/FrameTransport.swift Tests/RemoteUIChecks.swift -o "$scratch/$new"
"$scratch/$new" "$frames"
