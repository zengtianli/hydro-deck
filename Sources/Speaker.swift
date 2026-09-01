import Foundation
import Observation
import AVFoundation

// =============================================================================
// 答案朗读（TTS）。系统 AVSpeechSynthesizer，零联网零 key。
//
// 读之前把 markdown 转成能听的纯文本：**复用 MarkdownView 的解析层**
// （parseMarkdownBlocks，同 target 直接调），不另写一份正则去猜 markdown ——
// 两份解析就会漂（渲染出来的和读出来的不一致，没有门会报）。
// 表格读起来是灾难，降级为「表格（N 行），维度：…」的一句概述。
// =============================================================================

@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    /// 正在朗读哪一轮（Turn.id）；nil = 没在读。View 据此切换按钮形态。
    var speakingTurn: UUID?

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(turnId: UUID, markdown: String) {
        if speakingTurn == turnId {
            synth.stopSpeaking(at: .immediate)
            speakingTurn = nil
            return
        }
        synth.stopSpeaking(at: .immediate)
        let text = Self.speakable(markdown)
        guard !text.isEmpty else { return }
        // 播放走 .playback：录音用的 .record category 若还挂着，TTS 会无声。
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                         options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingTurn = turnId
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speakingTurn = nil
    }

    /// markdown → 可听文本。块级结构由 parseMarkdownBlocks 给（与渲染同一份真相）。
    static func speakable(_ md: String) -> String {
        parseMarkdownBlocks(md).compactMap { block -> String? in
            switch block {
            case .heading(_, let t):        return t + "。"
            case .paragraph(let t):         return stripInline(t)
            case .quote(let t):             return stripInline(t)
            case .list(let items):          return items.map { stripInline($0.text) }.joined(separator: "；")
            case .table(let header, let rows):
                return "（表格，\(rows.count) 行，维度：\(header.joined(separator: "、"))。详见屏幕。）"
            case .code:                     return nil       // 代码不读
            case .rule:                     return nil
            }
        }
        .joined(separator: "\n")
    }

    /// 去掉行内记号（** ` []()）。只删记号不动内容，听感自然即可，不追求完美。
    private static func stripInline(_ s: String) -> String {
        var t = s
        for mark in ["**", "`", "*"] { t = t.replacingOccurrences(of: mark, with: "") }
        // [标题](url) → 标题
        while let l = t.range(of: "["), let m = t.range(of: "](", range: l.upperBound..<t.endIndex),
              let r = t.range(of: ")", range: m.upperBound..<t.endIndex) {
            let label = String(t[l.upperBound..<m.lowerBound])
            t.replaceSubrange(l.lowerBound..<r.upperBound, with: label)
        }
        return t
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingTurn = nil }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingTurn = nil }
    }
}
