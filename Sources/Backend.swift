import Foundation
import UIKit

// =============================================================================
// 闸内的非流式请求：图片上传（/api/vision/upload）与引文回原文
// （POST /api/tools/kb.read_doc/invoke —— 后端没有 GET /api/rag/doc 端点，
// CitationBrief.source 就是 kb.read_doc 的 doc_id，同一命名空间，直接调）。
//
// 撞闸处理与流层同款：blocked → 拿钥匙串密码换会话 → **只重试一次**。
// 抽成一个 helper 而不是每个调用各写一份 —— day-deck 的教训：三份各自漂移的
// 判据，坏的那份表现是「解码失败」，指向完全错误的方向。
// =============================================================================

enum BackendError: Error {
    case gate(String)           // 撞闸且自动换会话失败 —— UI 该弹密码框
    case http(Int, String)
    case network(String)
    case contract(String)       // 响应解不出契约字段：点名字段，不容错

    var message: String {
        switch self {
        case .gate(let m):      return "被访问闸拦住：\(m)"
        case .http(let s, let b): return "HTTP \(s)：\(b.prefix(200))"
        case .network(let m):   return "连不上后端：\(m)"
        case .contract(let m):  return "响应对不上契约：\(m)"
        }
    }
}

enum Backend {
    /// 撞闸自动换会话重试一次的包装。op 必须幂等（GET / 纯上传 / 只读 invoke 都满足）。
    static func gateRetrying(_ op: () async throws -> (Data, URLResponse))
        async throws -> (Data, HTTPURLResponse)
    {
        var (data, resp) = try await op()
        if Gate.blocked(resp) {
            guard let pw = Gate.password else { throw BackendError.gate("这台设备还没有闸凭证") }
            do { try await Gate.login(password: pw, session: ChatStream.session) }
            catch { throw BackendError.gate((error as? Gate.Failure)?.message ?? "登录失败") }
            (data, resp) = try await op()
            if Gate.blocked(resp) { throw BackendError.gate("换了会话仍被拦 —— 密码可能已经改了") }
        }
        guard let http = resp as? HTTPURLResponse else {
            throw BackendError.network("响应不是 HTTP")
        }
        return (data, http)
    }

    // MARK: - 图片上传

    /// 传一张图，回 image_id。后端契约（app/routes_vision.py）：multipart 字段名 `file`，
    /// ≤12MB，mime 白名单 png/jpeg/webp（按魔数判）。响应 {image_id, w, h, bytes, ...}。
    static func uploadImage(_ image: UIImage) async throws -> String {
        guard let jpeg = compressed(image) else {
            throw BackendError.contract("图片压不进 12MB —— 换一张或截取局部")
        }
        let boundary = "hydro-deck-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: ChatStream.base + "/api/vision/upload")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90    // 手机网络传几 MB，20s 不够（wrong-book 实测同款）
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, http) = try await gateRetrying {
            try await ChatStream.session.upload(for: req, from: body)
        }
        guard http.statusCode == 200 else {
            throw BackendError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["image_id"] as? String else {
            throw BackendError.contract("upload 响应缺 image_id")
        }
        return id
    }

    /// 压图阶梯（wrong-book PaperScan.jpeg 同款思路，上限按本后端的 12MB 放宽）：
    /// 有地板 —— 都超就返回 nil 明说传不了，宁可传不了也不压糊。
    private static func compressed(_ image: UIImage) -> Data? {
        let cap = 11 * 1024 * 1024          // 留 1MB 余量给 multipart 包装
        for (edge, q) in [(CGFloat(2400), 0.82), (2000, 0.78), (1700, 0.72)] {
            let img = shrink(image, maxEdge: edge)
            if let d = img.jpegData(compressionQuality: q), d.count <= cap { return d }
        }
        return nil
    }

    private static func shrink(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let m = max(image.size.width, image.size.height)
        guard m > maxEdge else { return image }
        let k = maxEdge / m
        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1   // 不设的话 @3x 屏上长边 2400 实际变 7200（wrong-book 实测）
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 引文回原文

    struct DocPage {
        let title: String
        let displayPath: String
        let text: String
        let nextOffset: Int?        // truncated=true 时翻页用
    }

    /// 按 doc_id 读原文一页。走工具直调通道（HTTP 恒 200，成败看 ok）。
    static func readDoc(docId: String, offset: Int = 0, maxChars: Int = 4000)
        async throws -> DocPage
    {
        var req = URLRequest(url: URL(string: ChatStream.base + "/api/tools/kb.read_doc/invoke")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject:
            ["args": ["doc_id": docId, "offset": offset, "max_chars": maxChars]])

        let (data, http) = try await gateRetrying {
            try await ChatStream.session.data(for: req)
        }
        guard http.statusCode == 200 else {
            throw BackendError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.contract("invoke 响应不是 JSON 对象")
        }
        // InvokeResponse 契约（schemas/tools.py）：HTTP 恒 200，成败看 ok；
        // 业务结果在 result，错误在 error{code, message/detail}。
        guard d["ok"] as? Bool == true else {
            let e = d["error"] as? [String: Any]
            let err = (e?["message"] as? String) ?? (e?["detail"] as? String) ?? "kb.read_doc 调用失败"
            throw BackendError.contract(err)
        }
        guard let v = d["result"] as? [String: Any], let text = v["text"] as? String else {
            throw BackendError.contract("kb.read_doc 结果缺 text")
        }
        let truncated = v["truncated"] as? Bool ?? false
        return DocPage(title: v["title"] as? String ?? docId,
                       displayPath: v["display_path"] as? String ?? "",
                       text: text,
                       nextOffset: truncated ? v["next_offset"] as? Int : nil)
    }

}
