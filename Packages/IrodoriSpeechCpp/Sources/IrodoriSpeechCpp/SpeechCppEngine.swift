import Foundation
import CryptoKit
import IrodoriTTS
import IrodoriSpeechNative

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
}

/// Optional iPhone backend. Explicit Metal execution; models stay loaded until release().
public final class SpeechCppEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IrodoriSpeechCpp.inference", qos: .userInitiated)
    private let native = IrodoriSpeechBridge()
    private var directory: URL?
    private var referenceDigest: String?
    private var processor: AudioWatermarkProcessor?
    private var information: [String: String] = [:]
    public init() {}

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            // Completion means the autorelease pool has also drained.
            let outcome: Result<T, Error> = autoreleasepool { Result { try body() } }
            continuation.resume(with: outcome)
        }}
    }

    @discardableResult public func prepare(modelDirectory: URL) async throws -> Double {
        #if targetEnvironment(simulator)
        throw IrodoriError.invalid("speech.cppの音声生成は実機iPhoneで実行してください。Simulatorでは画面の確認ができます。")
        #else
        try await perform {
            let root = modelDirectory.standardizedFileURL
            if self.directory == root { return 0 }
            self.native.releaseModel(); self.processor = nil; self.directory = nil; self.referenceDigest = nil
            try SpeechCppModelBundle.validate(at: root)
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let info = try self.native.prepareModel(root.appendingPathComponent(SpeechCppModelBundle.fileName).path, metal4: true)
                self.information = info.compactMapValues { $0 as? String }
                self.processor = try AudioWatermarkProcessor(modelDirectory: root)
                self.directory = root
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            } catch {
                self.native.releaseModel(); self.processor = nil
                throw error
            }
        }
        #endif
    }

    @discardableResult public func registerReference(_ url: URL?) async throws -> ReferenceRegistration {
        try await perform {
            guard self.directory != nil else { throw IrodoriError.invalid("Prepare a model first") }
            let start = ProcessInfo.processInfo.systemUptime
            let data = try url.map(ReferenceAudio.read) ?? Data()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let hit = self.referenceDigest == digest
            if !hit {
                if data.isEmpty { try self.native.registerReference(nil) }
                else {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("irodori-reference-\(UUID().uuidString).wav")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    var invalid = false
                    var pcm = Data(count: data.count / 2)
                    data.withUnsafeBytes { source in pcm.withUnsafeMutableBytes { output in
                        for index in 0..<(data.count / 4) {
                            let sample = source.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
                            guard sample.isFinite else { invalid = true; break }
                            let value = Int16(max(-32768, min(32767, (Double(sample) * 32768).rounded())))
                            output.storeBytes(of: value.littleEndian, toByteOffset: index * 2, as: Int16.self)
                        }
                    }}
                    guard !invalid else { throw IrodoriError.invalid("Reference audio contains non-finite samples") }
                    try ReferenceAudio.writeWAV(pcm16: pcm, to: temporary)
                    try self.native.registerReference(temporary.path)
                }
                self.referenceDigest = digest
            }
            return ReferenceRegistration(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, cacheHit: hit)
        }
    }

    public func synthesize(_ text: String, caption: String = "", seed: UInt32? = nil,
                           watermark: WatermarkOptions? = WatermarkOptions(),
                           onChunk: (@Sendable (PCMChunk) -> Void)? = nil) async throws -> SynthesisResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await self.perform {
                self.native.resetCancellation()
                try cancellation.check()
                guard self.directory != nil else { throw IrodoriError.invalid("Prepare a model first") }
                let prepared = SpeechText.prepare(text)
                guard !prepared.isEmpty else { throw IrodoriError.invalid("No speakable text") }
                let memory = ProcessMemorySampler()
                defer { _ = memory.finish() }
                let start = ProcessInfo.processInfo.systemUptime
                let stream = watermark.map { self.processor!.stream(options: $0) }
                var first = -1.0, sequence = 0
                var callbackError: Error?
                let emit: (Data) -> Void = { bytes in
                    if first < 0 { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                    onChunk?(PCMChunk(pcm16: bytes, sequence: sequence)); sequence += 1
                }
                let output: [String: Any]
                do {
                    output = try self.native.synthesize(prepared, caption: caption, seed: seed ?? UInt32.random(in: .min ... .max), onPcm: { bytes in
                        do {
                            try cancellation.check()
                            if let stream { try stream.append(bytes, onPCM: emit) } else { emit(bytes) }
                        } catch { callbackError = error; self.native.cancel() }
                    })
                } catch {
                    if let callbackError { throw callbackError }
                    try cancellation.check()
                    throw error
                }
                if let callbackError { throw callbackError }
                try cancellation.check()
                guard let original = output["pcm16"] as? Data else { throw IrodoriError.invalid("No audio returned") }
                if let stream { try stream.append(Data(), finish: true, onPCM: emit) }
                try cancellation.check()
                return SynthesisResult(pcm16: stream?.pcm16 ?? original, preparedText: prepared,
                    synthesisMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    firstPCMMilliseconds: first,
                    metrics: [(output["metrics"] as? [String: Double]) ?? [:]], diagnostics: [self.information],
                    watermark: stream?.watermark, memory: memory.finish())
            }
        }, onCancel: { cancellation.cancel(); self.native.cancel() })
    }

    public func release() async {
        _ = try? await perform {
            self.native.releaseModel(); self.processor = nil; self.directory = nil; self.referenceDigest = nil
        }
    }
}
