#!/usr/bin/env python3
"""单条平台的虚构会话商店原片；编译/启动/旋转/静默/规格均复用总部实现。

由主会话调度后运行：store_shots.py iphone|ipad|mac|vision [--app 已编好的.app]
不排队等模拟器，忙或负载过高退出 75。--app 必须来自本轮源码编译；原片不缩放。
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HQ = Path.home() / "Dev/tools/dev/lib/tools/macapp/ios"
sys.path.insert(0, str(HQ))
import sim_lane
import store_shots
import yaml

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("platform", choices=("iphone", "ipad", "mac", "vision"))
parser.add_argument("--app", type=Path)
options = parser.parse_args()
config = yaml.safe_load((ROOT / "project.yaml").read_text())["sop"]["platforms"][options.platform]
output = ROOT / "shots/appstore" / options.platform
output.mkdir(parents=True, exist_ok=True)
if options.app:
    app = options.app.resolve()
else:
    app = Path(sim_lane.build(ROOT, "HydroDeck", options.platform, "Release")["app_path"])
args = ["run", "--platform", options.platform, "--app", str(app), "--screenshot", str(output / "01-chat.png"),
        "--lock-wait", "0", "--load-wait", "0", "--json"]
for arg in config.get("launch_args", []):
    args.append(f"--arg={arg}")
if config.get("orientation"):
    args += ["--orientation", config["orientation"]]
if config.get("simulator", {}).get("device_type"):
    args += ["--device-type", config["simulator"]["device_type"]]
result = subprocess.run([sys.executable, str(HQ / "sim_lane.py"), *args], capture_output=True, text=True)
(output / "capture.json").write_text(result.stdout)
print(result.stdout or result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
problems = store_shots.validate(options.platform, [output / "01-chat.png"])
print(json.dumps({"platform": options.platform, "problems": problems}, ensure_ascii=False))
raise SystemExit(1 if problems else 0)
