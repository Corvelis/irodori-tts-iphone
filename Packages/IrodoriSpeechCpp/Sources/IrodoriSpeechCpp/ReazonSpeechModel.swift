import Foundation
import IrodoriTTS

/// The published Q4_K bytes match the variant used by the optimized iPhone implementation.
public enum ReazonSpeechModel {
    public static let fileName = "reazonspeech-nemo-619M-v2-Q4_K.gguf"
    public static let bytes: Int64 = 357_216_832
    public static let sha256 = "d761f6b65572a0ec46db04f3f9cc829d25084608bcdcb86bc2aae4b95e4bb4c9"
    public static let revision = "ed04d9ee2cd156414982a7c0f6123c6fd1093904"
    public static let modelURL = URL(string: "https://huggingface.co/sakasegawa/reazonspeech-nemo-v2-GGUF/resolve/\(revision)/\(fileName)")!

    public static func validate(_ file: URL, verifyHash: Bool = false) throws {
        guard (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == bytes else {
            throw IrodoriError.invalid("ReazonSpeech Q4_Kモデルが見つからないか、サイズが一致しません。")
        }
        if verifyHash, try ModelBundle.checksum(file) != sha256 {
            throw IrodoriError.invalid("ReazonSpeech Q4_KのSHA-256が一致しません。")
        }
    }

    public static func download(to file: URL, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        try await ModelFileTransfer.download(from: modelURL, bytes: bytes, sha256: sha256, to: file, progress: progress)
    }

    public static func importFile(_ source: URL, to destination: URL) throws {
        try validate(source, verifyHash: true)
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: temporary) }
        try files.copyItem(at: source, to: temporary)
        try validate(temporary, verifyHash: true)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: temporary, to: destination)
    }
}
