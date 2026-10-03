import Foundation

// Product allowlist and release channel; shared lifecycle code owns transfer/checking.
@MainActor
enum MobileProductLifecycle {
    static var channel: MobileUpdateChannel {
        #if os(macOS)
        return .sandboxCloud(channel: "private")
        #else
        return .testFlight
        #endif
    }
    static let configuration: AppConfiguration? = nil
}
