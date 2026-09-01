import SwiftUI
import PhotosUI

// =============================================================================
// 主屏：对话流 + 输入条（麦克风/相册/发送-停止）+ 历史 sheet + 引文原文 sheet。
//
// 流式期间用户上滚 = 停止自动吸底（后端复审轮抓过「每条 delta 钉 scrollTop、
// 综述期间没法回看」的坑）；再点发送恢复吸底。
// 历史列表照 day-deck DayPicker 范式：sheet + List + 选中回写，不发明抽屉。
// =============================================================================

struct ChatView: View {
    @State private var model = ChatModel()
    @State private var voice = VoiceInput()
    @State private var speaker = Speaker()
    @State private var input = ""
    @State private var autoFollow = true
    @State private var showHistory = false
    @State private var citationDoc: TurnRecord.CitationRecord?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.turns.isEmpty && model.draftQuestion == nil {
                            emptyHint
                        }
                        ForEach(model.turns) { turn in
                            TurnView(turn: turn, speaker: speaker, voice: voice) { cite in
                                citationDoc = cite
                            }
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
                    // 新布局赛跑、停在半中间（模拟器实测）。等一拍布局落定再滚。
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新会话", systemImage: "plus.bubble") { model.newSession() }
                        Button("重设闸密码", systemImage: "key") {
                            model.gateMessage = ""
                            model.needGatePassword = true
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $model.needGatePassword) { GateSheet(model: model) }
        .sheet(isPresented: $showHistory) { HistoryView(model: model) }
        .sheet(item: $citationDoc) { c in CitationSheet(citation: c) }
        .task {
            await Gate.seedFromLaunchArg(session: ChatStream.session)
            await model.resumePendingIfAny()
            // 验证通道（同 day-deck 的 `-tab N`）：`-ask <问题>` 启动即自动发一问，
            // 让 CLI 验收能走 app 自己的完整路径。生产路径上恒为空。
            if let q = UserDefaults.standard.string(forKey: "ask"), !q.isEmpty {
                await model.send(q)
            }
        }
        .onChange(of: scenePhase) { _, p in
            // 回前台：iOS 切后台几秒就掐 SSE；run 还在服务端跑，回来接着取。
            guard p == .active else { return }
            Task { await model.resumePendingIfAny() }
        }
        .onChange(of: pickedPhotos) {
            let items = pickedPhotos
            pickedPhotos = []
            guard !items.isEmpty else { return }
            Task {
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self),
                       let img = UIImage(data: d) {
                        await model.attach(img)
                    }
                }
            }
        }
    }

    // MARK: - 子块

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("问一句试试").font(.headline)
            Text("引用文号问指标分档、对比两版标准差异、拍张表格照片让它读数、或让它跑一次承载力/效率评价。答案带引文；坏掉的算法它会如实拒答。")
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
            if !model.draftSteps.isEmpty {
                StepsDisclosure(steps: model.draftSteps, live: true)
            }
            if model.draftAnswer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(text: model.draftAnswer)
                if model.streaming || model.catchingUp {
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

    // MARK: - 输入条

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = voice.problem {
                Text(p).font(.caption).foregroundStyle(.red).padding(.horizontal, 4)
            }
            if !model.attachments.isEmpty || model.uploadingImage {
                attachmentRow
            }
            HStack(spacing: 8) {
                micButton
                photoButton
                if CameraPicker.available { cameraButton }
                inputField
                if model.streaming || model.catchingUp { stopButton } else { sendButton }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .onChange(of: voice.transcript) {
            if voice.recording || !voice.transcript.isEmpty { input = voice.transcript }
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { a in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: a.thumb)
                            .resizable().scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button { model.removeAttachment(a.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 5, y: -5)
                    }
                }
                if model.uploadingImage {
                    ProgressView().frame(width: 52, height: 52)
                }
            }
            .padding(.horizontal, 4).padding(.top, 4)
        }
    }

    /// 点一下开始、再点一下结束；转写实时回填输入框，**发送仍由人点**（转写会错字，
    /// 自动发送 = 把错字发给 agent 再白等几十秒）。
    private var micButton: some View {
        Button {
            speaker.stop()          // 录音与朗读共用 AVAudioSession，先停另一头（复审 finding）
            voice.toggle()
        } label: {
            Image(systemName: voice.recording ? "mic.fill" : "mic")
                .font(.system(size: 22))
                .foregroundStyle(voice.recording ? .red : Color.accentColor)
                .symbolEffect(.pulse, isActive: voice.recording)
        }
        .disabled(model.streaming)
    }

    private var photoButton: some View {
        PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 3, matching: .images) {
            Image(systemName: "photo")
                .font(.system(size: 21))
                .foregroundStyle(Color.accentColor)
        }
        .disabled(model.streaming || model.uploadingImage)
    }

    private var cameraButton: some View {
        Button { showCamera = true } label: {
            Image(systemName: "camera")
                .font(.system(size: 21))
                .foregroundStyle(Color.accentColor)
        }
        .disabled(model.streaming || model.uploadingImage)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in
                showCamera = false
                if let img { Task { await model.attach(img) } }
            }
            .ignoresSafeArea()
        }
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
        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && model.attachments.isEmpty)
    }

    /// 停止 = 断开连接，后端当前步跑完自停；已流出的部分保留成一轮（不丢）。
    private var stopButton: some View {
        Button { model.stop() } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - 一轮完成的问答

private struct TurnView: View {
    let turn: TurnRecord
    let speaker: Speaker
    let voice: VoiceInput
    let onCitation: (TurnRecord.CitationRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuestionBubble(text: turn.question, imageCount: turn.imageCount)
            if let label = ChatModel.terminalLabel(turn.terminal) {
                Label(label, systemImage: "exclamationmark.circle")
                    .font(.caption.bold())
                    .foregroundStyle(turn.terminal == "answered_degraded"
                                     || turn.terminal == "aborted" ? .orange : .red)
            }
            if !turn.steps.isEmpty {
                StepsDisclosure(steps: turn.steps, live: false)
            }
            MarkdownText(text: turn.answer)
            HStack(spacing: 12) {
                Button {
                    voice.stop()    // 朗读前停录音：.record category 挂着 TTS 无声（复审 finding）
                    speaker.toggle(turnId: turn.id, markdown: turn.answer)
                } label: {
                    Image(systemName: speaker.speakingTurn == turn.id
                          ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                if turn.wallMs > 0 {
                    Text(String(format: "%.1fs", Double(turn.wallMs) / 1000))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !turn.citations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("引文 \(turn.citations.count) 条（点开看原文）")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(turn.citations) { c in
                        Button { onCitation(c) } label: {
                            Text("· \(c.label ?? c.source)")
                                .font(.caption).foregroundStyle(Color.accentColor)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            Divider().padding(.top, 4)
        }
    }
}

// MARK: - 过程（步骤/工具时间线）

private struct StepsDisclosure: View {
    let steps: [StepRecord]
    let live: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("第 \(s.index + 1) 步").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            if s.tools.isEmpty {
                                Text("思考").font(.caption2).foregroundStyle(.tertiary)
                            }
                            ForEach(s.tools) { t in
                                HStack(spacing: 4) {
                                    Image(systemName: t.ok == nil ? "circle.dotted"
                                          : (t.ok! ? "checkmark.circle" : "xmark.circle"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(t.ok == false ? .red : .secondary)
                                    Text(t.name).font(.caption2.monospaced())
                                    if t.durationMs > 0 {
                                        Text("\(t.durationMs)ms")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label(summary, systemImage: "list.bullet.rectangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let n = steps.count
        let m = steps.reduce(0) { $0 + $1.tools.count }
        return live ? "过程 · 第 \(n) 步 · \(m) 次工具" : "过程 · \(n) 步 · \(m) 次工具"
    }
}

private struct QuestionBubble: View {
    let text: String
    var imageCount: Int = 0
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if imageCount > 0 {
                    Label("附图 \(imageCount) 张", systemImage: "photo")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14))
            }
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
