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

- **停止/断线语义**（与 web 前端参考实现对齐，后端无 cancel 端点）：
  停止 = 断开连接（后端当前步后自停），已流出部分固化成 `aborted` 轮；
  意外断流 = 轮询 `GET /api/runs/{id}/events?after_seq` 取回（500ms，15min 上限）；
  孤儿合成终态（顶层 `synthetic:true` / `payload.kind=run_orphaned`）当句号不当红错。
  ⚠ 取回循环里**见过终态后禁止再 persistPending** —— 会把欠账复活、complete 分支
  再补一条空 turn（2026-09-01 模拟器实测同一问固化两次，已修）。
- **持久化**：Application Support 每会话一个 JSON（blog-reader 范式）；
  枚举目录即索引，不另存索引文件。
- **引文回原文**走 `POST /api/tools/kb.read_doc/invoke`（后端没有 GET /api/rag/doc；
  CitationBrief.source 就是 kb.read_doc 的 doc_id，同一命名空间，2026-09-01 线上实测）。
- CameraPicker 在模拟器**显式隐藏**（isSourceTypeAvailable 在模拟器也可能报 true）。

## 跑法

```bash
bash sim-run.sh              # 模拟器一屏
./install-to-iphone.sh       # 真机（WiFi）
bash seed-gate.sh            # 喂闸密码（一次）
```

## 未证实观察（别当结论抄）

2026-09-01 两次出现「带 `-ask` 启动后请求根本没发出、界面白屏」，复现 5+ 次未再出现，
根因未查明（怀疑过 AVSpeechSynthesizer 冷加载卡主线程，未证实）。再遇到先
`sample <pid>` 抽主线程栈，别按旧猜测绕路。
