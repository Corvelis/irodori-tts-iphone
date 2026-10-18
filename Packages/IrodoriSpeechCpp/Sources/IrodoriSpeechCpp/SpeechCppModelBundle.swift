import Foundation
import IrodoriTTS

public enum SpeechCppModelBundle {
    public static let fileName = "Irodori-TTS-866M-MF-v4.1-F16.gguf"
    public static let bytes: Int64 = 1_920_321_792
    public static let sha256 = "e237dc3eefe469b8bba87872beacf12fb7fe00dbdf85767edca8ec04ab910d13"
    public static let modelURL = URL(string: "https://huggingface.co/sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF/resolve/69d307a472a1708c5637edcfe376d31c2685829d/\(fileName)")!
    public static let watermarkManifest = ModelVariant.standard.manifestURL

    private struct File: Codable { let path: String; let bytes: Int64; let sha256: String }
    private struct Manifest: Codable { let format: String; let files: [File] }
    private static let watermarkPaths: Set<String> = Set(["audioseal.json"] + ["audioseal_generator", "audioseal_detector"].flatMap { name in
        ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map { "\(name).mlpackage/\($0)" }
    })

    public static func isInstalled(at root: URL) -> Bool { (try? validate(at: root)) != nil }

    public static func validate(at root: URL, verifyHashes: Bool = false) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: ModelBundle.safeURL("speech-cpp-manifest.json", under: root)))
        guard manifest.format == "irodori-speech-cpp-v1", manifest.files.count == watermarkPaths.count + 1,
              Set(manifest.files.map(\.path)) == watermarkPaths.union([fileName]),
              manifest.files.first(where: { $0.path == fileName }).map({ $0.bytes == bytes && $0.sha256 == sha256 }) == true else {
            throw IrodoriError.invalid("Invalid speech.cpp model manifest")
        }
        for entry in manifest.files {
            let file = try ModelBundle.safeURL(entry.path, under: root)
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard entry.bytes > 0, entry.sha256.count == 64, size?.int64Value == entry.bytes else {
                throw IrodoriError.invalid("Missing or invalid speech.cpp model: \(entry.path)")
            }
            if verifyHashes, try ModelBundle.checksum(file) != entry.sha256 {
                throw IrodoriError.invalid("Model checksum mismatch: \(entry.path)")
            }
        }
    }

    /// Only the GGUF and AudioSeal components are fetched; the Core ML TTS weights are not needed.
    /// A supplied local GGUF is verified and copied, while the small AudioSeal bundle is downloaded.
    public static func download(to destination: URL, importingGGUF: URL? = nil,
                                progress: @escaping @Sendable (Int64, Int64, String) -> Void = { _, _, _ in }) async throws {
        let (data, response) = try await URLSession.shared.data(from: watermarkManifest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IrodoriError.invalid("AudioSeal manifest download failed") }
        let sourceManifest = try ModelBundle.manifest(from: data)
        let markers = sourceManifest.files.filter { watermarkPaths.contains($0.path) }
        guard Set(markers.map(\.path)) == watermarkPaths else { throw IrodoriError.invalid("Incomplete AudioSeal manifest") }
        let entries = [File(path: fileName, bytes: bytes, sha256: sha256)] + markers.map { File(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) }
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            try validate(at: destination, verifyHashes: true)
            progress(entries.reduce(0) { $0 + $1.bytes }, entries.reduce(0) { $0 + $1.bytes }, "Complete")
            return
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for entry in entries {
            try Task.checkCancellation()
            let target = try ModelBundle.safeURL(entry.path, under: staging)
            if entry.path == fileName, let importingGGUF {
                guard (try files.attributesOfItem(atPath: importingGGUF.path)[.size] as? NSNumber)?.int64Value == bytes,
                      try ModelBundle.checksum(importingGGUF) == sha256 else { throw IrodoriError.invalid("Irodori v4.1 Small MF F16 GGUF checksum mismatch") }
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.copyItem(at: importingGGUF, to: target)
            } else {
                let base = completed
                let url = entry.path == fileName ? modelURL : watermarkManifest.deletingLastPathComponent().appendingPathComponent(entry.path)
                try await ModelFileTransfer.download(from: url, bytes: entry.bytes, sha256: entry.sha256, to: target) {
                    progress(base + min($0, entry.bytes), total, entry.path)
                }
            }
            completed += entry.bytes
            progress(completed, total, entry.path)
        }
        try JSONEncoder().encode(Manifest(format: "irodori-speech-cpp-v1", files: entries))
            .write(to: staging.appendingPathComponent("speech-cpp-manifest.json"), options: .atomic)
        try validate(at: staging, verifyHashes: true)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: destination)
    }
}
