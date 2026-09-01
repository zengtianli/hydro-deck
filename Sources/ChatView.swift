import SwiftUI

// =============================================================================
// 第一屏 = 唯一主屏：对话流 + 输入条 + 闸密码 sheet。
//
// 流式期间用户上滚 = 停止自动吸底（后端复审轮抓过「每条 delta 钉 scrollTop、
// 综述 57–100s 里没法回看已出内容」的坑，客户端不重蹈）；再点发送恢复吸底。
// =============================================================================

struct ChatView: View {
    @State private var model = ChatModel()
    @State private var voice = VoiceInput()
    @State private var input = ""
    @State private var autoFollow = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.turns.isEmpty && model.draftQuestion == nil {
                            emptyHint
                        }
                        ForEach(model.turns) { turn in
                            TurnView(turn: turn)
                        }
                        if let q = model.draftQuestion {
                            draftView(question: q)
                        }
                        if let f = model.failure {
                            failureView(f)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                }
                .simultaneousGesture(DragGesture().onChanged { g in
                    if g.translation.height > 0 { autoFollow = false }   // 上滚：交还滚动权
                })
                .onChange(of: model.draftAnswer) {
                    if autoFollow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.turns.count) {
                    autoFollow = true
                    // 收尾时 draft 视图被 turn 视图整体替换，同一帧里 scrollTo 会和
                    // 新布局赛跑、停在半中间（模拟器实测：引文块留在折叠线下）。
                    // 等一拍布局落定再滚。
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("水利助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新会话", systemImage: "plus.bubble") {
                            model.turns = []
                            model.sessionId = nil
                            model.failure = nil
                        }
                        Button("重设闸密码", systemImage: "key") {
                            model.gateMessage = ""
                            model.needGatePassword = true
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $model.needGatePassword) { GateSheet(model: model) }
        .task {
            await Gate.seedFromLaunchArg(session: ChatStream.session)
            // 验证通道（同 day-deck 的 `-tab N`）：`-ask <问题>` 启动即自动发一问，
            // 让 CLI 验收能走「app 自己的完整路径」。生产路径上恒为空。
            if let q = UserDefaults.standard.string(forKey: "ask"), !q.isEmpty {
                await model.send(q)
            }
        }
    }

    // MARK: - 子块

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("问一句试试").font(.headline)
            Text("引用文号问指标分档、对比两版标准差异、或让它跑一次承载力/效率评价。答案带引文；坏掉的算法它会如实拒答。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private func draftView(question: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            QuestionBubble(text: question)
            ForEach(model.notices, id: \.self) { n in
                Label(n, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.draftAnswer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(text: model.draftAnswer)
                if model.streaming {
                    Text(model.statusLine).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func failureView(_ f: (headline: String, detail: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(f.headline, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold()).foregroundStyle(.red)
            Text(f.detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = voice.problem {
                Text(p).font(.caption).foregroundStyle(.red).padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                micButton
                inputField
                sendButton
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .onChange(of: voice.transcript) {
            if voice.recording || !voice.transcript.isEmpty { input = voice.transcript }
        }
    }

    /// 点一下开始、再点一下结束；转写实时回填输入框，**发送仍由人点**（转写会错字，
    /// 自动发送 = 把错字发给 agent 再白等几十秒）。
    private var micButton: some View {
        Button {
            voice.toggle()
        } label: {
            Image(systemName: voice.recording ? "mic.fill" : "mic")
                .font(.system(size: 22))
                .foregroundStyle(voice.recording ? .red : Color.accentColor)
                .symbolEffect(.pulse, isActive: voice.recording)
        }
        .disabled(model.streaming)
    }

    private var inputField: some View {
        TextField(voice.recording ? "说话中…" : "问水利…", text: $input, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
    }

    private var sendButton: some View {
        Button {
            if voice.recording { voice.stop() }
            let q = input
            input = ""
            voice.transcript = ""
            autoFollow = true
            inputFocused = false
            Task { await model.send(q) }
        } label: {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
        }
        .disabled(model.streaming ||
                  input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

// MARK: - 一轮完成的问答

private struct TurnView: View {
    let turn: ChatModel.Turn
    /// 引文可点：点一条展开全文（文号 + 标题 + 印发信息很长，默认两行截断）。
    @State private var expandedCites: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuestionBubble(text: turn.question)
            if let label = ChatModel.terminalLabel(turn.terminal) {
                Label(label, systemImage: "exclamationmark.circle")
                    .font(.caption.bold())
                    .foregroundStyle(turn.terminal == "answered_degraded" ? .orange : .red)
            }
            MarkdownText(text: turn.answer)
            if !turn.citations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("引文 \(turn.citations.count) 条").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(turn.citations) { c in
                        Button {
                            if expandedCites.contains(c.id) { expandedCites.remove(c.id) }
                            else { expandedCites.insert(c.id) }
                        } label: {
                            Text("· \(c.label ?? c.source)")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(expandedCites.contains(c.id) ? nil : 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            if turn.wallMs > 0 {
                Text(String(format: "%.1fs", Double(turn.wallMs) / 1000))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Divider().padding(.top, 4)
        }
    }
}

private struct QuestionBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - 闸密码

private struct GateSheet: View {
    @Bindable var model: ChatModel
    @State private var pw = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("站群闸密码", text: $pw)
                        .textContentType(.password)
                    if !model.gateMessage.isEmpty {
                        Text(model.gateMessage).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("密码只存这台设备的钥匙串；会话 7 天自动续。也可以在 Mac 上跑 bash seed-gate.sh 免手输。")
                }
                Button(busy ? "验证中…" : "登录") {
                    busy = true
                    Task { await model.submitPassword(pw); busy = false }
                }
                .disabled(pw.isEmpty || busy)
            }
            .navigationTitle("访问闸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.needGatePassword = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
