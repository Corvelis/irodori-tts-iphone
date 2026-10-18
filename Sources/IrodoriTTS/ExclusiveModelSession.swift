import Foundation

/// Serializes complete operations across different backends, including asynchronous load/release.
/// Actor reentrancy alone does not prevent two models from loading at the same time.
public actor ExclusiveModelSession {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var identifier: String?
    private var unload: (@Sendable () async -> Void)?

    public init() {}

    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func relinquish() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }

    public func withModel<T: Sendable>(identifier next: String,
        load: @Sendable () async throws -> Void,
        release: @escaping @Sendable () async -> Void,
        operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { relinquish() }
        try Task.checkCancellation()
        if identifier != next {
            await unload?()
            identifier = nil; unload = nil
            try Task.checkCancellation()
            do {
                try await load()
                try Task.checkCancellation()
                identifier = next; unload = release
            } catch {
                // A partially loaded native/Metal model also needs explicit cleanup.
                await release()
                throw error
            }
        }
        return try await operation()
    }

    public func release() async {
        await acquire()
        defer { relinquish() }
        await unload?()
        identifier = nil; unload = nil
    }
}
