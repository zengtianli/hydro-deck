# CLAUDE.md — hydro-deck（水利 agent 随身版）

> 舰队级规则在 `~/Apps/ios/CLAUDE.md` 与 `/appios` skill，此处只放本 app 特有的。

## 这是什么

`~/Dev/services/hydro-agent`（线上 `https://hydro-agent.tianli.cyou`，authgate 闸后）的
iOS 薄壳：打开即聊，SSE 流式渲染答案、步骤与引文。**业务零本地逻辑** ——
所有智能在后端，app 挂了先查后端，别在这里找算法。

## 约定

- **SSE 契约 SSOT = 后端 `obs/events.py`**。判别字段 `type`（`answer.delta` / `run.end` /
  `error` …），业务字段在 `payload`。客户端白名单消费，未知事件静默忽略。
  三条硬语义（都是后端 2026-09-01 立的结构轴，客户端必须跟）：
  - `answer.delta.reset == true` → 这是**新一稿**第一段，清掉已累积正文再接；
  - `error.payload.nonfatal == true` → 提示性事件，run 照常继续，**不进错误态**；
  - `run.end.answer` 是权威成稿，到达后以它为准覆盖拼接结果。
- **闸**：`Gate.swift` 从 day-deck 移植（契约 6），只改了 Keychain service
  （`cyou.tianli.hydrodeck.gate`）。密码只进钥匙串；喂密码走 `bash seed-gate.sh`（总部 shim）。
- **MarkdownView.swift 逐字移植自 day-deck（源头 blog-reader）**，别单独改这份。
- 流式期间用户上滚 = 停止自动吸底（后端复审轮抓过「每条 delta 钉 scrollTop」的坑，
  客户端别重蹈）。

## 跑法

```bash
bash sim-run.sh              # 模拟器一屏
./install-to-iphone.sh       # 真机（WiFi）
bash seed-gate.sh            # 喂闸密码（一次）
```
