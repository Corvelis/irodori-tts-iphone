import XCTest
@testable import IrodoriTTS

private actor ResidentModels {
    var current = Set<String>()
    var maximum = 0
    var loads = 0
    func load(_ name: String) async {
        try? await Task.sleep(nanoseconds: 3_000_000)
        current.insert(name); maximum = max(maximum, current.count); loads += 1
    }
    func release(_ name: String) async {
        try? await Task.sleep(nanoseconds: 3_000_000)
        current.remove(name)
    }
    func observation() -> (Int, Int, Int) { (current.count, maximum, loads) }
}

final class ModelResidencyTests: XCTestCase {
    func testConcurrentBackendSwitchesNeverOverlapAndReuseSameModel() async throws {
        let session = ExclusiveModelSession(), models = ResidentModels()
        // Await points in release and load make an actor-only implementation overlap.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                let name = ["CoreML", "speech.cpp TTS", "ReazonSpeech"][index % 3]
                group.addTask {
                    try await session.withModel(identifier: name, load: { await models.load(name) },
                        release: { await models.release(name) }, operation: { try await Task.sleep(nanoseconds: 1_000_000) })
                }
            }
            try await group.waitForAll()
        }
        await session.release()
        let state = await models.observation()
        XCTAssertEqual(state.0, 0); XCTAssertEqual(state.1, 1)
        for _ in 0..<3 {
            try await session.withModel(identifier: "same", load: { await models.load("same") },
                release: { await models.release("same") }, operation: {})
        }
        let reused = await models.observation()
        XCTAssertEqual(reused.2, state.2 + 1)
        await session.release()
    }

    func testFailedLoadReleasesPartialModelBeforeNextRequest() async throws {
        let session = ExclusiveModelSession(), models = ResidentModels()
        do {
            try await session.withModel(identifier: "bad", load: {
                await models.load("bad"); throw IrodoriError.invalid("load failure")
            }, release: { await models.release("bad") }, operation: {})
            XCTFail("Expected load failure")
        } catch { }
        try await session.withModel(identifier: "good", load: { await models.load("good") },
            release: { await models.release("good") }, operation: {})
        await session.release()
        let state = await models.observation()
        XCTAssertEqual(state.0, 0); XCTAssertEqual(state.1, 1)
    }
}
