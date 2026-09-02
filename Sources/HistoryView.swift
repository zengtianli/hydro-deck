import SwiftUI

// =============================================================================
// 会话历史：sheet + List + 选中回写（day-deck DayPicker 范式，舰队不发明抽屉）。
// 每行 = 标题（首问）+ 时间 + 轮数徽标；左滑删除；顶部「新会话」。
//
// 宽屏（iPad / Mac）不弹 sheet，同一份 List 作为 NavigationSplitView 的常驻侧栏
// （SessionSidebar）。行视图 SessionRow 两边共用，别再长出第二份。
// =============================================================================

/// 宽屏侧栏：selection 绑到 model.session.id，点行即切会话；工具条「新会话」。
struct SessionSidebar: View {
    @Bindable var model: ChatModel

    private var selection: Binding<String?> {
        Binding(get: { model.session.id },
                set: { if let id = $0 { model.switchTo(id) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("历史 · \(model.store.sessions.count)") {
                ForEach(model.store.sessions) { s in
                    SessionRow(session: s, current: s.id == model.session.id)
                        .tag(s.id)
                        .contextMenu {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                model.deleteSession(s.id)
                            }
                        }
                }
                .onDelete { idx in
                    for i in idx { model.deleteSession(model.store.sessions[i].id) }
                }
            }
        }
        .navigationTitle("会话")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newSession() } label: {
                    Label("新会话", systemImage: "plus.bubble")
                }
            }
        }
        .overlay {
            if model.store.sessions.isEmpty {
                ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("问出第一句就会出现在这里"))
            }
        }
    }
}

struct HistoryView: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.newSession()
                    dismiss()
                } label: {
                    Label("新会话", systemImage: "plus.bubble")
                }

                Section("历史 · \(model.store.sessions.count)") {
                    ForEach(model.store.sessions) { s in
                        Button {
                            model.switchTo(s.id)
                            dismiss()
                        } label: {
                            SessionRow(session: s, current: s.id == model.session.id)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        for i in idx { model.deleteSession(model.store.sessions[i].id) }
                    }
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay {
                if model.store.sessions.isEmpty {
                    ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("问出第一句就会出现在这里"))
                }
            }
        }
    }

}

/// 一行会话：标题（首问）+ 时间 + 轮数；欠着未收完 run 的带橙色回转标。
struct SessionRow: View {
    let session: ChatSession
    let current: Bool

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(s.title).lineLimit(1)
                    .fontWeight(current ? .semibold : .regular)
                Spacer()
                if s.pendingRun != nil, !s.pendingRun!.userStopped {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("\(s.turns.count) 轮").font(.caption2).foregroundStyle(.secondary)
            }
            Text(s.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// =============================================================================
// 引文原文：点一条引文 → 按 doc_id 走 kb.read_doc 读回该文档（分页），
// 与 agent 读到的是**同一条通道、同一份正文**（不是另配一份预览实现）。
// =============================================================================

struct CitationSheet: View {
    let citation: TurnRecord.CitationRecord
    @Environment(\.dismiss) private var dismiss

    @State private var page: Backend.DocPage?
    @State private var loading = true
    @State private var error: String?
    @State private var offset = 0

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("读取原文…")
                } else if let e = error {
                    ContentUnavailableView("原文读不到", systemImage: "doc.questionmark",
                                           description: Text(e))
                } else if let p = page {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if !p.displayPath.isEmpty {
                                Text(p.displayPath).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(p.text)
                                .font(.callout)
                                .textSelection(.enabled)
                            if p.nextOffset != nil {
                                Button("继续读下一页") { Task { await loadNext() } }
                                    .padding(.top, 8)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .navigationTitle(page?.title ?? citation.label ?? "原文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await load(offset: 0) }
    }

    private func load(offset o: Int) async {
        loading = true
        defer { loading = false }
        do {
            let p = try await Backend.readDoc(docId: citation.source, offset: o)
            if o == 0 || page == nil {
                page = p
            } else {
                page = Backend.DocPage(title: p.title, displayPath: p.displayPath,
                                       text: (page?.text ?? "") + p.text,
                                       nextOffset: p.nextOffset)
            }
            offset = o
            error = nil
        } catch let e as BackendError {
            error = e.message
        } catch let e {
            error = (e as NSError).localizedDescription
        }
    }

    private func loadNext() async {
        guard let n = page?.nextOffset else { return }
        await load(offset: n)
    }
}
