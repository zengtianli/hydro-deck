#!/bin/bash
# hydro-deck 固定验收共用运行器：把生产源码（非 UI 层 + Markdown 解析）与 scripts/accept/<check>.swift
# 一起在 macOS 用 swiftc 编译成独立进程运行。不启动模拟器、不碰手机、不合成输入、不连真实后端：
# 验收用例把 ChatStream.session 换成本地 URLProtocol，SessionStore 指向临时目录。
#   bash scripts/accept/_common.sh <functionality|recovery|privacy>
# 退出码 0 通过、1 失败；结果摘要写 $SOP_OUT_DIR/<check>.detail.json（缺省 perf/acceptance/）。
set -uo pipefail
check="${1:-${SOP_CHECK:-}}"
case "$check" in functionality|recovery|privacy) ;; *) echo "用法: _common.sh functionality|recovery|privacy" >&2; exit 2;; esac
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out_dir="${SOP_OUT_DIR:-$root/perf/acceptance}"
mkdir -p "$out_dir"
scratch="$(mktemp -d /tmp/hydro-accept-$check.XXXXXX)"
# UserDefaults 走 cfprefsd，不认 HOME：用专属进程名作偏好域，结束时删掉，不在 ~/Library/Preferences 留残留。
bin="hydro-deck-accept-$check"
trap 'defaults delete "$bin" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$bin.plist"; rm -rf "$scratch"' EXIT

PROD=(Shared/PlatformCompat.swift Shared/RemoteUI.swift Sources/AIConsent.swift Sources/ChatStream.swift Sources/Backend.swift
      Sources/Gate.swift Sources/Store.swift Sources/ChatModel.swift Sources/Speaker.swift Sources/MarkdownView.swift
      Sources/LaneDemo.swift)
finish() {  # ok summary log
  python3 - "$out_dir/$check.detail.json" "$check" "$1" "$2" <<'PY'
import json, sys
path, check, ok, summary = sys.argv[1:5]
json.dump({"check": check, "ok": ok == "1", "summary": summary,
           "scope": "生产 ChatModel/ChatStream/Backend/Store/AIConsent 在 macOS 编译运行，本地 URLProtocol 代替后端；SwiftUI 渲染与真机不在本项范围"},
          open(path, "w"), ensure_ascii=False, indent=2)
PY
  tail -c 6000 "$3" 2>/dev/null
  if [ "$1" = 1 ]; then echo "✅ $2"; exit 0; else echo "❌ $2"; exit 1; fi
}

log="$scratch/log"
if ! xcrun --sdk macosx swiftc -target "$(uname -m)-apple-macos15.0" -parse-as-library \
     "${PROD[@]}" scripts/accept/AcceptKit.swift "scripts/accept/$check.swift" -o "$scratch/$bin" >"$log" 2>&1; then
  finish 0 "$check: 验收包编译失败（生产源码或验收用例）" "$log"
fi
# 独立 HOME 让 Application Support 等文件落进临时目录，不碰本机已装 Mac 版数据。
mkdir -p "$scratch/home"
if HOME="$scratch/home" CFFIXED_USER_HOME="$scratch/home" HYDRO_ACCEPT_TMP="$scratch" \
   perl -e 'alarm 300; exec @ARGV' "$scratch/$bin" >"$log" 2>&1; then
  finish 1 "$check: $(grep -c '^PASS ' "$log") 项断言通过；$(grep '^SUMMARY ' "$log" | tail -1 | cut -c9-)" "$log"
else
  finish 0 "$check: 失败 —— $(grep -E '^FAIL |Fatal error' "$log" | head -1)" "$log"
fi
