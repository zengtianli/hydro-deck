#!/bin/bash
# Chapter 的平台启动验收；配置中的 -lane_demo YES 使用隔离的虚构会话并拦截网络。
set -euo pipefail
lane="${1:?usage: launch.sh <iphone|ipad|mac|vision>}"
shift
case "$lane" in iphone|ipad|mac|vision) ;; *) exit 2;; esac
cd "$(dirname "$0")/../.."
[ -n "${SOP_PLATFORM_LAUNCH:-}" ] || { echo '由 Chapter 的 launch_<平台> 验收调用'; exit 78; }
py="$HOME/Dev/.venv/bin/python"
[ -x "$py" ] || py=python3
args=("$@")
if [ -n "${HYDRO_LANE_REUSE_BUILD:-}" ]; then
  args+=(--reuse-build "$HYDRO_LANE_REUSE_BUILD")
fi
if [ "${HYDRO_LANE_NO_WAIT:-0}" = 1 ]; then
  args+=(--lock-wait 0 --load-wait 0)
fi
exec "$py" "$SOP_PLATFORM_LAUNCH" "${args[@]}"
