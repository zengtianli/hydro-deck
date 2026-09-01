import Foundation
import Observation

// =============================================================================
// 会话持久化（照 blog-reader/Sources/Store.swift 的档：Application Support +
// 每会话一个 JSON 文件 + 原子写）。放 Application Support 不是 Caches ——
// Caches 会被 iOS 空间紧张时自清，聊天记录被清掉表现是「历史时有时无」。
//
// 文件布局：<AppSupport>/hydro-deck/session-<id>.json
// 索引不单独存 —— 枚举目录就是索引（少一份会漂的第二真相）。
// =============================================================================

struct StepRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var index: Int
    var tools: [ToolRecord] = []

    struct ToolRecord: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var ok: Bool?
        var durationMs: Int = 0
    }
}

struct TurnRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var answer: String
    var terminal: String
    var citations: [CitationRecord]
    var wallMs: Int
    var steps: [StepRecord] = []
    var notices: [String] = []
    var imageCount: Int = 0

    struct CitationRecord: Codable, Identifiable, Equatable {
        var id = UUID()
        var kind: String
        var source: String
        var label: String?
    }
}

struct ChatSession: Codable, Identifiable {
    var id: String                      // 本地生成的 uuid；服务端 session_id 单独存
    var serverSessionId: String?        // run.start 回来的 session_id（多轮对话要带回）
    var createdAt: Date
    var updatedAt: Date
    var turns: [TurnRecord] = []
    /// 未收到终态就断掉的 run —— 下次进前台按它 catch-up。nil = 没有欠账。
    var pendingRun: PendingRun?

    struct PendingRun: Codable {
        var runId: String
        var lastSeq: Int
        var question: String
        var partialAnswer: String
        var steps: [StepRecord] = []
        var userStopped: Bool           // true = 人点了停止（终态记 aborted，不再取回）
    }

    var title: String { turns.first?.question ?? pendingRun?.question ?? "新会话" }
}

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [ChatSession] = []      // updatedAt 倒序
    private let dir: URL

    /// baseDir 注入点是给测试用的（blog-reader 同款）：不注入则测试会写真目录，
    /// 缓存命中可能是上次运行留下的假绿。
    init(baseDir: URL? = nil) {
        dir = baseDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hydro-deck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadAll()
    }

    func save(_ session: ChatSession) {
        var s = session
        s.updatedAt = Date()
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
        else { sessions.insert(s, at: 0) }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: fileURL(s.id), options: .atomic)
        }
    }

    func delete(_ id: String) {
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    func newSession() -> ChatSession {
        ChatSession(id: UUID().uuidString, serverSessionId: nil,
                    createdAt: Date(), updatedAt: Date())
    }

    // MARK: - 私有

    private func fileURL(_ id: String) -> URL {
        dir.appendingPathComponent("session-\(id).json")
    }

    private func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        sessions = files
            .filter { $0.lastPathComponent.hasPrefix("session-") }
            .compactMap { url -> ChatSession? in
                guard let d = try? Data(contentsOf: url) else { return nil }
                // 解不开的文件跳过但**不删**：可能是新版本写的（降级安装场景），
                // 删了等于静默丢聊天记录。
                return try? JSONDecoder().decode(ChatSession.self, from: d)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
