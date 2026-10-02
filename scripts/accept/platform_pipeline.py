#!/usr/bin/env python3
"""主调度授予时段后的四线收口；复用总部构建回执、测量、截图与 Chapter 验收。

--prepare-only 只核缓存和显示命令，不请求锁、不启动 App。
运行须 HYDRO_PLATFORM_SLOT=granted；任一步忙即退出 75，不轮询。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HQ = Path.home() / "Dev/tools/dev/lib/tools/macapp/ios"
ENGINE = Path.home() / "Apps/chapter/engine/app_sop.py"
PERF_TOOLS = Path.home() / "Apps/.claude/skills/app-lightweight/scripts"
sys.path[:0] = [str(HQ), str(ENGINE.parent), str(PERF_TOOLS)]
import app_sop
import platform_measure
import sim_lane
import store_shots

APP_ID = "hydro-deck"
SOURCE = "289ff0bba2e27ed21758131a7dca175fb4d410eebaa438ed45f496261cc8ced6"
LANES = ("iphone", "ipad", "mac", "vision")
CACHE = Path.home() / "Library/Caches/sim-lane"
MEASURE = ROOT / "scripts/perf/measure_platforms.py"


def receipt(lane):
    physical = "iphone" if lane == "ipad" else lane
    return CACHE / f"hydro-{physical}-20261003/reuse-{lane}.json"


def current(lane):
    app = app_sop.load_apps(APP_ID)[0]
    if app_sop.lane_inputs(app, lane)["input_sha256"] != SOURCE:
        raise RuntimeError("平台源码已变化，拒绝使用本轮缓存或写通过证据")
    cfg = app_sop.platform_lanes(app)["lanes"][lane]
    expected = ["-lane_demo", "YES"] + (["-lane_window", "1440x900"] if lane == "mac" else [])
    if cfg["launch_args"] != expected:
        raise RuntimeError("平台演示启动参数已变化，拒绝运行")
    built = sim_lane.reuse_build(receipt(lane), APP_ID, ROOT, lane,
                                scheme="HydroDeck", configuration="Release", fixture_debug=False)
    return app, cfg, built


def call(command, env=None, capture=False, acceptance=False):
    print("→ " + " ".join(map(str, command)), flush=True)
    result = subprocess.run(list(map(str, command)), cwd=ROOT, stdin=subprocess.DEVNULL,
                            env=env, capture_output=capture, text=capture)
    if acceptance:
        print(result.stdout or result.stderr, flush=True)
        outcome = json.loads(result.stdout)
        checks = outcome.get("results") or {}
        if checks and all(check.get("status") == "deferred" for check in checks.values()):
            raise SystemExit(75)
    if result.returncode:
        if capture:
            print(result.stdout or result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
    return result


def measured(lane):
    cfg = platform_measure.lane_config(ROOT, lane)
    return platform_measure.current_evidence(ROOT, lane, cfg, SOURCE, fixture_debug=False) is not None


def capture_lane(lane, cfg, built):
    output = ROOT / f"shots/appstore/{lane}"
    target = output / "01-chat.png"
    try:
        old = json.loads((output / "capture.json").read_text())
        if (old.get("ok") is True and old.get("ready_signal") and old.get("input_sha256") == SOURCE
                and old.get("executable_sha256") == built["executable_sha256"]
                and old.get("screenshot_sha256") == sim_lane.sha256(target)):
            if not store_shots.validate(lane, [target]):
                print(f"＝ {lane} 当前商店原片，跳过", flush=True)
                return
    except (OSError, ValueError):
        pass
    with tempfile.TemporaryDirectory(prefix=f"hydro-shot-{lane}.") as scratch:
        image = Path(scratch) / "01-chat.png"
        command = [sys.executable, HQ / "sim_lane.py", "run", "--platform", lane, "--app", built["app_path"],
                   "--screenshot", image, "--lock-wait", "0", "--load-wait", "0", "--json"]
        for arg in cfg["launch_args"]:
            command.append(f"--arg={arg}")
        if cfg.get("orientation"):
            command += ["--orientation", cfg["orientation"]]
        sim = cfg.get("simulator") or {}
        # 商店 iPhone 6.9 寸原片用 Pro Max；性能仍沿登记的 Pro，不重测。
        device_type = "iPhone-17-Pro-Max" if lane == "iphone" else sim.get("device_type")
        if device_type:
            command += ["--device-type", device_type]
        result = call(command, capture=True)
        proof = json.loads(result.stdout)
        if proof.get("ok") is not True or not proof.get("ready_signal"):
            raise RuntimeError("共享启动未通过")
        if lane == "mac" and (not proof.get("quiet") or proof.get("window_on_screen") or proof.get("focus_taken")):
            raise RuntimeError("Mac 静默守卫未通过")
        problems = store_shots.validate(lane, [image])
        if problems:
            raise RuntimeError("；".join(problems))
        current(lane)  # 输入变化时不发布候选原片。
        proof.update(input_sha256=SOURCE, executable_sha256=built["executable_sha256"],
                     screenshot_sha256=sim_lane.sha256(image), screenshot=str(target.relative_to(ROOT)))
        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(image, target)
        (output / "capture.json").write_text(json.dumps(proof, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--only", choices=LANES)
    options = parser.parse_args()
    lanes = (options.only,) if options.only else LANES
    if not options.prepare_only and os.environ.get("HYDRO_PLATFORM_SLOT") != "granted":
        print("等待主调度授予时段；未请求锁、未运行", file=sys.stderr)
        return 78
    for lane in lanes:
        app, cfg, built = current(lane)
        measure = [sys.executable, MEASURE, "--platform", lane, "--reuse-size-build", receipt(lane),
                   "--lock-wait", "0", "--load-wait", "0"]
        accept = [sys.executable, ENGINE, "accept", "--app", APP_ID, "--check", f"launch_{lane}", "--json"]
        if options.prepare_only:
            print(json.dumps({"lane": lane, "source": SOURCE, "receipt": str(receipt(lane)),
                              "measure": list(map(str, measure)), "accept": list(map(str, accept)),
                              "launch_env": {"HYDRO_LANE_REUSE_BUILD": str(receipt(lane)), "HYDRO_LANE_NO_WAIT": "1"}},
                             ensure_ascii=False))
            continue
        if not measured(lane):
            call(measure)
        else:
            print(f"＝ {lane} 当前资源原件，跳过", flush=True)
        current(lane)
        capture_lane(lane, cfg, built)
        state = app_sop.read_state()
        inputs = app_sop.monitor_inputs(app, state)
        if f"launch_{lane}" in app_sop.delivery_coverage(app, inputs, state):
            call(accept, env={**os.environ, "HYDRO_LANE_REUSE_BUILD": str(receipt(lane)), "HYDRO_LANE_NO_WAIT": "1"},
                 capture=True, acceptance=True)
        else:
            print(f"＝ {lane} 当前启动验收，跳过", flush=True)
        current(lane)
    if not options.prepare_only:
        call([sys.executable, Path.home() / "Apps/apps-portal/site/perf_block.py", ROOT])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, sim_lane.LaneError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
