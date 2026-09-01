# hydro-deck · 水利助手

水利领域 agent 的 iPhone 随身版。后端在 `~/Dev/services/hydro-agent`
（线上 `hydro-agent.tianli.cyou`，authgate 闸内），app 是纯客户端：

- 打开即聊：`POST /api/chat/stream`，SSE 流式打字机渲染（markdown 真渲染）
- 步骤与工具进度实时可见（第 N 步 · kb.read_doc …）
- 答案带引文；七种终态如实显示（含「有保留」「拒答」）
- 闸密码存 iOS 钥匙串，会话 cookie 由系统 cookie jar 管

## 用法

```bash
bash sim-run.sh              # 模拟器
./install-to-iphone.sh       # 真机装机（WiFi）
bash seed-gate.sh            # 装机后喂一次闸密码
```
