import Foundation

// 把一份 SSE 字节原样当成后端的回应：本地 URLProtocol，零真实网络。
// 字节来自后端的生产出网路径（service/scripts/dump_ui_frames.py），不是手写的帧。
// 新旧两版客户端的检查共用本文件，所以这里只碰两版都有的接口。
final class FrameTransport: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FrameTransport.self]
        return URLSession(configuration: configuration)
    }

    static func load(_ directory: URL, _ name: String) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).sse")), !data.isEmpty else {
            fatalError("读不到帧样本 \(name).sse（目录 \(directory.path)）")
        }
        body = data
    }
}

func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("PASS \(what)") } else { print("FAIL \(what) \(detail())"); exit(1) }
}
