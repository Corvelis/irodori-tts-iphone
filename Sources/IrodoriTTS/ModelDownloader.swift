import Foundation
import CryptoKit

/// Downloads to disk, retaining completed verified files for a subsequent retry.
/// Prefer an immutable commit SHA or a versioned release tag over a moving main branch.
public actor ModelDownloader {
    public init() {}

    public func download(manifestURL: URL, to destination: URL,
                         progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in },
                         byteProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        guard manifestURL.scheme == "https" else { throw IrodoriError.invalid("Use an HTTPS manifest URL") }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw IrodoriError.invalid("Destination already exists. Select a new folder or verify the existing model.")
        }
        // Distinct manifests must not share a staging directory during retries.
        let key = SHA256.hash(data: Data(manifestURL.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-\(key).partial")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IrodoriError.invalid("Manifest download failed") }
        let manifest = try ModelBundle.manifest(from: data)
        if manifest.format == "irodori-coreml-distribution-v2" {
            if #available(iOS 18, macOS 15, *) {} else {
                throw IrodoriError.invalid("This model requires iOS 18 or macOS 15")
            }
        }
        let base = manifestURL.deletingLastPathComponent()
        let total = try manifest.files.reduce(Int64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.bytes)
            guard !overflow else { throw IrodoriError.invalid("Model size overflow") }
            return sum
        }
        var completed: Int64 = 0
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let target = try ModelBundle.safeURL(entry.path, under: staging)
            progress(index, manifest.files.count, entry.path)
            let baseBytes = completed
            try await ModelFileTransfer.download(from: base.appendingPathComponent(entry.path),
                bytes: entry.bytes, sha256: entry.sha256, to: target) { received in
                byteProgress(baseBytes + min(received, entry.bytes), total)
            }
            completed += entry.bytes
        }
        try Task.checkCancellation()
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try ModelBundle.validate(at: staging)
        try files.moveItem(at: staging, to: destination)
        progress(manifest.files.count, manifest.files.count, "Complete")
    }
}
