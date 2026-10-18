import Foundation
import IrodoriTTS
import IrodoriSpeechNative

public enum RecognitionDecoding: String, CaseIterable, Codable, Sendable, Identifiable {
    case beam, greedy
    public var id: String { rawValue }
}

public struct RecognitionResult: Sendable {
    public let text: String
    public let decoding: RecognitionDecoding
    public let audioSeconds: Double
    public let conversionMilliseconds: Double
    public let inferenceMilliseconds: Double
    public let memory: MemoryObservation
    public let device: String
    public let decodeOnCPU: Bool
    public var rtf: Double { inferenceMilliseconds / 1000 / audioSeconds }
}

private final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
}

/// ReazonSpeech Q4_K on Metal. Decoding-mode changes reuse the same resident model.
public final class SpeechRecognitionEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IrodoriSpeechCpp.recognition", qos: .userInitiated)
    private let native = ReazonSpeechBridge()
    private let preferGpuGreedy: Bool
    private var path: URL?
    public init(preferGpuGreedy: Bool = false) { self.preferGpuGreedy = preferGpuGreedy }

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            let outcome: Result<T, Error> = autoreleasepool { Result { try body() } }
            continuation.resume(with: outcome)
        }}
    }

    @discardableResult public func prepare(modelFile: URL) async throws -> Double {
        #if targetEnvironment(simulator)
        throw IrodoriError.invalid("speech.cppの音声認識は実機iPhoneで実行してください。")
        #else
        return try await perform {
            let file = modelFile.standardizedFileURL
            if self.path == file { return 0 }
            self.native.releaseModel(); self.path = nil
            try ReazonSpeechModel.validate(file)
            let info = try self.native.prepareModel(file.path, preferGpuGreedy: self.preferGpuGreedy)
            self.path = file
            return (info["loadMs"] as? NSNumber)?.doubleValue ?? 0
        }
        #endif
    }

    public func transcribe(_ audioFile: URL, decoding: RecognitionDecoding = .beam) async throws -> RecognitionResult {
        let cancellation = RecognitionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await self.perform {
                self.native.resetCancellation()
                try cancellation.check()
                guard self.path != nil else { throw IrodoriError.invalid("先に音声認識モデルを準備してください。") }
                let start = ProcessInfo.processInfo.systemUptime
                let pcm = try RecognitionAudio.read(audioFile)
                let conversion = (ProcessInfo.processInfo.systemUptime - start) * 1000
                try cancellation.check()
                let memory = ProcessMemorySampler()
                defer { _ = memory.finish() }
                let result: [String: Any]
                do { result = try self.native.transcribe(pcm, decoding: decoding.rawValue) }
                catch { try cancellation.check(); throw error }
                try cancellation.check()
                guard let text = result["text"] as? String, let elapsed = result["inferenceMs"] as? NSNumber else {
                    throw IrodoriError.invalid("音声認識の結果を取得できません。")
                }
                return RecognitionResult(text: text, decoding: decoding, audioSeconds: Double(pcm.count) / 32_000,
                    conversionMilliseconds: conversion, inferenceMilliseconds: elapsed.doubleValue, memory: memory.finish(),
                    device: result["metalKernel"] as? String ?? "Metal", decodeOnCPU: (result["decodeOnCpu"] as? NSNumber)?.boolValue ?? false)
            }
        }, onCancel: { cancellation.cancel(); self.native.cancel() })
    }

    public func release() async {
        _ = try? await perform { self.native.releaseModel(); self.path = nil }
    }
}
