import Foundation

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission = 0.0
    let expectedBytes: Int64
    let progress: @Sendable (Int64) -> Void
    init(bytes: Int64, _ progress: @escaping @Sendable (Int64) -> Void) { expectedBytes = bytes; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes { downloadTask.cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let emit = now - lastEmission >= 0.1 || totalBytesWritten == expectedBytes
        if emit { lastEmission = now }
        lock.unlock()
        if emit { progress(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Download large weights to a file, then hash in bounded chunks; never buffer an entire model in RAM.
public enum ModelFileTransfer {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration)
    }()
    public static func download(from source: URL, bytes: Int64, sha256: String, to destination: URL,
                                progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        guard source.scheme == "https", bytes > 0, sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw IrodoriError.invalid("Invalid model download descriptor")
        }
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? files.attributesOfItem(atPath: destination.path)[.size] as? NSNumber,
           size.int64Value == bytes, (try? ModelBundle.checksum(destination)) == sha256 {
            progress(bytes); return
        }
        if let capacity = try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity < bytes {
            throw IrodoriError.invalid("モデルを保存する空き容量が不足しています。必要容量：\(String(format: "%.2f", Double(bytes)/1e9)) GB")
        }
        let delegate = DownloadProgress(bytes: bytes, progress)
        let (temporary, response) = try await session.download(from: source, delegate: delegate)
        defer { try? files.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try files.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == bytes,
              try ModelBundle.checksum(temporary) == sha256 else {
            throw IrodoriError.invalid("Downloaded file failed verification: \(destination.lastPathComponent)")
        }
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: temporary, to: destination)
        progress(bytes)
    }
}
