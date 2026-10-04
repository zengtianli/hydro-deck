#!/usr/bin/env python3
"""单条平台的虚构会话商店原片；编译/启动/旋转/静默/规格均复用总部实现。

由主会话调度后运行：store_shots.py iphone|ipad|mac|vision [--reuse-build 真实构建回执]
不排队等模拟器，忙或负载过高退出 75。--app 必须来自本轮源码编译；原片不缩放。
Mac 可显式选择透明像素合成底并保存原始含 alpha PNG；不改变 App 内容或默认黑底。
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
build_source = parser.add_mutually_exclusive_group()
build_source.add_argument("--app", type=Path)
build_source.add_argument("--reuse-build", type=Path)
parser.add_argument("--snapshot-background", choices=("black", "white"))
parser.add_argument("--raw-snapshot-out", type=Path)
options = parser.parse_args()
if options.platform != "mac" and (options.snapshot_background is not None or options.raw_snapshot_out is not None):
    parser.error("--snapshot-background/--raw-snapshot-out 仅用于 Mac")
config = yaml.safe_load((ROOT / "project.yaml").read_text())["sop"]["platforms"][options.platform]
output = ROOT / "shots/appstore" / options.platform
sim_lane.validate_mac_snapshot_outputs(output / "01-chat.png", options.snapshot_background or "black",
                                      options.raw_snapshot_out)
reused = None
if options.reuse_build:
    reused = sim_lane.reuse_build(options.reuse_build.resolve(), "hydro-deck", ROOT,
                                 options.platform, "HydroDeck", "Release", False)
output.mkdir(parents=True, exist_ok=True)
if reused:
    app = Path(reused["app_path"])
elif options.app:
    app = options.app.resolve()
else:
    app = Path(sim_lane.build(ROOT, "HydroDeck", options.platform, "Release")["app_path"])
args = ["run", "--platform", options.platform, "--app", str(app), "--screenshot", str(output / "01-chat.png"),
        "--lock-wait", "0", "--load-wait", "0", "--json"]
if options.snapshot_background is not None:
    args += ["--snapshot-background", options.snapshot_background]
if options.raw_snapshot_out is not None:
    args += ["--raw-snapshot-out", str(options.raw_snapshot_out)]
for arg in config.get("launch_args", []):
    args.append(f"--arg={arg}")
if config.get("orientation"):
    args += ["--orientation", config["orientation"]]
if config.get("simulator", {}).get("device_type"):
    args += ["--device-type", config["simulator"]["device_type"]]
result = subprocess.run([sys.executable, str(HQ / "sim_lane.py"), *args], capture_output=True, text=True)
capture = result.stdout
if reused and result.returncode == 0:
    verified = sim_lane.reuse_build(options.reuse_build.resolve(), "hydro-deck", ROOT,
                                   options.platform, "HydroDeck", "Release", False)
    actual = json.loads(result.stdout)
    actual.update(input_sha256=verified["reuse"]["input_sha256"],
                  executable_sha256=verified["executable_sha256"], build_reuse=verified["reuse"])
    capture = json.dumps(actual, ensure_ascii=False, indent=2) + "\n"
(output / "capture.json").write_text(capture)
print(result.stdout or result.stderr)
if result.returncode:
    raise SystemExit(result.returncode)
problems = store_shots.validate(options.platform, [output / "01-chat.png"])
print(json.dumps({"platform": options.platform, "problems": problems}, ensure_ascii=False))
raise SystemExit(1 if problems else 0)
