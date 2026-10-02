#!/usr/bin/env python3
"""Water Assistant 平台测量薄入口；调度、当前证据复用与 iOS 证据投影由总部实现。

默认补齐全部适用平台；只测一条可传 --platform iphone|ipad|mac|vision。
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = Path.home() / "Apps/.claude/skills/app-lightweight/scripts/platform_measure.py"
args = sys.argv[1:]
platform = [] if "--platform" in args or any(a.startswith("--platform=") for a in args) else ["--platform", "all"]
os.execv(sys.executable, [sys.executable, str(TOOL), "--app", "hydro-deck", "--repo", str(ROOT),
                         "--sync-ios", *platform, *args])
