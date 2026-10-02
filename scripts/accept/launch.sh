#!/bin/bash
# Chapter 的平台启动验收；配置中的 -lane_demo YES 使用隔离的虚构会话并拦截网络。
set -euo pipefail
lane="${1:?usage: launch.sh <iphone|ipad|mac|vision>}"
case "$lane" in iphone|ipad|mac|vision) ;; *) exit 2;; esac
cd "$(dirname "$0")/../.."
[ -n "${SOP_PLATFORM_LAUNCH:-}" ] || { echo '由 Chapter 的 launch_<平台> 验收调用'; exit 78; }
py="$HOME/Dev/.venv/bin/python"
[ -x "$py" ] || py=python3
exec "$py" "$SOP_PLATFORM_LAUNCH"
