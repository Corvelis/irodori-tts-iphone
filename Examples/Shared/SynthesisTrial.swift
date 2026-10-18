import Foundation
import IrodoriTTS

enum SynthesisBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case coreML, speechCpp
    var id: String { rawValue }
    var title: String { self == .coreML ? "Core ML" : "speech.cpp / Metal" }
    var supportsSynthesis: Bool {
        #if targetEnvironment(simulator)
        return self != .speechCpp
        #else
        return true
        #endif
    }
    static var available: [Self] {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        return [.coreML, .speechCpp]
        #else
        return [.coreML]
        #endif
    }
}

struct SynthesisInput: Sendable {
    let text: String
    let caption: String
    let seed: UInt32
    let reference: URL?
    let coreMLDescription: String
    let coreMLDirectory: URL?
    let speechDirectory: URL
    let watermark: Bool
    let group: UUID
}

/// Results retain file URLs and small summaries, never loaded models or full PCM buffers.
struct SynthesisTrial: Identifiable, Sendable, Codable {
    let backend: SynthesisBackend
    let group: UUID
    var id: String { backend.rawValue }
    var url: URL
    let text: String
    let seed: UInt32
    let watermark: Bool
    let synthesisMilliseconds: Double
    let firstPCMMilliseconds: Double
    let audioSeconds: Double
    let modelLoadMilliseconds: Double
    let referenceMilliseconds: Double
    let loadMemory: MemoryObservation?
    let memory: MemoryObservation?
    let waveform: [Double]
    let device: String
    let modelDescription: String?
    var rtf: Double { synthesisMilliseconds / 1000 / max(audioSeconds, 0.000001) }
}
