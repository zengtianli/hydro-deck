import Foundation

/// A consent applies only to the disclosed service and disclosure revision.
/// Keep the network and UI checks on this same source; an existing login is not consent.
enum AIConsent {
    static let disclosureVersion = "2026-09-10"
    private static let key = "hydro.aiDataConsent"

    static func isAccepted(in defaults: UserDefaults = .standard,
                           server: String = ChatStream.base,
                           revision: String = disclosureVersion) -> Bool {
        let prefix = "\(server)\n\(revision)\n"
        guard let stored = defaults.string(forKey: key), stored.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(stored.dropFirst(prefix.count))) != nil
    }

    static func accept(in defaults: UserDefaults = .standard,
                       server: String = ChatStream.base,
                       revision: String = disclosureVersion) {
        defaults.set("\(server)\n\(revision)\n\(UUID().uuidString)", forKey: key)
    }

    static func revoke(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    struct Required: LocalizedError {
        var errorDescription: String? { "AI 数据处理授权尚未提供或已经变更；请再次主动发送或选择图片。" }
    }

    struct Authorization: Equatable {
        fileprivate let receipt: String
    }

    static func capture(in defaults: UserDefaults = .standard) throws -> Authorization {
        guard isAccepted(in: defaults), let receipt = defaults.string(forKey: key) else { throw Required() }
        return Authorization(receipt: receipt)
    }

    static func require(_ authorization: Authorization, in defaults: UserDefaults = .standard) throws {
        guard isAccepted(in: defaults), defaults.string(forKey: key) == authorization.receipt else {
            throw Required()
        }
    }
}
