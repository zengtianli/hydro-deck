# hydro-deck · 水利助手

水利领域 agent 的 iPhone 随身版。后端在 `~/Dev/services/hydro-agent`
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
