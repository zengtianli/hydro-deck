#!/usr/bin/env python3
"""hydro-deck 模拟器实测：Release 构建 → 隔离模拟器 → 冷启动 unified log 计时 + 空闲 CPU/内存 → 写回 perf/simulator.json。

口径沿用 2026-09-26/27 两份原始证据（perf/raw/simulator-20260926.json、simulator-launch-20260927.json）：
  - 构建：xcodegen generate → xcodebuild Release / iphonesimulator / CODE_SIGNING_ALLOWED=NO / -derivedDataPath .dd-iphone
  - 设备：专用隔离模拟器（默认 "HydroDeck Perf"，iPhone 17 Pro，iOS 27.x），simctl 无界面启动、erase 后全新容器
  - 体积：.app 的 ditto ZIP 字节（不是 App Store 包）与 du 实占字节
  - 冷启动：terminate → 等 3 s → simctl launch；读模拟器 unified log
            CoreSimulatorBridge "Requesting launch of <bundle>" → SpringBoard "scene content state changed: ready" /
            SpringBoard "Dropping launch assertion"；丢弃安装后首次，取 5 次中位数；同设备对 com.apple.Preferences 同法校准
  - 空闲：最后一次启动后静置 45 s，60 s CPU 时间增量 ÷ 墙钟，窗口后 3 次 phys_footprint 取最大（共享 measure.py 函数，按 PID）
  - 采样隔离：候选先写 build/ 或临时目录，全部结束且源码快照三次一致后才写回仓库。

门：开跑前调用 Chapter app_sop.steady()（接电源、用户 ≥600 s 无操作、1 分钟负载 < 核数、无构建在跑），
不满足即以 75 退出，不构建、不写文件。--force-gate / --reuse-build 仅供调试，强制 dry-run。

  ~/Dev/.venv/bin/python scripts/perf/sim_measure.py                  # 正式：门满足才跑并写回
  ~/Dev/.venv/bin/python scripts/perf/sim_measure.py --dry-run        # 门满足才跑，只打印候选
  ~/Dev/.venv/bin/python scripts/perf/sim_measure.py --force-gate --idle-seconds 10 --settle-seconds 5   # 调试（自动 dry-run）

退出码：0 成功；75 门不满足；1 测量/构建失败；3 写回冲突（候选留在 build/sim-measure/）。
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HOME = Path.home()
ENGINE = HOME / "Apps/chapter/engine"
LW_SCRIPTS = HOME / "Apps/.claude/skills/app-lightweight/scripts"
sys.path.insert(0, str(ENGINE))
sys.path.insert(0, str(LW_SCRIPTS))

import app_sop  # noqa: E402  门、源码快照、iOS 证据校验（唯一责任源）
import measure  # noqa: E402  cpu_seconds / footprint_kb / footprint_peak / size_of（共享测量库）

APP_ID = "hydro-deck"
BUNDLE = "cyou.tianli.hydrodeck"
CALIBRATION_BUNDLE = "com.apple.Preferences"
SCHEME = "HydroDeck"
PROJECT = "HydroDeck.xcodeproj"
DERIVED = REPO / ".dd-iphone"
APP_PATH = DERIVED / "Build/Products/Release-iphonesimulator/HydroDeck.app"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
DEVICE_LABEL = "iPhone 17 Pro"
SIM_JSON = REPO / "perf/simulator.json"
LIGHTWEIGHT = REPO / "perf/lightweight.json"
RAW_DIR = REPO / "perf/raw"
CANDIDATES = REPO / "build/sim-measure"
TZ = app_sop.TZ
EXIT_GATE, EXIT_FAIL, EXIT_CONFLICT = 75, 1, 3
SCOPE = "Simulator App process only; excludes CoreSimulator, Simulator GUI, system services and inactive extensions"
DATA = "Fresh app container on isolated simulator; default first-run data; no production user data imported"
SIZE_KIND = "Local simulator .app ZIP; not an App Store IPA or device slice"
LAUNCH_METHOD = ('Simulator unified log: CoreSimulator "Requesting launch of <bundle>" -> SpringBoard scene content state '
                 '"ready" (app committed its first scene content) / FrontBoard "Dropping launch assertion" (launch finished). '
                 'App process terminated {wait:g} s before each run; system caches warm; first run after install discarded.')
IDLE_METHOD = ("Shared measure.py: CPU time delta / {window}s wall; 3 phys_footprint samples after CPU window, maximum reported")
IDLE_LIMITS = ("Post-launch simulator process sampling; simctl requested foreground by default; UIApplication/RunningBoard "
               "activation state was not observed and this is not a complete foreground business test.")


class Failure(RuntimeError):
    pass


def log(msg):
    print(f"[sim_measure {dt.datetime.now(TZ):%H:%M:%S}] {msg}", file=sys.stderr, flush=True)


def run(cmd, timeout=600, check=True, cwd=REPO):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise Failure(f"命令失败（{r.returncode}）：{' '.join(map(str, cmd))}\n{(r.stderr or r.stdout)[-2000:]}")
    return r


def tilde(p) -> str:
    s = str(p)
    return "~" + s[len(str(HOME)):] if s.startswith(str(HOME) + "/") else s


def sha_file(p: Path) -> str:
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def load_avg():
    return list(os.getloadavg())


def iso(t=None) -> str:
    return (dt.datetime.fromtimestamp(t, TZ) if t else dt.datetime.now(TZ)).isoformat()


def host_desc() -> str:
    return measure.device()


# ───────── 输入快照 ─────────

def app_record() -> dict:
    import yaml
    meta = yaml.safe_load((REPO / "project.yaml").read_text(encoding="utf-8")) or {}
    sop = meta.get("sop") or {}
    if not sop.get("source"):
        raise Failure("project.yaml 缺 sop.source")
    return {"id": APP_ID, "repo": REPO, "sop": sop, "form": "ios"}


def snapshot(app) -> dict:
    return app_sop.app_source_snapshot(app, app["sop"]["source"])


def tool_hashes() -> dict:
    return {"scripts/perf/sim_measure.py": sha_file(Path(__file__).resolve()),
            tilde(LW_SCRIPTS / "measure.py"): sha_file(LW_SCRIPTS / "measure.py")}


# ───────── 构建 ─────────

def build(app, udid, before) -> dict:
    t0 = time.time()
    gen = run(["xcodegen", "generate", "--spec", "project.yml"], timeout=300, check=False)
    gen_s = round(time.time() - t0, 2)
    if gen.returncode != 0:
        raise Failure(f"xcodegen 失败：{gen.stderr[-1500:]}")
    cmd = ["xcrun", "xcodebuild", "-project", PROJECT, "-scheme", SCHEME, "-configuration", "Release",
           "-sdk", "iphonesimulator", "-destination", f"id={udid}", "-derivedDataPath", str(DERIVED),
           "CODE_SIGNING_ALLOWED=NO", "build"]
    log("xcodebuild Release（iphonesimulator）…")
    t1 = time.time()
    r = run(cmd, timeout=3600, check=False)
    secs = round(time.time() - t1, 2)
    after = snapshot(app)["sha256"]
    receipt = {"exit": r.returncode, "configuration": "Release",
               "generate": {"command": ["xcodegen", "generate", "--spec", "project.yml"], "exit": gen.returncode, "seconds": gen_s},
               "command": [tilde(c) if str(c).startswith(str(HOME)) else c for c in cmd], "seconds": secs,
               "source_before_sha256": before, "source_after_sha256": after, "source_unchanged": before == after,
               "load_average_after_build": load_avg(), "built_from": "working tree"}
    if r.returncode != 0:
        raise Failure(f"xcodebuild 失败：{(r.stdout + r.stderr)[-3000:]}")
    if not APP_PATH.is_dir():
        raise Failure(f"构建产物不存在：{APP_PATH}")
    if before != after:
        raise Failure("构建期间源码输入发生变化，放弃本次测量")
    return receipt


def app_info(app_path: Path) -> dict:
    info = plistlib.loads((app_path / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise Failure(f"产物 bundle id 不符：{info.get('CFBundleIdentifier')}")
    return info


# ───────── 模拟器 ─────────

def sim_devices() -> dict:
    return json.loads(run(["xcrun", "simctl", "list", "-j", "devices", "available"]).stdout)["devices"]


def pick_runtime() -> dict:
    runtimes = json.loads(run(["xcrun", "simctl", "list", "-j", "runtimes", "available"]).stdout)["runtimes"]
    ios27 = [r for r in runtimes if r.get("platform") == "iOS" and str(r.get("version", "")).startswith("27.")]
    if not ios27:
        raise Failure("没有可用的 iOS 27.x 模拟器 runtime")
    return sorted(ios27, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]


def ensure_device(name: str, runtime: dict) -> str:
    for rid, devs in sim_devices().items():
        for d in devs:
            if d["name"] == name:
                if rid != runtime["identifier"] or d.get("deviceTypeIdentifier") not in (None, DEVICE_TYPE):
                    raise Failure(f"已有同名设备 {name} 但 runtime/机型不符：{rid} / {d.get('deviceTypeIdentifier')}")
                return d["udid"]
    log(f"创建隔离模拟器 {name}（{DEVICE_LABEL} / iOS {runtime['version']}）")
    return run(["xcrun", "simctl", "create", name, DEVICE_TYPE, runtime["identifier"]]).stdout.strip()


def device_state(udid: str) -> str:
    for devs in sim_devices().values():
        for d in devs:
            if d["udid"] == udid:
                return d["state"]
    raise Failure(f"模拟器 {udid} 消失")


def shutdown(udid: str):
    if device_state(udid) != "Shutdown":
        run(["xcrun", "simctl", "shutdown", udid], timeout=180, check=False)


def fresh_boot(udid: str, settle: float):
    shutdown(udid)
    run(["xcrun", "simctl", "erase", udid], timeout=300)
    log("无界面启动模拟器（simctl bootstatus -b，不打开 Simulator.app）…")
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=900)
    if settle > 0:
        log(f"首启静置 {settle:g} s")
        time.sleep(settle)


# ───────── 冷启动计时（unified log）─────────

def parse_ts(s: str) -> float:
    return dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def log_markers(udid: str, bundle: str, since: float) -> list[dict]:
    start = dt.datetime.fromtimestamp(since - 2).strftime("%Y-%m-%d %H:%M:%S")
    pred = (f'(process == "CoreSimulatorBridge" AND eventMessage CONTAINS "{bundle}" AND '
            f'(eventMessage BEGINSWITH "Requesting launch of" OR eventMessage BEGINSWITH "Launch successful")) OR '
            f'(eventMessage CONTAINS "sceneID:{bundle}-default] scene content state changed: ready") OR '
            f'(eventMessage CONTAINS "[app<{bundle}>:" AND eventMessage CONTAINS "Dropping launch assertion")')
    r = run(["xcrun", "simctl", "spawn", udid, "log", "show", "--start", start, "--info", "--debug",
             "--style", "ndjson", "--predicate", pred], timeout=300, check=False)
    rows = []
    for line in r.stdout.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if "timestamp" not in e or "eventMessage" not in e:
            continue
        proc = Path(e.get("processImagePath") or "").name or e.get("process", "")
        rows.append({"timestamp": e["timestamp"], "process": proc, "message": e["eventMessage"], "_t": parse_ts(e["timestamp"])})
    return sorted(rows, key=lambda x: x["_t"])


def one_launch(udid: str, bundle: str, wait: float, run_no: int, marker_timeout: float) -> dict:
    run(["xcrun", "simctl", "terminate", udid, bundle], timeout=120, check=False)
    time.sleep(wait)
    call = time.time()
    r = run(["xcrun", "simctl", "launch", udid, bundle], timeout=300)
    pid = int(r.stdout.strip().rsplit(":", 1)[-1].strip())
    deadline = time.time() + marker_timeout
    while True:
        time.sleep(2)
        rows = [x for x in log_markers(udid, bundle, call) if x["_t"] >= call - 0.5]
        req = next((x for x in rows if x["process"] == "CoreSimulatorBridge" and x["message"].startswith("Requesting launch of")), None)
        ready = next((x for x in rows if req and x["_t"] >= req["_t"] and x["process"] == "SpringBoard"
                      and "scene content state changed: ready" in x["message"]), None)
        drop = next((x for x in rows if req and x["_t"] >= req["_t"] and x["process"] == "SpringBoard"
                     and f"[app<{bundle}>:{pid}] Dropping launch assertion" in x["message"]), None)
        if req and ready and drop:
            break
        if time.time() > deadline:
            raise Failure(f"{bundle} 第 {run_no} 次启动 {marker_timeout:g} s 内未取到完整 unified log 标记："
                          f"request={bool(req)} ready={bool(ready)} launch_complete={bool(drop)}")
    return {"run": run_no, "pid": pid, "host_call_epoch": call,
            "request_to_ready_ms": round((ready["_t"] - req["_t"]) * 1000, 1),
            "request_to_launch_complete_ms": round((drop["_t"] - req["_t"]) * 1000, 1),
            "markers": [{k: v for k, v in x.items() if k != "_t"} for x in rows if x["_t"] <= drop["_t"] + 1]}


def launch_series(udid, bundle, runs, discard, wait, marker_timeout, label):
    samples = []
    for i in range(runs + discard):
        s = one_launch(udid, bundle, wait, i, marker_timeout)
        log(f"{label} #{i}{'（丢弃）' if i < discard else ''}：ready {s['request_to_ready_ms']} ms · "
            f"launch complete {s['request_to_launch_complete_ms']} ms · pid {s['pid']}")
        samples.append(s)
    kept = samples[discard:]
    return samples, round(statistics.median(x["request_to_ready_ms"] for x in kept), 1), \
        round(statistics.median(x["request_to_launch_complete_ms"] for x in kept), 1)


# ───────── 空闲 ─────────

def idle_sample(pid: int, settle: float, window: float) -> dict:
    log(f"静置 {settle:g} s 后采 {window:g} s CPU 窗口（pid {pid}）")
    time.sleep(settle)
    c0, t0 = measure.cpu_seconds(pid), time.time()
    while time.time() - t0 < window:  # 窗口内只读 CPU 时间（ps），不查 footprint
        time.sleep(min(5, max(0.0, window - (time.time() - t0))))
        measure.cpu_seconds(pid)  # 进程退出会抛 SystemExit
    c1, wall = measure.cpu_seconds(pid), time.time() - t0
    kb = measure.footprint_peak([pid], samples=3, gap=2.0)
    if not kb:
        raise Failure(f"footprint 读不到 pid {pid}")
    return {"process": str(pid), "footprint_mb": round(kb / 1024, 1), "footprint_bytes": int(kb * 1024),
            "cpu_pct": round((c1 - c0) / wall * 100, 2), "cpu_seconds_delta": round(c1 - c0, 3),
            "wall_s": round(wall, 2), "window_s": int(window) if float(window).is_integer() else window,
            "settle_s": int(settle) if float(settle).is_integer() else settle,
            "method": IDLE_METHOD.format(window=int(window) if float(window).is_integer() else window),
            "units": "footprint_mb is MiB (KB/1024, measure.py convention); footprint_bytes for decimal MB",
            "scope": SCOPE, "limitations": IDLE_LIMITS}


# ───────── 体积 ─────────

def sizes(app_path: Path, work: Path, udid: str) -> dict:
    z = work / "HydroDeck.app.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app_path), str(z)], timeout=300)
    out = {"download_bytes": z.stat().st_size, "installed_bytes": measure.size_of(app_path), "kind": SIZE_KIND,
           "method": "download_bytes = ditto -c -k --keepParent ZIP of the built .app; installed_bytes = du -sk of the built .app x 1024"}
    cont = run(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "app"], check=False).stdout.strip()
    if cont and Path(cont).is_dir():
        out["installed_copy_du_bytes"] = measure.size_of(cont)
    z.unlink()
    return out


# ───────── 组装与写回 ─────────

def build_candidates(ctx) -> tuple[dict, dict]:
    raw = {
        "schema_version": 1, "app_id": APP_ID, "environment": "simulator", "mode": "launch+idle",
        "measured_at": ctx["measured_at"], "version": ctx["version"], "configuration": "Release", "bundle_id": BUNDLE,
        "binary_sha256": ctx["binary_sha256"], "installed_binary_sha256": ctx["installed_binary_sha256"],
        "source": ctx["source"], "git_head": ctx["source"].get("commit"),
        "app_path": tilde(APP_PATH), "simulator_name": ctx["device_name"], "simulator_udid": ctx["udid"],
        "simulator_device": DEVICE_LABEL, "simulator_os": ctx["os"], "simulator_runtime": ctx["runtime_id"],
        "host": ctx["host"], "load_average_at_start": ctx["load_start"],
        "gate": ctx["gate"],
        "measurement_tool_sha256": ctx["tool_sha"], "measurement_tools": ctx["tools"],
        "scope": SCOPE, "data": DATA, "build_receipt": ctx["receipt"], "size": ctx["size"],
        "launch": {
            "samples": [{k: v for k, v in s.items() if k != "markers"} for s in ctx["app_samples"]],
            "discarded_runs": ctx["discard"], "runs": ctx["runs"],
            "ready_median_ms": ctx["ready_med"], "launch_complete_median_ms": ctx["done_med"],
            "method": LAUNCH_METHOD.format(wait=ctx["wait"]),
            "command": ["xcrun", "simctl", "launch", ctx["udid"], BUNDLE],
            "foreground_request": "simctl default; --background not supplied",
            "marker_lines": {str(s["run"]): s["markers"] for s in ctx["app_samples"]},
        },
        "calibration": {
            "measured_at": ctx["cal_at"], "device": f"{DEVICE_LABEL} / {ctx['os']} Simulator (same device as app runs)",
            "app": f"{CALIBRATION_BUNDLE} (system Settings)",
            "settings_ready_samples_ms": [s["request_to_ready_ms"] for s in ctx["cal_samples"]],
            "settings_launch_complete_samples_ms": [s["request_to_launch_complete_ms"] for s in ctx["cal_samples"]],
            "settings_ready_median_ms": ctx["cal_ready"], "settings_launch_complete_median_ms": ctx["cal_done"],
            "note": f"Same probe and markers as the app runs; first {ctx['discard']} sample(s) discarded. Shows the simulator's own "
                    "launch overhead; not a physical-device figure.",
            "marker_lines": {str(s["run"]): s["markers"] for s in ctx["cal_samples"]},
        },
        "idle": ctx["idle"],
        "source_unchanged_during_measurement": ctx["source_unchanged"],
        "binary_unchanged_during_measurement": ctx["binary_unchanged"],
        "completed_at": ctx["completed_at"],
    }
    return raw, raw  # simulator.json 需要原始文件路径与摘要，写回阶段再生成


def simulator_doc(old: dict, raw: dict, evidence_rel: str, evidence_sha: str) -> dict:
    doc = json.loads(json.dumps(old))  # 保留现有结构与未知字段
    speed_method = (raw["launch"]["method"] + f" Median of {raw['launch']['runs']} runs. Reference on the same simulator: "
                    f"system Settings app {raw['calibration']['settings_ready_median_ms']} ms to ready.")
    medians = {"first_screen_ready": raw["launch"]["ready_median_ms"], "launch_complete": raw["launch"]["launch_complete_median_ms"]}
    doc.update({
        "version": raw["version"], "configuration": "Release", "measured_at": raw["measured_at"],
        "device": f"{DEVICE_LABEL} / {raw['simulator_os']} Simulator / {raw['host']}",
        "input_sha256": raw["source"]["sha256"], "data": DATA,
        "size": {k: raw["size"][k] for k in ("download_bytes", "installed_bytes", "kind")},
        "idle": {k: raw["idle"][k] for k in ("process", "footprint_mb", "cpu_pct", "window_s", "settle_s", "method", "scope", "limitations")},
        "scope": SCOPE,
        "speed_measured_at": raw["measured_at"],
        "runtime_measurement": {"environment": "simulator", "device": DEVICE_LABEL, "os": raw["simulator_os"],
                                "version": raw["version"], "evidence": evidence_rel, "evidence_sha256": evidence_sha},
        "build": {"configuration": "Release", "binary_sha256": raw["binary_sha256"],
                  "input_sha256": raw["source"]["sha256"], "actual_build": True},
        "speed_build": {"version": raw["version"], "configuration": "Release", "binary_sha256": raw["binary_sha256"],
                        "input_sha256": raw["source"]["sha256"], "source_same_as_idle_measurement": True},
    })
    speeds = doc.get("speed_gui") or []
    for key in medians:
        if not any(s.get("key") == key for s in speeds):
            raise Failure(f"perf/simulator.json 缺 speed_gui[{key}]，结构与预期不符")
    for s in speeds:
        if s.get("key") in medians:
            s.update({"median_ms": medians[s["key"]], "runs": raw["launch"]["runs"], "method": speed_method,
                      "evidence": evidence_rel, "evidence_sha256": evidence_sha})
    return doc


def dumps(d) -> str:
    return json.dumps(d, ensure_ascii=False, indent=2) + "\n"


def evidence_name(stamp: dt.datetime) -> Path:
    p = RAW_DIR / f"simulator-{stamp:%Y%m%d}.json"
    return p if not p.exists() else RAW_DIR / f"simulator-{stamp:%Y%m%d-%H%M%S}.json"


def verify_written(app):
    """用 app_sop 自身的消费函数回读，确认 Chapter 会接受这份证据。"""
    lw = json.loads(LIGHTWEIGHT.read_text(encoding="utf-8"))
    measured = app_sop.ios_resource_raw(app, lw)
    ok, reason = app_sop.ios_resource_evidence(app, measured)
    if not ok:
        raise Failure(f"写回后 app_sop 校验未通过：{reason}")
    return measured


# ───────── 主流程 ─────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="只打印候选 JSON，不写仓库 perf 文件")
    ap.add_argument("--force-gate", action="store_true", help="调试：跳过恒定情况门；强制 dry-run")
    ap.add_argument("--reuse-build", action="store_true", help="调试：不重新构建，用现有 .dd-iphone 产物；强制 dry-run")
    ap.add_argument("--device-name", default="HydroDeck Perf")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--discard", type=int, default=1)
    ap.add_argument("--wait-seconds", type=float, default=3.0, help="terminate 后到 launch 的间隔")
    ap.add_argument("--settle-seconds", type=float, default=45.0, help="最后一次启动后静置（非默认值强制 dry-run）")
    ap.add_argument("--idle-seconds", type=float, default=60.0, help="CPU 窗口（非默认值强制 dry-run）")
    ap.add_argument("--boot-settle-seconds", type=float, default=60.0, help="erase+boot 后等待系统首启任务")
    ap.add_argument("--marker-timeout", type=float, default=90.0)
    a = ap.parse_args()

    debug = []
    if a.force_gate:
        debug.append("--force-gate")
    if a.reuse_build:
        debug.append("--reuse-build")
    if (a.settle_seconds, a.idle_seconds, a.runs, a.discard, a.wait_seconds) != (45.0, 60.0, 5, 1, 3.0):
        debug.append("非标准采样参数")
    dry = a.dry_run or bool(debug)
    if debug and not a.dry_run:
        log(f"{'、'.join(debug)} → 强制 dry-run，结果不写回")

    gate_ok, gate_why = app_sop.steady()
    if not gate_ok and not a.force_gate:
        print(f"门不满足，不测量、不写文件：{gate_why}", file=sys.stderr)
        return EXIT_GATE
    log(f"门：{'满足' if gate_ok else '不满足（--force-gate 调试）'}——{gate_why}")
    gate = {"steady": gate_ok, "reason": gate_why, "forced": not gate_ok}

    app = app_record()
    pointer = (json.loads(LIGHTWEIGHT.read_text(encoding="utf-8")).get("runtime_measurement") or {}).get("simulator")
    if pointer != "perf/simulator.json":
        raise Failure(f"perf/lightweight.json 的 runtime_measurement.simulator 指向 {pointer!r}，不是 perf/simulator.json")
    sim_json_sha0 = sha_file(SIM_JSON)
    old_doc = json.loads(SIM_JSON.read_text(encoding="utf-8"))
    tools = tool_hashes()
    tool_sha = hashlib.sha256(json.dumps(tools, sort_keys=True).encode()).hexdigest()
    load_start = load_avg()
    snap0 = snapshot(app)
    log(f"源码快照 {snap0['sha256'][:12]}（{snap0['file_count']} 文件）；perf/simulator.json 旧 input {old_doc.get('input_sha256', '')[:12]}")

    runtime = pick_runtime()
    os_label = f"iOS {runtime['version']}"
    udid = ensure_device(a.device_name, runtime)
    work = Path(tempfile.mkdtemp(prefix="hydrodeck-sim-"))
    stamp = dt.datetime.now(TZ)
    try:
        if a.reuse_build:
            receipt = {"reused_existing_build": True, "configuration": "Release", "source_before_sha256": snap0["sha256"]}
            if not APP_PATH.is_dir():
                raise Failure("--reuse-build 但没有现成产物")
        else:
            receipt = build(app, udid, snap0["sha256"])
        info = app_info(APP_PATH)
        version = f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"
        binary = APP_PATH / info["CFBundleExecutable"]
        binary_sha = sha_file(binary)
        log(f"产物 {version} · binary {binary_sha[:12]}")

        fresh_boot(udid, a.boot_settle_seconds)
        run(["xcrun", "simctl", "install", udid, str(APP_PATH)], timeout=600)
        cont = Path(run(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "app"]).stdout.strip())
        installed_sha = sha_file(cont / info["CFBundleExecutable"])
        size = sizes(APP_PATH, work, udid)
        log(f"体积：zip {size['download_bytes']} B · du {size['installed_bytes']} B")

        cal_at = iso()
        cal_samples, cal_ready, cal_done = launch_series(udid, CALIBRATION_BUNDLE, a.runs, a.discard, a.wait_seconds,
                                                         a.marker_timeout, "Settings 校准")
        run(["xcrun", "simctl", "terminate", udid, CALIBRATION_BUNDLE], check=False)
        measured_at = iso()
        app_samples, ready_med, done_med = launch_series(udid, BUNDLE, a.runs, a.discard, a.wait_seconds,
                                                         a.marker_timeout, "HydroDeck")
        idle = idle_sample(app_samples[-1]["pid"], a.settle_seconds, a.idle_seconds)
        log(f"空闲：CPU {idle['cpu_pct']}% · footprint {idle['footprint_mb']} MB")

        snap2 = snapshot(app)
        binary_unchanged = sha_file(binary) == binary_sha and sha_file(cont / info["CFBundleExecutable"]) == installed_sha
        source_unchanged = snap2["sha256"] == snap0["sha256"] and receipt.get("source_after_sha256", snap0["sha256"]) == snap0["sha256"]
        ctx = dict(measured_at=measured_at, version=version, binary_sha256=binary_sha, installed_binary_sha256=installed_sha,
                   source=snap0, device_name=a.device_name, udid=udid, os=os_label, runtime_id=runtime["identifier"],
                   host=host_desc(), load_start=load_start, gate=gate, tool_sha=tool_sha, tools=tools, receipt=receipt,
                   size=size, app_samples=app_samples, discard=a.discard, runs=a.runs, ready_med=ready_med, done_med=done_med,
                   wait=a.wait_seconds, cal_at=cal_at, cal_samples=cal_samples, cal_ready=cal_ready, cal_done=cal_done,
                   idle=idle, source_unchanged=source_unchanged, binary_unchanged=binary_unchanged, completed_at=iso())
        raw, _ = build_candidates(ctx)
        if not source_unchanged or not binary_unchanged:
            raise Failure(f"测量期间输入变化（source {source_unchanged} / binary {binary_unchanged}），不写回")
    finally:
        log("关闭模拟器")
        with_err = run(["xcrun", "simctl", "shutdown", udid], timeout=180, check=False)
        if with_err.returncode not in (0, 149) and "current state: Shutdown" not in with_err.stderr:
            log(f"shutdown 返回 {with_err.returncode}：{with_err.stderr.strip()[:200]}")
        shutil.rmtree(work, ignore_errors=True)

    evidence = evidence_name(stamp)
    evidence_rel = evidence.relative_to(REPO).as_posix()
    raw_text = dumps(raw)
    raw_sha = hashlib.sha256(raw_text.encode()).hexdigest()
    new_doc = simulator_doc(old_doc, raw, evidence_rel, raw_sha)
    doc_text = dumps(new_doc)

    if dry:
        cand = Path(tempfile.mkdtemp(prefix="hydrodeck-sim-candidate-"))
        (cand / evidence.name).write_text(raw_text, encoding="utf-8")
        (cand / "simulator.json").write_text(doc_text, encoding="utf-8")
        print(json.dumps({"dry_run": True, "reasons": debug or ["--dry-run"], "candidate_dir": str(cand),
                          "would_write": [evidence_rel, "perf/simulator.json"], "simulator_json": new_doc},
                         ensure_ascii=False, indent=2))
        return 0

    # 候选先落 build/，核对并发改动后再写回仓库
    cand = CANDIDATES / f"{stamp:%Y%m%d-%H%M%S}"
    cand.mkdir(parents=True, exist_ok=True)
    (cand / evidence.name).write_text(raw_text, encoding="utf-8")
    (cand / "simulator.json").write_text(doc_text, encoding="utf-8")
    if sha_file(SIM_JSON) != sim_json_sha0:
        print(f"写回冲突：perf/simulator.json 在测量期间被改动；候选保留在 {cand}", file=sys.stderr)
        return EXIT_CONFLICT
    if snapshot(app)["sha256"] != snap0["sha256"]:
        print(f"写回前源码快照已变化；候选保留在 {cand}", file=sys.stderr)
        return EXIT_CONFLICT
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    evidence.write_text(raw_text, encoding="utf-8")
    tmp = SIM_JSON.with_suffix(".json.tmp")
    tmp.write_text(doc_text, encoding="utf-8")
    os.replace(tmp, SIM_JSON)
    verify_written(app)
    shutil.rmtree(cand, ignore_errors=True)
    print(json.dumps({"written": [evidence_rel, "perf/simulator.json"], "evidence_sha256": raw_sha,
                      "input_sha256": snap0["sha256"], "version": raw["version"],
                      "ready_median_ms": raw["launch"]["ready_median_ms"],
                      "launch_complete_median_ms": raw["launch"]["launch_complete_median_ms"],
                      "idle": {"cpu_pct": raw["idle"]["cpu_pct"], "footprint_mb": raw["idle"]["footprint_mb"]},
                      "size": raw["size"]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as e:
        print(f"失败：{e}", file=sys.stderr)
        sys.exit(EXIT_FAIL)
    except SystemExit as e:  # measure.py 的进程退出等以 SystemExit 报告
        if isinstance(e.code, str):
            print(f"失败：{e.code}", file=sys.stderr)
            sys.exit(EXIT_FAIL)
        raise
