import Foundation

// 平台车道只读合成会话；不带 -lane_demo YES 时使用原来的真实模型。
// URLProtocol 在演示会话中拦住所有网络请求，避免截图入口误触生产后端。
enum LaneDemo {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "lane_demo") }

    @MainActor static func makeModel() -> ChatModel {
        guard enabled else { return ChatModel() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaneDemoTransport.self]
        ChatStream.session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydro-lane-demo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let store = SessionStore(baseDir: directory)
        let now = Date(timeIntervalSince1970: 1_790_870_400)
        let examples: [(String, String)] = [
            ("北岚溪：如何整理现场观测？", """
            ## 先保留原始记录
            以下是**虚构的演示资料**，用于展示对话与表格阅读，不作为工程结论。

            | 观测点 | 水位（m） | 说明 |
            | --- | --- | --- |
            | 上游一号 | 2.31 | 演示样本 |
            | 下游二号 | 2.08 | 演示样本 |

            1. 按测点记录时间、仪器与单位。
            2. 回看原始表格，再核对缺测和异常值。
            3. 把依据和计算过程留在同一份记录中。

            正式计算需要采用项目已核验的数据与适用标准。
            """),
            ("雨量表有哪些需要核对的字段？", "先核对观测日期、测站、时间步长和雨量单位，再标明缺测与补测来源。此会话为虚构演示，不包含实际项目数据。"),
            ("两版资料如何保留来源？", "保留原件、版本日期与引用位置；每条数字沿原始材料核对。这是虚构的界面演示。")
        ]
        for (index, example) in examples.reversed().enumerated() {
            var session = ChatSession(id: "lane-example-\(index)", serverSessionId: nil,
                                      createdAt: now, updatedAt: now)
            session.turns = [TurnRecord(question: example.0, answer: example.1,
                                       terminal: "answered", citations: [], wallMs: 1200)]
            store.save(session)
        }
        return ChatModel(store: store)
    }
}

private final class LaneDemoTransport: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
