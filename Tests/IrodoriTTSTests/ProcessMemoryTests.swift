import XCTest
@testable import IrodoriTTS

private final class Readings: @unchecked Sendable {
    let lock = NSLock()
    var values: [Double?]
    init(_ values: [Double?]) { self.values = values }
    func next() -> Double? { lock.lock(); defer { lock.unlock() }; return values.isEmpty ? nil : values.removeFirst() }
}

final class ProcessMemoryTests: XCTestCase {
    func testFailedReadingsAreMissingAndPeakResetsBetweenOperations() {
        let first = Readings([700, 900])
        let sampler = ProcessMemorySampler(intervalMilliseconds: 60_000, reader: { first.next() })
        let observation = sampler.finish()
        XCTAssertEqual(observation.startMiB, 700); XCTAssertEqual(observation.endMiB, 900)
        XCTAssertEqual(observation.peakMiB, 900); XCTAssertEqual(observation.sampleCount, 2)
        XCTAssertEqual(sampler.finish().sampleCount, 2)
        let second = Readings([nil, 300])
        let next = ProcessMemorySampler(intervalMilliseconds: 60_000, reader: { second.next() }).finish()
        XCTAssertNil(next.startMiB); XCTAssertEqual(next.peakMiB, 300); XCTAssertEqual(next.readErrorCount, 1)
        let unavailable = ProcessMemorySampler(intervalMilliseconds: 60_000, reader: { .nan }).finish()
        XCTAssertNil(unavailable.peakMiB); XCTAssertNil(unavailable.endMiB)
    }

    func testProcessReportsPhysicalFootprint() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ProcessMemory.currentMiB()), 0)
    }

    func testVerifiedDownloadedFileCanBeReusedWithoutNetwork() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        try await ModelFileTransfer.download(from: URL(string: "https://invalid.example/model")!, bytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", to: url)
        XCTAssertEqual(try String(contentsOf: url), "abc")
    }
}
