import Foundation
import Observation
import Speech
import AVFoundation

// =============================================================================
// 语音输入：按住说话不如「点一下开始、点一下结束」——现场单手场景里长按会误触。
// 转写走系统 SFSpeechRecognizer(zh-CN)，实时回填输入框，**发送仍由人点**：
// 转写会错字，直接自动发送 = 把错字问题发给 agent 再等几十秒，不如让人扫一眼。
// =============================================================================

@MainActor
@Observable
final class VoiceInput {
    var transcript = ""
    var recording = false
    /// 出问题时给人看的一句话（权限被拒 / 识别器不可用 / 音频起不来）。
    /// 不静默吞：语音起不来而界面毫无表示，表现就是「按了没反应」。
    var problem: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if recording { stop() } else { start() }
    }

    func stop() {
        request?.endAudio()
        teardown()
    }

    // MARK: - 私有

    private func start() {
        problem = nil
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { auth in
            Task { @MainActor in
                guard auth == .authorized else {
                    self.problem = "语音识别权限被拒 —— 设置 → 水利助手 里打开"
                    return
                }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in
                        guard ok else {
                            self.problem = "麦克风权限被拒 —— 设置 → 水利助手 里打开"
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            problem = "这台设备上中文语音识别不可用"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
                req.append(buf)
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = req
            self.recording = true
            self.task = recognizer.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    if let r = result { self.transcript = r.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) { self.teardown() }
                }
            }
        } catch {
            problem = "麦克风起不来：\((error as NSError).localizedDescription)"
            teardown()
        }
    }

    private func teardown() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request = nil
        task?.cancel()
        task = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
