import Foundation

// 固定验收共用件：本地假后端 + 断言输出。由 _common.sh 与生产源码、<check>.swift 一起编译。
// 每项验收自己写 `@main struct ...Acceptance { static func main() async }`。

/// 假后端：按 path 路由到脚本化响应，记录每条请求（含 body），零真实网络。
final class FakeBackend: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []          // 依次喂给客户端；SSE 一帧一个 chunk
        var failAfterChunks: URLError.Code? = nil   // 喂完 chunks 后以该错误断流（模拟断网/中断）
        var delay: TimeInterval = 0
    }
    struct Seen { let method: String; let url: URL; let headers: [String: String]; let body: Data }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [(String, (URLRequest) -> Reply)] = []
    nonisolated(unsafe) private static var log: [Seen] = []

    /// 前缀匹配 path（后登记者优先）。
    static func route(_ pathPrefix: String, _ make: @escaping (URLRequest) -> Reply) {
        lock.lock(); routes.insert((pathPrefix, make), at: 0); lock.unlock()
    }
    static func reset() { lock.lock(); routes = []; log = []; lock.unlock() }
    static var requests: [Seen] { lock.lock(); defer { lock.unlock() }; return log }

    /// 换掉生产 ChatStream.session（App 与验收共用同一代码路径，只是传输层是本地的）。
    static func install() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeBackend.self]
        c.timeoutIntervalForRequest = 10
        let s = URLSession(configuration: c)
        ChatStream.session = s
        return s
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.log.append(Seen(method: request.httpMethod ?? "GET", url: request.url!,
                             headers: request.allHTTPHeaderFields ?? [:], body: body))
        let make = Self.routes.first { path.hasPrefix($0.0) }?.1
        Self.lock.unlock()
        guard let make else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let r = make(request)
        let send = { [self] in
            let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                       headerFields: r.headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            for c in r.chunks { client?.urlProtocol(self, didLoad: c) }
            if let code = r.failAfterChunks { client?.urlProtocol(self, didFailWithError: URLError(code)) }
            else { client?.urlProtocolDidFinishLoading(self) }
        }
        if r.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + r.delay, execute: send) } else { send() }
    }
    override func stopLoading() {}
}

enum SSE {
    /// 一帧 `data: {...}\n\n`。字段按后端 obs/events.py 契约（type/seq/run_id/payload）。
    static func frame(_ type: String, seq: Int, runId: String = "run-accept", payload: [String: Any] = [:],
                      extra: [String: Any] = [:]) -> Data {
        var d: [String: Any] = ["type": type, "seq": seq, "run_id": runId, "payload": payload]
        for (k, v) in extra { d[k] = v }
        let json = try! JSONSerialization.data(withJSONObject: d)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
    static let headers = ["Content-Type": "text/event-stream"]
}

enum Accept {
    nonisolated(unsafe) static var failures = 0
    /// 一条断言：PASS/FAIL 行供 _common.sh 计数。
    static func expect(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
    }
    /// 独立临时目录（_common.sh 给的 HYDRO_ACCEPT_TMP 之下）。
    static func tempDir(_ name: String) -> URL {
        let base = ProcessInfo.processInfo.environment["HYDRO_ACCEPT_TMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let u = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// 轮询等条件成立（主线程上的 @Observable 状态），超时返回 false。
    @MainActor static func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    static func finish(_ summary: String) -> Never {
        print("SUMMARY \(summary)")
        exit(failures == 0 ? 0 : 1)
    }
}
