import Foundation

// Standalone integration check: compile with AIConsent, ChatStream, Backend, Gate and PlatformCompat.
// Every request uses an ephemeral URLSession with a local URLProtocol; no real service is called.
private final class ConsentTransport: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let upload = request.url?.path == "/api/vision/upload"
        precondition(request.httpMethod == "POST")
        if upload {
            precondition(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": upload ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = upload
            ? "{\"image_id\":\"0123456789abcdef0123456789abcdef\"}"
            : "data: {\"type\":\"run.end\",\"payload\":{\"terminal\":\"answered\",\"answer\":\"synthetic reply\"}}\n\n"
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private struct ConsentChecks {
    static func main() async throws {
        let suiteName = "hydro-consent-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        precondition(!AIConsent.isAccepted(in: defaults))
        AIConsent.accept(in: defaults)
        precondition(AIConsent.isAccepted(in: defaults))
        precondition(!AIConsent.isAccepted(in: defaults, server: "https://different.invalid"))
        precondition(!AIConsent.isAccepted(in: defaults, revision: "future-revision"))
        AIConsent.revoke(in: defaults)
        precondition(!AIConsent.isAccepted(in: defaults))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentTransport.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }

        // This standalone executable has its own UserDefaults domain, not the installed app's.
        AIConsent.revoke()
        defer { AIConsent.revoke() }
        try await assertBlocked(transport)
        precondition(ConsentTransport.count == 0, "Refusal must not dispatch a question")

        AIConsent.accept()
        let firstAuthorization = try AIConsent.capture()
        let stream = try await ChatStream.open(message: "synthetic consent test",
                                              sessionId: nil, authorization: firstAuthorization,
                                              transport: transport)
        var answered = false
        for try await event in stream {
            if case .runEnd(_, let answer, _, _) = event.event {
                answered = answer == "synthetic reply"
            }
        }
        precondition(answered && ConsentTransport.count == 1, "Accepted requests must remain usable")
        let imageID = try await Backend.uploadJPEG(Data([0xFF, 0xD8, 0xFF, 0xD9]),
                                                  authorization: firstAuthorization, transport: transport)
        precondition(imageID == "0123456789abcdef0123456789abcdef" && ConsentTransport.count == 2,
                     "Accepted images must use the real multipart upload and response path")

        AIConsent.revoke()
        try await assertBlocked(transport)
        try await assertUploadBlocked(firstAuthorization, transport)
        precondition(ConsentTransport.count == 2, "Revocation must block questions and images")

        // Simulate an old selection/authentication operation resuming after revoke + re-accept.
        AIConsent.accept()
        let nextAuthorization = try AIConsent.capture()
        precondition(firstAuthorization != nextAuthorization)
        try await assertBlocked(transport, authorization: firstAuthorization)
        try await assertUploadBlocked(firstAuthorization, transport)
        precondition(ConsentTransport.count == 2, "Old work must not borrow a new acceptance")
        _ = try await Backend.uploadJPEG(Data([0xFF, 0xD8, 0xFF, 0xD9]),
                                         authorization: nextAuthorization, transport: transport)
        precondition(ConsentTransport.count == 3, "A new explicit action must remain usable")
        print("PASS: questions/images blocked before consent; accepted requests work; service/revision scope; old generation blocked after revoke/re-accept; 0 real network")
    }

    private static func assertBlocked(_ transport: URLSession,
                                      authorization: AIConsent.Authorization? = nil) async throws {
        do {
            _ = try await ChatStream.open(message: "must stay local", sessionId: nil,
                                          authorization: authorization, transport: transport)
            preconditionFailure("A request without consent was allowed")
        } catch is AIConsent.Required {
            // The expected product-level error occurs before URLSession dispatch.
        }
    }

    private static func assertUploadBlocked(_ authorization: AIConsent.Authorization,
                                            _ transport: URLSession) async throws {
        do {
            _ = try await Backend.uploadJPEG(Data([0xFF, 0xD8, 0xFF, 0xD9]),
                                             authorization: authorization, transport: transport)
            preconditionFailure("An image without the original consent was allowed")
        } catch is AIConsent.Required {
            // The production upload path refused before dispatching any bytes.
        }
    }
}
