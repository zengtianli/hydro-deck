// ⚠ 本文件从 `~/Apps/ios/blog-reader/Sources/MarkdownView.swift` **逐字移植**(舰队契约 6)。
//   这里不改它 —— 改了两边就会漂,而漂了的表现是「同一篇复盘在两个 app 里排版不一样」,
//   没有任何机器门会报。要改渲染行为,改 blog-reader 那份再同步过来。
//   为什么必须真渲染:全局产物规范 —— 展示 md 的界面露出字面 `**` / `|---|` / 行首 `##` 即不合格。

import SwiftUI

// =============================================================================
// AskClaude — MarkdownView（Claude 回复的 markdown 渲染）
//
// 结构：解析层（MDBlock + parseMarkdownBlocks，纯值逻辑零 UI 依赖，可用 swiftc
// 单独编译对拍）＋ 渲染层（MarkdownText，SwiftUI）。行内样式（**粗** *斜* `代码`
// [链接]）委托系统 AttributedString(markdown:)，块级（标题/表格/代码块/引用/列表/
// 分隔线）系统不管，自己切块。
//
// 流式容错：未闭合的 ``` 围栏、只有表头没分隔行的表格，都按「已看到的部分」优雅
// 渲染，不抛错不闪烁。
// =============================================================================

// MARK: - 跨平台色板（2026-08-19 加）
//
// 本文件被 iOS 侧 vendored 复用（~/Apps/ios/blog-reader，逐字节一致，由那边的
// check-markdown-drift.sh 守着）。`Color(nsColor:)` 只在 macOS 上有，iOS 编不过。
// 分叉出一份 iOS 版是错的做法 —— 那道逐字节门会从此永远红，红久了就没人看。
// 所以把平台差异收在这四个常量里，两边共用同一个文件。
//
// **macOS 上的取值一个没变**（还是同样的 NSColor 语义色），所以 ask-claude 的
// 观感零变化；iOS 侧用 UIKit 里语义对应的那两个。
#if os(macOS)
import AppKit
private let mdFill = Color(nsColor: .quaternarySystemFill)
private let mdSeparator = Color(nsColor: .separatorColor)
#else
import UIKit
private let mdFill = Color(uiColor: .quaternarySystemFill)
private let mdSeparator = Color(uiColor: .separator)
#endif

// MARK: - 解析层（纯值逻辑）

enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String, text: String)
    case table(header: [String], rows: [[String]])
    case quote(text: String)      // 引用体原文（已剥 "> "），渲染时递归解析——引用内的表格/列表照常成块
    case list(items: [MDListItem])
    case rule
}

struct MDListItem: Equatable {
    var indent: Int      // 嵌套层级 0..n（每 2 空格算 1 级）
    var marker: String   // "•" / "1." / "2." …
    var text: String
}

/// 一行是否是表格行（含未转义的 |）。
private func isTableRow(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("|") else { return false }
    // 排除代码类内容误判：行首是 | 或行内有 " | " 都算
    return t.hasPrefix("|") || t.contains(" | ")
}

/// 表格分隔行：| --- | :---: | 这类。必须含 |，且每段是 :?-{3,}:?（空段 = 首尾边界）。
/// 收紧原因（对抗测试实证）：裸 "---" 会把「含 | 的散文 + 分隔线」吞成空表格；
/// "| - | - |"（Claude 常用的空 cell 占位行）会截断表格。
private func isTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("|"), t.contains("-") else { return false }
    guard t.allSatisfy({ "|-: \t".contains($0) }) else { return false }
    for seg in t.split(separator: "|", omittingEmptySubsequences: false) {
        var s = seg.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { continue }
        if s.hasPrefix(":") { s.removeFirst() }
        if s.hasSuffix(":") { s.removeLast() }
        if s.count < 3 || !s.allSatisfy({ $0 == "-" }) { return false }
    }
    return true
}

/// 拆一行表格为 cells：剥首尾 |，按未转义 | 切，cell 内 \| 还原成 |。
private func splitTableCells(_ line: String) -> [String] {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
    var cells: [String] = []
    var cur = ""
    var escaped = false
    for ch in t {
        if escaped {
            cur.append(ch == "|" ? "|" : "\\\(ch)")
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "|" {
            cells.append(cur.trimmingCharacters(in: .whitespaces))
            cur = ""
        } else {
            cur.append(ch)
        }
    }
    if escaped { cur.append("\\") }
    cells.append(cur.trimmingCharacters(in: .whitespaces))
    return cells
}

/// 列表项行：- / * / + / 1. / 1) 开头。返回 (indent 层级, marker, 正文)。
private func matchListItem(_ line: String) -> (Int, String, String)? {
    var indent = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
        indent += line[idx] == "\t" ? 2 : 1
        idx = line.index(after: idx)
    }
    let rest = String(line[idx...])
    // 无序：- x / * x / + x（marker 后必须有空格，避免把 **粗体** 当列表）
    for m in ["- ", "* ", "+ "] where rest.hasPrefix(m) {
        let body = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return (indent / 2, "•", body)
    }
    // 有序：1. x / 12) x
    var digits = ""
    var j = rest.startIndex
    while j < rest.endIndex, rest[j].isNumber, digits.count < 3 {
        digits.append(rest[j]); j = rest.index(after: j)
    }
    if !digits.isEmpty, j < rest.endIndex, rest[j] == "." || rest[j] == ")" {
        let afterDot = rest.index(after: j)
        if afterDot < rest.endIndex, rest[afterDot] == " " {
            let body = String(rest[rest.index(after: afterDot)...])
                .trimmingCharacters(in: .whitespaces)
            return (indent / 2, "\(digits).", body)
        }
    }
    return nil
}

/// 标题行：#{1,6} + 空格。闭合式 "## 标题 ##" 的尾部井号剥掉（仅当其前有空格，不伤 "C##"）。
private func matchHeading(_ line: String) -> (Int, String)? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("#") else { return nil }
    let level = t.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level) else { return nil }
    let rest = t.dropFirst(level)
    guard rest.first == " " else { return nil }
    var body = rest.trimmingCharacters(in: .whitespaces)
    let trailing = body.reversed().prefix(while: { $0 == "#" }).count
    if trailing > 0, trailing < body.count {
        let cut = body.index(body.endIndex, offsetBy: -trailing)
        if body[..<cut].hasSuffix(" ") {
            body = body[..<cut].trimmingCharacters(in: .whitespaces)
        }
    }
    return (level, body)
}

/// 分隔线：--- / *** / ___（3+，允许空格）。
private func isRule(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    guard t.count >= 3 else { return false }
    return t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" }
}

/// 主入口：整段文本 → 块序列。流式中的半截内容也要能稳定解析。
func parseMarkdownBlocks(_ text: String) -> [MDBlock] {
    // CRLF/孤 \r 先归一：\r 不在 whitespaces 里，会让表格分隔行判定整体失效。
    // 注意必须查 unicodeScalars："\r\n" 是单个 grapheme，contains("\r") 对纯 CRLF 文本是 false。
    let normalized = text.unicodeScalars.contains("\r")
        ? text.replacingOccurrences(of: "\r\n", with: "\n")
              .replacingOccurrences(of: "\r", with: "\n")
        : text
    let lines = normalized.components(separatedBy: "\n")
    var blocks: [MDBlock] = []
    var para: [String] = []

    func flushPara() {
        if !para.isEmpty {
            blocks.append(.paragraph(para.joined(separator: "\n")))
            para = []
        }
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 代码围栏 ``` / ~~~。闭栏必须整行只含同种围栏字符（CommonMark：闭栏不带
        // info string）—— 否则围栏内的 "```python" 会把外层围栏闭掉，后文 code/正文反转。
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flushPara()
            let fenceChar = trimmed.first!
            let fenceLen = trimmed.prefix(while: { $0 == fenceChar }).count
            var lang = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
            if lang.contains("`") { lang = "" }
            func isClose(_ s: String) -> Bool {
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.count >= 3 && t.allSatisfy { $0 == fenceChar }
            }
            var code: [String] = []
            i += 1
            while i < lines.count, !isClose(lines[i]) {
                code.append(lines[i]); i += 1
            }
            if i < lines.count { i += 1 }   // 吃掉闭栏；EOF 未闭合 = 流式中，照常渲染
            blocks.append(.code(lang: lang, text: code.joined(separator: "\n")))
            continue
        }

        // 空行 = 段落边界
        if trimmed.isEmpty {
            flushPara()
            i += 1
            continue
        }

        // 表格：当前行像表格行，且下一行是分隔行
        if isTableRow(line), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            flushPara()
            let header = splitTableCells(line)
            var rows: [[String]] = []
            i += 2
            while i < lines.count {
                // 表体内的视觉分隔行（| --- |）跳过而非截断——截断会让后续数据行裸奔成段落
                if isTableSeparator(lines[i]) { i += 1; continue }
                // 表体行必须 | 开头：紧贴表格的含 " | " 散文不吞成数据行
                guard lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") else { break }
                var cells = splitTableCells(lines[i])
                // 列数对齐表头：多截少补
                if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
                while cells.count < header.count { cells.append("") }
                rows.append(cells)
                i += 1
            }
            blocks.append(.table(header: header, rows: rows))
            continue
        }

        // 标题
        if let (level, txt) = matchHeading(line) {
            flushPara()
            blocks.append(.heading(level: level, text: txt))
            i += 1
            continue
        }

        // 分隔线（在列表判定之前：--- 不是列表）
        if isRule(line) {
            flushPara()
            blocks.append(.rule)
            i += 1
            continue
        }

        // 引用块
        if trimmed.hasPrefix(">") {
            flushPara()
            var qlines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                var inner = String(t.dropFirst())
                if inner.hasPrefix(" ") { inner.removeFirst() }
                qlines.append(inner)
                i += 1
            }
            blocks.append(.quote(text: qlines.joined(separator: "\n")))
            continue
        }

        // 列表（连续项聚为一块；缩进续行并进上一项）
        if matchListItem(line) != nil {
            flushPara()
            var items: [MDListItem] = []
            while i < lines.count {
                if let (indent, marker, body) = matchListItem(lines[i]) {
                    items.append(MDListItem(indent: indent, marker: marker, text: body))
                    i += 1
                } else if !items.isEmpty,
                          lines[i].hasPrefix("  "),
                          !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    items[items.count - 1].text += "\n"
                        + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                } else {
                    break
                }
            }
            blocks.append(.list(items: items))
            continue
        }

        // 普通段落行
        para.append(line)
        i += 1
    }
    flushPara()
    return blocks
}

// MARK: - 行内样式（系统 markdown 解析 + 行内代码上样式）

/// CommonMark flanking 规则在 CJK 标点紧贴 **…** 时会让粗体整个失效（LLM 高频模式：
/// "**注意：**这里" / "她说**「不去」**然后"，对抗测试 NS 层实证零样式 run）。
/// 解法：在成对 ** 的内侧插零宽空格 U+200B 保住 flanking，解析完再剥除。
/// 内侧首尾是 * 的（***粗斜***）不动，交给系统原生处理。
private let strongPairRegex = try! NSRegularExpression(
    pattern: "\\*\\*(?![*\\s])((?:(?!\\*\\*).)+?)(?<![*\\s])\\*\\*")

private func sentinelizeStrong(_ s: String) -> String {
    guard s.contains("**") else { return s }
    let ns = s as NSString
    let matches = strongPairRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return s }
    var out = ""
    var last = 0
    for m in matches {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        out += "**\u{200B}" + ns.substring(with: m.range(at: 1)) + "\u{200B}**"
        last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
}

func inlineAttributed(_ s: String) -> AttributedString {
    var opts = AttributedString.MarkdownParsingOptions()
    opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
    guard var attr = try? AttributedString(markdown: sentinelizeStrong(s), options: opts) else {
        return AttributedString(s)
    }
    while let r = attr.range(of: "\u{200B}") { attr.removeSubrange(r) }
    for run in attr.runs {
        if let intent = run.inlinePresentationIntent, intent.contains(.code) {
            attr[run.range].font = .system(.body, design: .monospaced)
            attr[run.range].backgroundColor = mdFill
        }
    }
    return attr
}

/// 行内解析缓存：流式每 delta 全文重渲染，但前缀块内容不变 → 直接命中，
/// 把 O(n·delta) 的 AttributedString 重解析压掉。视图只在主线程渲染，无并发访问。
enum MDInlineCache {
    static var store: [String: AttributedString] = [:]
    static func attributed(_ s: String) -> AttributedString {
        if let hit = store[s] { return hit }
        if store.count > 4096 { store.removeAll(keepingCapacity: true) }
        let v = inlineAttributed(s)
        store[s] = v
        return v
    }
}

// MARK: - 渲染层

struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let txt):
            Text(MDInlineCache.attributed(txt))
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let txt):
            Text(MDInlineCache.attributed(txt))
                .textSelection(.enabled)

        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !lang.isEmpty {
                    Text(lang).font(.caption2).foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(mdFill))   // 与气泡底(controlBackground)差一档,代码块才像代码块
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(mdSeparator, lineWidth: 0.5))

        case .table(let header, let rows):
            // 嵌套单轴(外层已是 vertical ScrollView):窄表 cell 上限内自然换行,宽表走横滚,
            // 不会被压成逐字竖条,也不会撑出气泡。
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(MDInlineCache.attributed(cell))
                                .fontWeight(.semibold)
                                .textSelection(.enabled)
                                .frame(maxWidth: 280, alignment: .leading)
                                .gridColumnAlignment(.leading)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MDInlineCache.attributed(cell))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 280, alignment: .leading)
                                    .gridColumnAlignment(.leading)
                            }
                        }
                        if ri < rows.count - 1 {
                            Divider().gridCellUnsizedAxes(.horizontal)
                                .opacity(0.4)
                        }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(mdFill.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(mdSeparator, lineWidth: 0.5))

        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                MarkdownText(text: inner)     // 递归:引用内的表格/列表/代码照常渲染
                    .foregroundStyle(.secondary)
            }

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Text(MDInlineCache.attributed(item.text))
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}
