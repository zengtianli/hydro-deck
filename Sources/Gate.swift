import Foundation
import Security

// =============================================================================
// 站群访问闸（authgate）的客户端。
//
// 为什么需要它：本 app 的后端 `hydro-agent.tianli.cyou` 整站挂着 authgate
// （`/` 与流式端点两个 location 都 include authgate-protect）。
// 不带凭证去打 `/api/chat/stream`，URLSession 会跟着 302 走到登录页，
// 到手的是一个 **200 的 HTML**——SSE 解析失败，而失败原因完全指不出「你没登录」。
//
// 本文件从 `~/Apps/ios/day-deck/Sources/Gate.swift` 移植（舰队契约 6：移植不重写），
// 只改了 Keychain 的 service 标识 —— 两个 app 各存各的，互不影响。
// 闸的登录端点是站群共享的（cookie 域 `.tianli.cyou`），所以 loginURL 保持不变。
//
// 凭证保管三条：
//   ① 密码只进 **Keychain**，不进仓库、不进 UserDefaults、不进任何 plist。
//   ② 存的是**密码**不是 cookie：cookie 只有 7 天（服务端 API_SESSION_DAYS），
//      存密码才能自动续。
//   ③ 会话 cookie 交给 URLSession 自己的 cookie jar 管（HttpOnly + Secure 语义
//      保持完整）。
// =============================================================================

enum Gate {
    /// 闸的对外前缀。服务端 SSOT 是 `gate.URL_PREFIX`，两边都是 `/_gate`。
    static let prefix = "/_gate"
    static let loginURL = URL(string: "https://tianli.cyou\(prefix)/api/login")!

    /// 这次响应是不是被闸拦下来了。
    ///
    /// **判据是最终 URL 落在 `/_gate/` 下**，不是状态码、也不是 HTML 里有什么字：
    /// URLSession 默认会跟 302，所以到手的是登录页的 200，状态码分辨不出来；
    /// 而嗅 HTML 内容是在给页面文案建第二份判据，改个字就瞎。
    static func blocked(_ resp: URLResponse?) -> Bool {
        (resp?.url?.path ?? "").hasPrefix(prefix + "/")
    }

    // MARK: - 凭证（Keychain）

    private static let service = "cyou.tianli.hydrodeck.gate"
    private static let account = "password"

    static var hasPassword: Bool { password != nil }

    static var password: String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func savePassword(_ pw: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(pw.utf8),
            // AfterFirstUnlock：开机后第一次解锁起就可读，让后台刷新也能自动续会话。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attrs) { a, _ in a }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func forgetPassword() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    /// 装机时用启动参数喂进来的密码 —— 让「第一次要输一次密码」这步不用人做。
    ///
    /// `-gatepw <值>` 会被 iOS 放进 `NSArgumentDomain`，**只在那一次启动里存在**，
    /// 不落 UserDefaults 文件。拿到后立刻换一次会话，**验过才写钥匙串**。
    ///
    /// 密码源是 macOS 钥匙串而不是 `~/.personal_env`：`XCBuildData` 会把构建时的
    /// 完整环境连值一起记进中间产物。喂法见 `seed-gate.sh`。
    static func seedFromLaunchArg(session: URLSession) async {
        guard let pw = UserDefaults.standard.string(forKey: "gatepw"),
              !pw.isEmpty else { return }
        // 已经有一份能用的就不动它 —— 免得每次装机都白跑一次登录、白撞一次限流
        if let cur = password, cur == pw { return }
        do {
            try await login(password: pw, session: session)
            savePassword(pw)
        } catch {
            // 喂进来的密码不对就当没喂过。这里不能存 —— 存了会让 app
            // 每次刷新都拿错密码去撞限流，而界面上显示的是「已登录」。
        }
    }

    // MARK: - 登录

    struct Failure: Error { let message: String }

    /// 拿密码换一次会话。成功后 cookie 落进 `session` 的 cookie jar，
    /// 域是 `.tianli.cyou`，之后所有子域请求自动带上。
    ///
    /// 服务端返回体形如 `{"ok":true,...}`；**只看 `ok`，不碰 `cookie` 字段** ——
    /// 那个字段是给没有 cookie jar 的客户端（小程序）用的。
    static func login(password pw: String, session: URLSession) async throws {
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "password", value: pw)]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // 服务端的原话比「登录失败」有用：密码错是「密码不对。」，
        // 撞限流是「尝试过于频繁，请 N 秒后再试。」——后者重试解决不了，得让人看见。
        let said = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 200, said?["ok"] as? Bool == true { return }
        throw Failure(message: (said?["error"] as? String) ?? "登录失败（HTTP \(code)）")
    }
}
