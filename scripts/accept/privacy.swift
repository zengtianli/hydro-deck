import Foundation
#if canImport(AppKit)
import AppKit
#endif

// 隐私边界固定验收：走生产 ChatModel/SessionStore/ChatStream/Backend/AIConsent，传输层换成本地 FakeBackend。
// 不调用 submitPassword / Gate.savePassword / Gate.password（都会碰本机钥匙串），不触发闸路径。
//   bash scripts/accept/_common.sh privacy

private let allowedHosts: Set<String> = ["hydro-agent.tianli.cyou", "tianli.cyou"]   // 后者仅闸登录 /_gate
private let allowedChatKeys: Set<String> = ["message", "paradigm", "session_id", "image_ids"]
private let allowedHeaderKeys: Set<String> = ["content-type", "accept", "content-length", "user-agent",
                                              "accept-encoding", "accept-language"]

@MainActor private func sseReply(sessionId: String, answer: String) -> FakeBackend.Reply {
    .init(headers: SSE.headers, chunks: [
        SSE.frame("run.start", seq: 0, payload: ["session_id": sessionId]),
        SSE.frame("answer.delta", seq: 1, payload: ["text": answer]),
        SSE.frame("run.end", seq: 2, payload: ["terminal": "answered", "answer": answer,
                                               "citations": [], "wall_ms": 5]),
    ])
}

private func sampleImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { ctx in
        ctx.cgContext.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    }
}

/// 目录下所有常规文件（递归，真实路径）。
private func files(under root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    return e.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.map { $0.resolvingSymlinksInPath() }
}

private func contains(_ url: URL, _ needle: String) -> Bool {
    guard let d = try? Data(contentsOf: url) else { return false }
    return d.range(of: Data(needle.utf8)) != nil
}

@main struct PrivacyAcceptance {
    @MainActor static func main() async {
        _ = FakeBackend.install()
        let marker = "PRIVMARK-\(UUID().uuidString.prefix(8))"
        var serial = 0
        FakeBackend.route("/api/chat/stream") { _ in
            serial += 1
            return sseReply(sessionId: "srv-sess-1", answer: "答复 \(serial)")
        }
        FakeBackend.route("/api/vision/upload") { _ in
            .init(headers: ["Content-Type": "application/json"],
                  chunks: [Data(#"{"image_id":"0123456789abcdef0123456789abcdef","w":32,"h":24}"#.utf8)])
        }

        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let scratch = ProcessInfo.processInfo.environment["HYDRO_ACCEPT_TMP"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath() } ?? home
        let storeDir = Accept.tempDir("store").resolvingSymlinksInPath()
        let realAppSupport = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? "/nonexistent")
            .appendingPathComponent("Library/Application Support/hydro-deck", isDirectory: true)
        let realBefore = Set(files(under: realAppSupport).map(\.path))
        let homeBefore = Set(files(under: home).map(\.path))

        // ── 1. 未同意：一个请求都不发，问题留本地，弹同意 ──────────────────────────
        AIConsent.revoke()
        let m = ChatModel(store: SessionStore(baseDir: storeDir))
        Accept.expect(!m.aiConsentAccepted && !AIConsent.isAccepted(), "初始状态未同意")
        let q0 = "\(marker) 未同意的问题"
        await m.send(q0)
        Accept.expect(FakeBackend.requests.isEmpty, "未同意时 send 不发出任何请求",
                      "\(FakeBackend.requests.map(\.url))")
        Accept.expect(m.unsentQuestion == q0, "未同意时问题保留在本地 unsentQuestion", "\(m.unsentQuestion ?? "nil")")
        Accept.expect(m.showAIConsent, "未同意时弹出 AI 数据同意")
        Accept.expect(m.turns.isEmpty && !m.streaming && m.draftQuestion == nil, "未同意的问题不进入对话/流式状态")
        m.showAIConsent = false
        Accept.expect(m.authorizationForNewAction() == nil && m.showAIConsent,
                      "未同意时图片选择拿不到授权（上传入口被拦）并弹同意")
        Accept.expect((try? AIConsent.capture()) == nil, "未同意时无法生成上传授权凭据")
        Accept.expect(FakeBackend.requests.isEmpty, "未同意阶段零请求（问答与图片）")

        // ── 2. 同意：本身不自动发送待发内容 ─────────────────────────────────────
        m.acceptAIConsent()
        Accept.expect(m.aiConsentAccepted && !m.showAIConsent && AIConsent.isAccepted(), "同意后状态生效")
        Accept.expect(FakeBackend.requests.isEmpty, "同意动作本身不自动发送保留的问题或图片")

        // 图片上传 + 带图提问 + 多轮
        guard let authA = m.authorizationForNewAction() else {
            Accept.expect(false, "同意后可取得新动作授权"); Accept.finish("privacy 中止")
        }
        await m.attach(sampleImage(), authorization: authA)
        Accept.expect(m.attachments.map(\.id) == ["0123456789abcdef0123456789abcdef"], "同意后图片上传成功",
                      "failure=\(String(describing: m.failure)) attachments=\(m.attachments.count)")
        let q1 = "\(marker) 第一问"
        await m.send(q1)
        let q2 = "\(marker) 第二问"
        await m.send(q2)
        Accept.expect(m.turns.count == 2 && m.turns.last?.terminal == "answered", "同意后两问均完成",
                      "turns=\(m.turns.count) failure=\(String(describing: m.failure))")

        let reqs = FakeBackend.requests
        Accept.expect(reqs.count == 3, "同意后恰好 3 个请求（1 上传 + 2 提问）", "\(reqs.map(\.url))")
        let badHost = reqs.filter { !allowedHosts.contains($0.url.host ?? "") }
        Accept.expect(badHost.isEmpty, "所有请求 host 均在白名单（hydro-agent.tianli.cyou / tianli.cyou）",
                      "\(badHost.map(\.url))")
        Accept.expect(reqs.allSatisfy { $0.url.scheme == "https" }, "所有请求均为 HTTPS")
        let gateReqs = reqs.filter { $0.url.host == "tianli.cyou" }
        Accept.expect(gateReqs.allSatisfy { $0.url.path.hasPrefix(Gate.prefix + "/") },
                      "tianli.cyou 只用于闸登录 /_gate", "\(gateReqs.map(\.url))")
        Accept.expect(reqs.allSatisfy { $0.method == "POST" }, "请求均为 POST（无查询串携带数据）")
        Accept.expect(reqs.allSatisfy { ($0.url.query ?? "").isEmpty }, "请求 URL 无查询参数")

        let chats = reqs.filter { $0.url.path == "/api/chat/stream" }
        let chatBodies = chats.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
        Accept.expect(chatBodies.count == 2, "提问 body 为 JSON 对象")
        let extraKeys = chatBodies.flatMap { $0.keys }.filter { !allowedChatKeys.contains($0) }
        Accept.expect(extraKeys.isEmpty, "提问 body 只含 message/paradigm/session_id/image_ids", "多余字段 \(extraKeys)")
        Accept.expect(chatBodies.first?["message"] as? String == q1
                      && (chatBodies.first?["image_ids"] as? [String]) == ["0123456789abcdef0123456789abcdef"]
                      && chatBodies.first?["session_id"] == nil,
                      "首问只带问题与已上传图片 id，不带会话 id", "\(chatBodies.first ?? [:])")
        Accept.expect(chatBodies.last?["session_id"] as? String == "srv-sess-1" && chatBodies.last?["image_ids"] == nil,
                      "第二问带服务端会话 id、不重复带已交付的图片", "\(chatBodies.last ?? [:])")

        // 设备标识、本机路径、账号名、密码类字段均不外发（body + header + URL）
        let secrets = [NSUserName(), NSFullUserName(), home.path, storeDir.path, scratch.path,
                       NSHomeDirectoryForUser(NSUserName()) ?? "/nonexistent", ProcessInfo.processInfo.hostName,
                       Host.current().localizedName ?? "/nonexistent"]
            .filter { $0.count >= 3 }
        let lowerKeys = ["password", "gatepw", "passwd", "keychain", "device", "idfv", "idfa", "serial", "udid"]
        var leaks: [String] = []
        for r in reqs {
            // 只看 body、path、query、header —— 不含 host：本机用户名 tianli 与域名 tianli.cyou 重合
            let bodyText: String = String(decoding: r.body, as: UTF8.self)
            let headerText: String = r.headers.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let text: String = [bodyText, r.url.path, r.url.query ?? "", headerText].joined(separator: " ")
            for s in secrets where text.contains(s) { leaks.append("\(r.url.path) 含本机信息 \(s)") }
            if r.url.path == "/api/chat/stream" {
                let lower = text.lowercased()
                for k in lowerKeys where lower.contains(k) { leaks.append("\(r.url.path) 含 \(k)") }
            }
        }
        Accept.expect(leaks.isEmpty, "请求不含用户名/主机名/本机路径/密码/设备标识", "\(leaks)")
        let badHeaders = reqs.flatMap { r in r.headers.keys.filter { !allowedHeaderKeys.contains($0.lowercased()) }
            .map { "\(r.url.path):\($0)" } }
        Accept.expect(badHeaders.isEmpty, "请求头只含内容协商类字段（无 Cookie/Authorization/自定义标识）", "\(badHeaders)")
        if let up = reqs.first(where: { $0.url.path == "/api/vision/upload" }) {
            let head = String(decoding: up.body.prefix(400), as: UTF8.self)
            Accept.expect(head.contains("name=\"file\"; filename=\"photo.jpg\"") && head.contains("Content-Type: image/jpeg"),
                          "图片上传只用固定文件名 photo.jpg 的单一 file 字段，不带原路径", head)
            let parts = String(decoding: up.body, as: UTF8.self).components(separatedBy: "Content-Disposition").count - 1
            Accept.expect(parts == 1, "图片上传 multipart 只有一个字段", "parts=\(parts)")
        } else {
            Accept.expect(false, "图片上传请求存在")
        }

        // ── 3. 撤销：新问题与上传再被拦；旧授权代际不能借用新同意 ─────────────────
        let before = FakeBackend.requests.count
        m.revokeAIConsent()
        Accept.expect(!m.aiConsentAccepted && !AIConsent.isAccepted(), "撤销后同意状态清除")
        let q3 = "\(marker) 撤销后的问题"
        await m.send(q3)
        Accept.expect(FakeBackend.requests.count == before && m.unsentQuestion == q3 && m.showAIConsent,
                      "撤销后新问题被拦、保留本地并重新弹同意",
                      "reqs=\(FakeBackend.requests.count - before) unsent=\(m.unsentQuestion ?? "nil")")
        m.showAIConsent = false
        Accept.expect(m.authorizationForNewAction() == nil, "撤销后新图片动作拿不到授权")
        m.failure = nil
        await m.attach(sampleImage(), authorization: authA)
        Accept.expect(FakeBackend.requests.count == before && m.failure != nil,
                      "撤销后旧授权的图片上传被拦且提示", "reqs=\(FakeBackend.requests.count - before)")
        await m.send("\(marker) 旧授权提问", authorization: authA)
        Accept.expect(FakeBackend.requests.count == before, "撤销后旧授权的提问被拦")

        m.acceptAIConsent()
        Accept.expect(FakeBackend.requests.count == before, "重新同意不自动补发撤销期间的问题")
        await m.send("\(marker) 旧代际提问", authorization: authA)
        m.failure = nil
        await m.attach(sampleImage(), authorization: authA)
        Accept.expect(FakeBackend.requests.count == before && m.failure != nil,
                      "旧授权代际不能借用新同意（提问与上传均不发出）", "reqs=\(FakeBackend.requests.count - before)")
        guard let authB = m.authorizationForNewAction() else {
            Accept.expect(false, "重新同意后可取得新授权"); Accept.finish("privacy 中止")
        }
        Accept.expect(authB != authA, "重新同意生成新的授权代际")
        await m.send("\(marker) 新代际提问", authorization: authB)
        Accept.expect(FakeBackend.requests.count == before + 1, "新的明确动作在新同意下可用")

        // ── 4. 本地存储：只写注入目录；删除后文件消失 ───────────────────────────
        let storeFiles = files(under: storeDir)
        Accept.expect(!storeFiles.isEmpty && storeFiles.allSatisfy { $0.lastPathComponent.hasPrefix("session-") },
                      "会话只以 session-<id>.json 写入注入的 store 目录", "\(storeFiles.map(\.lastPathComponent))")
        let outside = (files(under: scratch) + files(under: home))
            .filter { !$0.path.hasPrefix(storeDir.path + "/") && contains($0, marker) }
        Accept.expect(outside.isEmpty, "会话内容不出现在 store 目录以外的临时 HOME/临时目录文件",
                      "\(Set(outside.map(\.path)))")
        let homeNew = Set(files(under: home).map(\.path)).subtracting(homeBefore)
            .filter { !$0.hasPrefix(storeDir.path + "/") }
        let unexpectedNew = homeNew.filter { !$0.contains("/Library/Preferences/") }
        Accept.expect(unexpectedNew.isEmpty, "临时 HOME 下除偏好设置外无新增文件", "\(unexpectedNew.sorted())")
        let realAfter = files(under: realAppSupport)
        Accept.expect(Set(realAfter.map(\.path)) == realBefore && !realAfter.contains { contains($0, marker) },
                      "未写入真实用户的 Application Support/hydro-deck")
        let defaultsDump = "\(UserDefaults.standard.dictionaryRepresentation())"
        Accept.expect(!defaultsDump.contains(marker), "UserDefaults 不含会话内容")
        let pwKeys = UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.lowercased().contains("password") || $0.lowercased().contains("gatepw") }
        Accept.expect(pwKeys.isEmpty, "UserDefaults 无密码类键", "\(pwKeys)")
        let storedKeys: Set<String> = Set(storeFiles.flatMap { u -> [String] in
            guard let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
            return Array(o.keys)
        })
        Accept.expect(storedKeys.isSubset(of: ["id", "serverSessionId", "createdAt", "updatedAt", "turns", "pendingRun"]),
                      "会话 JSON 只含会话字段（无凭证/设备字段）", "\(storedKeys.sorted())")

        let sid = m.session.id
        let sessionFile = storeDir.appendingPathComponent("session-\(sid).json")
        Accept.expect(FileManager.default.fileExists(atPath: sessionFile.path), "删除前会话文件存在")
        m.deleteSession(sid)
        Accept.expect(!FileManager.default.fileExists(atPath: sessionFile.path), "删除会话后文件真正消失")
        Accept.expect(!files(under: storeDir).contains { contains($0, marker) }, "删除后 store 目录不再含该会话内容")
        let reloaded = SessionStore(baseDir: storeDir)
        Accept.expect(!reloaded.sessions.contains { $0.id == sid }, "重新加载 store 不再出现已删会话")

        // ── 5. 源码静态：闸密码只经钥匙串 ────────────────────────────────────────
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) -> String { (try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)) ?? "" }
        let gate = src("Sources/Gate.swift")
        Accept.expect(gate.contains("kSecClassGenericPassword"), "Gate.swift 用 kSecClassGenericPassword 保存密码")
        Accept.expect(gate.contains(#"service = "cyou.tianli.hydrodeck.gate""#), "Gate 钥匙串 service 为 cyou.tianli.hydrodeck.gate")
        Accept.expect(src("Sources/Store.swift").range(of: "password", options: .caseInsensitive) == nil,
                      "Store.swift 不含 password")
        let sourceNames = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources").path)) ?? []
        var defaultsWrites: [String] = []
        var urlLiterals: [String] = []
        for n in sourceNames where n.hasSuffix(".swift") {
            for (i, line) in src("Sources/\(n)").components(separatedBy: "\n").enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                let l = t.lowercased()
                if (l.contains("userdefaults") || l.contains("appstorage") || l.contains("defaults.set"))
                    && (l.contains("password") || l.contains(".set(")) && l.contains("pw") {
                    defaultsWrites.append("\(n):\(i + 1)")
                }
                if l.contains("appstorage") && l.contains("pass") { defaultsWrites.append("\(n):\(i + 1)") }
                if let r = t.range(of: #"https?://[A-Za-z0-9.\-]+"#, options: .regularExpression) {
                    urlLiterals.append(String(t[r]))
                }
            }
        }
        Accept.expect(defaultsWrites.isEmpty, "源码无把密码写入 UserDefaults/AppStorage", "\(defaultsWrites)")
        Accept.expect(!sourceNames.isEmpty && urlLiterals.allSatisfy {
                          $0.hasPrefix("https://") && allowedHosts.contains(String($0.dropFirst(8))) },
                      "源码中全部 URL 字面量均为白名单 HTTPS host", "\(urlLiterals)")
        Accept.expect(Gate.loginURL.scheme == "https" && Gate.loginURL.host == "tianli.cyou"
                      && Gate.loginURL.path.hasPrefix(Gate.prefix + "/"), "闸登录端点为 https://tianli.cyou/_gate/…")

        // ── 6. 权限用途描述与隐私清单 ───────────────────────────────────────────
        let yml = src("project.yml")
        let usage: [(api: String, file: String, key: String)] = [
            ("UIImagePickerController", "Sources/CameraPicker.swift", "INFOPLIST_KEY_NSCameraUsageDescription"),
            ("SFSpeechRecognizer", "Sources/VoiceInput.swift", "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription"),
            ("AVAudioEngine", "Sources/VoiceInput.swift", "INFOPLIST_KEY_NSMicrophoneUsageDescription"),
        ]
        for u in usage where src(u.file).contains(u.api) {
            Accept.expect(yml.contains(u.key + ":"), "使用 \(u.api) 已声明 \(u.key)")
        }

        let manifestCandidates = files(under: root.appendingPathComponent("Resources"))
            + files(under: root.appendingPathComponent("Sources"))
        let manifest = manifestCandidates.first { $0.lastPathComponent == "PrivacyInfo.xcprivacy" }
        Accept.expect(manifest != nil, "PrivacyInfo.xcprivacy 存在于 Resources/ 或 Sources/",
                      "缺失：App 使用 UserDefaults（需 NSPrivacyAccessedAPICategoryUserDefaults 理由）并向后端发送用户问题与照片，却没有隐私清单")
        if let manifest,
           let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: manifest), format: nil)) as? [String: Any] {
            Accept.expect(plist["NSPrivacyTracking"] as? Bool == false, "隐私清单声明不追踪")
            let collected = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["NSPrivacyCollectedDataType"] as? String }
            Accept.expect(collected.contains("NSPrivacyCollectedDataTypeOtherUserContent"),
                          "隐私清单声明收集用户内容（问题文本）", "\(collected)")
            Accept.expect(collected.contains("NSPrivacyCollectedDataTypePhotosorVideos"),
                          "隐私清单声明收集照片（图片上传）", "\(collected)")
            let forbidden = collected.filter { $0.contains("DeviceID") || $0.contains("PreciseLocation")
                || $0.contains("Contacts") || $0.contains("AdvertisingData") }
            Accept.expect(forbidden.isEmpty, "隐私清单不声明实际未发送的设备标识/位置/通讯录/广告数据", "\(forbidden)")
            let apis = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
            Accept.expect(apis.contains("NSPrivacyAccessedAPICategoryUserDefaults"),
                          "隐私清单声明 UserDefaults 必要理由 API", "\(apis)")
            Accept.expect(yml.contains("PrivacyInfo.xcprivacy") || manifest.path.contains("/Sources/"),
                          "隐私清单被纳入构建资源（project.yml）")
        }

        // 平台截图入口也必须隔离：合成会话独立存储，任何 URL 都在进程内被拒绝。
        let originalTransport = ChatStream.session
        UserDefaults.standard.set(true, forKey: "lane_demo")
        let demo = LaneDemo.makeModel()
        Accept.expect(demo.store.sessions.count == 3 && !demo.turns.isEmpty,
                      "平台演示有三条合成会话且首屏有内容")
        Accept.expect(demo.turns.allSatisfy { $0.answer.contains("虚构") },
                      "平台演示内容明确标注虚构")
        Accept.expect(demo.store.sessions.allSatisfy { $0.pendingRun == nil && $0.serverSessionId == nil },
                      "平台演示不含待恢复的服务端运行")
        let requestsBeforeDemo = FakeBackend.requests.count
        var blockedDemo = false
        do { _ = try await ChatStream.session.data(from: URL(string: "https://lane.invalid/never-send")!) }
        catch { blockedDemo = (error as? URLError)?.code == .notConnectedToInternet }
        Accept.expect(blockedDemo && FakeBackend.requests.count == requestsBeforeDemo,
                      "平台演示 URLProtocol 拦住请求并报告离线")
        Accept.expect(Set(files(under: realAppSupport).map(\.path)) == realBefore,
                      "平台演示没有写正式会话目录")
        UserDefaults.standard.removeObject(forKey: "lane_demo")
        ChatStream.session.invalidateAndCancel()
        ChatStream.session = originalTransport
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("hydro-lane-demo-\(ProcessInfo.processInfo.processIdentifier)"))
        AIConsent.revoke()
        Accept.finish("privacy：同意、最小字段、撤销、本地存储、钥匙串静态、隐私清单、平台演示网络与数据隔离")
    }
}
