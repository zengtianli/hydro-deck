# hydro-deck · 水利助手

水利领域 agent 的 iPhone 随身版。后端在 `~/Apps/hydro-assistant/service`
（线上 `hydro-agent.tianli.cyou`，authgate 闸内），app 是纯客户端，业务零本地逻辑。

## 功能（v0.2）

- **打开即聊**：`POST /api/chat/stream` SSE 流式打字机（markdown 真渲染，表格/标题/引用）
- **停止**：生成中随时打断；已流出部分保留成一轮（后端当前步后自停）
- **会话历史**：本地持久化（Application Support），多会话列表、切换、左滑删除
- **断线恢复**：切后台/杀进程/断网后，回来自动从 `/api/runs/{id}/events` 取回已生成部分
- **过程可视化**：每轮可展开「第 N 步 · 工具 ✓ 耗时」时间线
- **图片输入**：相册/拍照 → `/api/vision/upload` → 带图提问（压图阶梯有地板，压不进不硬传）
- **语音输入**：中文转写实时回填输入框（发送仍由人点）
- **TTS 朗读**：答案一键读出来（表格降级为概述）
- **引文回原文**：点引文 → `kb.read_doc` 分页读原文（与 agent 同一条读取通道）
- 七种终态如实标注（「有保留」「拒答」「已停止」不抹成完成）

## 用法

```bash
bash sim-run.sh              # 模拟器
./install-to-iphone.sh       # 真机装机（WiFi）
bash seed-gate.sh            # 装机后喂一次闸密码
```

验证通道（launch 参数，生产路径恒空）：`-gatepw <pw>` 喂闸密码、`-ask <问题>` 启动即自动发问。

## 四条平台线

`project.yml` 的同一 `HydroDeck` target 支持 iOS、macOS、visionOS；Watch 不适用原因记录在本机 `project.yaml`。不带车道参数时照常加载正式会话。

`-lane_demo YES` 使用隔离的合成会话和阻断网络的 URLProtocol；图片上传、问答及引文网络在该演示模式均不连接生产服务。Mac 的 `-lane_quiet YES`、`-lane_snapshot <png>` 由总部 `Shared/LaneSignal.swift` 执行，不上屏、不进 Dock；共享文件只经总部 `multiplatform.py` 刷新。

作者工作区的可复现入口：

```bash
# 编译始终在仓外副本中，不启动模拟器。
~/Dev/.venv/bin/python ~/Dev/tools/dev/lib/tools/macapp/ios/sim_lane.py build \
  --project-dir "$PWD" --scheme HydroDeck --platform vision --configuration Release --json
# 平台线测量由总部串行调度，跳过已有当前证据；Watch 自动跳过。
~/Dev/.venv/bin/python scripts/perf/measure_platforms.py
# 单线补测。
~/Dev/.venv/bin/python scripts/perf/measure_platforms.py --platform vision
# 调度后生成单平台商店原片；忙时退出 75，不起等待队列。
~/Dev/.venv/bin/python scripts/media/store_shots.py vision
# 绑定本轮功能、恢复与隐私证据；平台启动必须由 Chapter 调用。
~/Dev/.venv/bin/python ~/Apps/chapter/engine/app_sop.py accept --app hydro-deck --check privacy
~/Dev/.venv/bin/python ~/Apps/chapter/engine/app_sop.py accept --app hydro-deck --check launch_vision
```

同机其他产品在用模拟器时不启动新车道等待批次；由主会话统一调度。商店原片写 `shots/appstore/<平台>/`，规格检查复用总部 `ios/store_shots.py`，不得放大截图来凑尺寸。
