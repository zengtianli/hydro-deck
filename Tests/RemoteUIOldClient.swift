import Foundation

// 接入后台覆盖项**之前**的客户端（check-remote-ui.sh 用 git show 取基线提交的源码编进来），
// 解新后端的真实出网字节：run.start 帧顶层多了一个它不认识的 `ui`，事件必须一条不少、字段不变。
@main
private struct RemoteUIOldClient {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        AIConsent.accept()
        defer { AIConsent.revoke() }
        let transport = FrameTransport.session()
        defer { transport.invalidateAndCancel() }

        for name in ["written", "broken", "malformed", "empty"] {
            FrameTransport.load(directory, name)
            let stream = try await ChatStream.open(message: "合成验收", sessionId: nil,
                                                   authorization: try AIConsent.capture(), transport: transport)
            var sessionId: String?, provider: String?, delta = "", terminal: String?, answer: String?
            var count = 0
            for try await w in stream {
                count += 1
                switch w.event {
                case .runStart(let sid, let p): sessionId = sid; provider = p
                case .answerDelta(let text, _): delta += text
                case .runEnd(let t, let a, _, _): terminal = t; answer = a
                default: break
                }
            }
            expect(count == 3 && sessionId == "sess-ui" && provider == "deepseek" && delta == "按曼宁公式"
                   && terminal == "refused_no_evidence" && answer == "语料里没有这条依据。",
                   "旧客户端解新后端的 \(name) 流：三条事件、字段不变",
                   "count=\(count) sid=\(sessionId ?? "nil") terminal=\(terminal ?? "nil")")
        }
        print("SUMMARY 改动前的客户端照常解新后端的四种出网字节")
    }
}
