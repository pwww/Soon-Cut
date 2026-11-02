import Foundation
import ScreenCaptureKit
import CoreMedia

enum RecorderError: LocalizedError {
    case displayNotFound
    case notRecording

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return String(localized: "找不到框選範圍所在的螢幕，請重新框選。")
        case .notRecording: return String(localized: "目前沒有在錄影。")
        }
    }
}

/// 用 ScreenCaptureKit + SCRecordingOutput（macOS 15）把框選範圍直接錄成 MP4，含系統聲音。
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let sampleQueue = DispatchQueue(label: "cc.aicolab.sooncut.samples")
    private let lock = NSLock()
    private var finishContinuation: CheckedContinuation<Void, Error>?

    /// - Parameters:
    ///   - sourceRect: 相對於螢幕、左上原點、單位 point
    func start(displayID: CGDirectDisplayID,
               sourceRect: CGRect,
               captureAudio: Bool,
               captureMicrophone: Bool,
               microphoneID: String?,
               outputURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.displayNotFound
        }
        // 排除自己的所有視窗（浮動視窗、紅框）
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var w = sourceRect.width * scale
        var h = sourceRect.height * scale
        let longEdge = max(w, h)
        if longEdge > 1920 {          // 社群用，長邊最多 1920px
            let k = 1920 / longEdge
            w *= k
            h *= k
        }
        config.width = max(2, Int(w / 2) * 2)   // H.264 需要偶數
        config.height = max(2, Int(h / 2) * 2)
        config.sourceRect = sourceRect
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = captureAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 麥克風（macOS 15）：跟系統聲音各自獨立開關；nil = 系統預設麥克風
        config.captureMicrophone = captureMicrophone
        if captureMicrophone, let microphoneID {
            config.microphoneCaptureDeviceID = microphoneID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = outputURL
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recConfig, delegate: self)
        try stream.addRecordingOutput(output)

        try await stream.startCapture()
        self.stream = stream
        self.recordingOutput = output
    }

    /// 停止並等到檔案寫完
    func stop() async throws {
        guard let stream else { throw RecorderError.notRecording }
        defer {
            self.stream = nil
            self.recordingOutput = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            finishContinuation = continuation
            lock.unlock()
            stream.stopCapture { [weak self] error in
                if let error { self?.resumeFinish(.failure(error)) }
            }
            // 保險：3 秒內沒收到完成通知也結束等待
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.resumeFinish(.success(()))
            }
        }
    }

    private func resumeFinish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = finishContinuation
        finishContinuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    // MARK: SCStreamOutput（樣本由 SCRecordingOutput 寫檔，這裡不處理）
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        resumeFinish(.failure(error))
    }

    // MARK: SCRecordingOutputDelegate
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resumeFinish(.success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resumeFinish(.failure(error))
    }
}
