#!/usr/bin/env bash
# 薄 shim —— 真实现是总部 SSOT，别在这儿改逻辑（改了别的 app 不会跟着变）。
exec /Users/tianli/Dev/tools/dev/lib/tools/macapp/ios/seed-gate.sh \
  "$(cd "$(dirname "$0")" && pwd)" "$@"
