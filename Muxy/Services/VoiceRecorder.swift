import AVFoundation
import Foundation
import os
import Speech

private let logger = Logger(subsystem: "app.muxy", category: "VoiceRecorder")

enum VoiceRecorderError: Error {
    case recognizerUnavailable
    case engineFailure(String)
}

@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var transcript: String = ""

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let activeRequest = ActiveRequestHolder()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var accumulatedBeforePause: TimeInterval = 0
    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var levelSink: LevelSink?
    @ObservationIgnored private var transcriptSink: TranscriptSink?
    @ObservationIgnored private var committedTranscript: String = ""
    @ObservationIgnored private var currentSegment: String = ""
    @ObservationIgnored private var segmentSequence: Int = 0

    func start(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable
        else {
            throw VoiceRecorderError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceRecorderError.engineFailure(
                "On-device speech recognition is unavailable for this language. Open Settings → Recording to pick another."
            )
        }
        self.recognizer = recognizer
        recognizer.defaultTaskHint = .dictation

        let levelSink = LevelSink { [weak self] normalized in
            guard let self else { return }
            self.level = normalized
        }
        self.levelSink = levelSink
        let requestHolder = activeRequest
        Self.installTapNonisolated(on: engine.inputNode, sink: levelSink) { buffer in
            requestHolder.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            levelSink.detach()
            self.levelSink = nil
            self.recognizer = nil
            throw VoiceRecorderError.engineFailure(error.localizedDescription)
        }

        let transcriptSink = TranscriptSink { [weak self] segmentId, text, isFinal in
            guard let self, segmentId == self.segmentSequence else { return }
            self.applyPartial(text)
            if isFinal {
                self.handleSegmentEnded(segmentId: segmentId)
            }
        }
        self.transcriptSink = transcriptSink

        startedAt = Date()
        accumulatedBeforePause = 0
        elapsed = 0
        level = 0
        transcript = ""
        committedTranscript = ""
        currentSegment = ""
        segmentSequence = 0
        isRecording = true
        isPaused = false
        startElapsedTimer()
        startRecognitionSegment()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        engine.pause()
        if let startedAt {
            accumulatedBeforePause += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        isPaused = true
        level = 0
        stopElapsedTimer()
        commitCurrentSegment()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        do {
            try engine.start()
        } catch {
            logger.error("Failed to resume engine: \(error.localizedDescription)")
            return
        }
        startedAt = Date()
        isPaused = false
        startElapsedTimer()
        startRecognitionSegment()
    }

    func finish() -> String {
        commitCurrentSegment()
        let final = transcript
        teardown()
        return final
    }

    private func commitCurrentSegment() {
        activeRequest.take()?.endAudio()
        task?.finish()
        committedTranscript = Self.merge(committed: committedTranscript, segment: currentSegment)
        transcript = committedTranscript
        currentSegment = ""
        segmentSequence &+= 1
        task = nil
    }

    func cancel() {
        teardown()
    }

    nonisolated static func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard mic else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated static func currentPermissionStatus() -> Bool {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        return mic && speech
    }

    private func teardown() {
        stopElapsedTimer()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        activeRequest.take()?.endAudio()
        task?.cancel()
        levelSink?.detach()
        levelSink = nil
        transcriptSink?.detach()
        transcriptSink = nil
        task = nil
        recognizer = nil
        startedAt = nil
        accumulatedBeforePause = 0
        committedTranscript = ""
        currentSegment = ""
        isRecording = false
        isPaused = false
        level = 0
    }

    private func startRecognitionSegment() {
        guard let recognizer, let transcriptSink, isRecording else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        activeRequest.set(request)
        currentSegment = ""
        let segmentId = segmentSequence

        task = Self.startRecognitionTaskNonisolated(
            recognizer: recognizer,
            request: request,
            sink: transcriptSink,
            segmentId: segmentId,
            onError: { [weak self] in
                Task { @MainActor in self?.handleSegmentEnded(segmentId: segmentId) }
            }
        )
    }

    private func handleSegmentEnded(segmentId: Int) {
        guard isRecording, segmentId == segmentSequence else { return }
        committedTranscript = Self.merge(committed: committedTranscript, segment: currentSegment)
        transcript = committedTranscript
        currentSegment = ""
        segmentSequence &+= 1
        task = nil
        _ = activeRequest.take()
        guard !isPaused else { return }
        startRecognitionSegment()
    }

    private func applyPartial(_ text: String) {
        if !currentSegment.isEmpty, !Self.isContinuation(previous: currentSegment, next: text) {
            committedTranscript = Self.merge(committed: committedTranscript, segment: currentSegment)
        }
        currentSegment = text
        transcript = Self.merge(committed: committedTranscript, segment: text)
    }

    nonisolated static func isContinuation(previous: String, next: String) -> Bool {
        if next.hasPrefix(previous) { return true }
        if previous.hasPrefix(next) { return true }
        return false
    }

    nonisolated static func merge(committed: String, segment: String) -> String {
        if committed.isEmpty { return segment }
        if segment.isEmpty { return committed }
        return committed + " " + segment
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = accumulatedBeforePause + Date().timeIntervalSince(startedAt)
    }

    nonisolated static func averagePower(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return -160 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }
        var sum: Float = 0
        for i in 0 ..< frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        guard rms > 0 else { return -160 }
        return 20 * log10(rms)
    }

    nonisolated static func startRecognitionTaskNonisolated(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        sink: TranscriptSink,
        segmentId: Int,
        onError: @escaping @Sendable () -> Void
    ) -> SFSpeechRecognitionTask {
        let endedBox = UncheckedBox(EndOnceFlag())
        let handler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
            if let result {
                sink.publish(
                    segmentId: segmentId,
                    value: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )
            }
            guard error != nil else { return }
            guard endedBox.value.markEnded() else { return }
            onError()
        }
        return recognizer.recognitionTask(with: request, resultHandler: handler)
    }

    nonisolated static func installTapNonisolated(
        on inputNode: AVAudioInputNode,
        sink: LevelSink,
        forward: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        inputNode.removeTap(onBus: 0)
        let block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            forward(buffer)
            let normalized = normalize(power: averagePower(in: buffer))
            sink.publish(normalized)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: block)
    }

    nonisolated static func normalize(power db: Float) -> Float {
        let floor: Float = -50
        guard db.isFinite else { return 0 }
        let clamped = max(min(db, 0), floor)
        return (clamped - floor) / -floor
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

final class ActiveRequestHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func take() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let value = request
        request = nil
        lock.unlock()
        return value
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let value = request
        lock.unlock()
        value?.append(buffer)
    }
}

final class EndOnceFlag {
    private let lock = NSLock()
    private var ended = false

    func markEnded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return false }
        ended = true
        return true
    }
}

final class TranscriptSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor (Int, String, Bool) -> Void)?

    init(handler: @escaping @MainActor (Int, String, Bool) -> Void) {
        self.handler = handler
    }

    func publish(segmentId: Int, value: String, isFinal: Bool) {
        lock.lock()
        let current = handler
        lock.unlock()
        guard let current else { return }
        Task { @MainActor in
            current(segmentId, value, isFinal)
        }
    }

    func detach() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}

final class LevelSink: @unchecked Sendable {
    private static let minInterval: TimeInterval = 1.0 / 15.0

    private let lock = NSLock()
    private var handler: (@MainActor (Float) -> Void)?
    private var lastPublishedAt: TimeInterval = 0

    init(handler: @escaping @MainActor (Float) -> Void) {
        self.handler = handler
    }

    func publish(_ value: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard let current = handler, now - lastPublishedAt >= Self.minInterval else {
            lock.unlock()
            return
        }
        lastPublishedAt = now
        lock.unlock()
        Task { @MainActor in
            current(value)
        }
    }

    func detach() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}
