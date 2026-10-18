#if IRODORI_SAMPLE_DIAGNOSTICS
import Foundation
import SwiftUI
import IrodoriTTS
#if os(iOS) && canImport(IrodoriSpeechCpp)
import IrodoriSpeechCpp
#endif

@MainActor extension SampleModel {
    // Explicit developer launch only. Exercises the same download/generate/replay actions as the UI.
    // Models, input audio and reports stay in the app container and are never bundled in source exports.
    func runDeviceSmokeIfRequested() async {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        if ProcessInfo.processInfo.arguments.contains("--irodori-recognition-preview") {
            showingRecognition = true
            return
        }
        #endif
        guard ProcessInfo.processInfo.arguments.contains("--irodori-comparison-smoke"), !didRunDeviceSmoke else { return }
        didRunDeviceSmoke = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let reportURL = documents.appendingPathComponent("comparison-smoke-result.json")
        var report: [String: Any] = ["status": "running", "startedAt": ISO8601DateFormatter().string(from: Date())]
        func write(_ phase: String) {
            report["phase"] = phase; report["currentMiB"] = ProcessMemory.currentMiB()
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: reportURL, options: .atomic)
            }
            print("IRODORI_COMPARISON_SMOKE: \(phase)")
        }
        func completedWork() async throws { try await self.waitForCurrentOperation() }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        do {
            let configURL = documents.appendingPathComponent("comparison-smoke-config.json")
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] ?? [:]
            try? FileManager.default.removeItem(at: configURL)
            report["runId"] = config["runId"]
            text = config["text"] as? String ?? "こんにちは。今日はいい天気ですね。"
            caption = config["caption"] as? String ?? ""
            seed = "12345"; watermarkEnabled = config["watermark"] as? Bool ?? true
            write("starting")
            #if os(iOS) && canImport(IrodoriSpeechCpp)
            if config["verifyRecognition"] as? Bool == true {
                report["recognition"] = try await verifyRecognition(config, documents: documents)
                report["status"] = "complete"; write("complete")
                return
            }
            #endif
            if config["verifySavedOnly"] as? Bool == true {
                guard savedTrials.count == 2, residentDescription == "未ロード" else { throw IrodoriError.invalid("Saved results were not restored") }
                for trial in savedTrials {
                    replay(trial)
                    guard isPlaying, residentDescription == "未ロード" else { throw IrodoriError.invalid("Replay unexpectedly loaded a model") }
                    stop()
                }
                report["restoredTrials"] = savedTrials.count
                report["replayWithoutModel"] = true
                report["status"] = "complete"; write("complete")
                return
            }
            if let relative = config["coreMLDirectory"] as? String {
                let source = try ModelBundle.safeURL(relative, under: documents)
                selectModel(source.path); try await completedWork()
            } else if config["downloadCoreML"] as? Bool == true {
                downloadVariant = .lightINT8; downloadSelectedVariant()
                write("downloading-coreml"); try await completedWork()
            }
            if config["downloadSpeech"] as? Bool == true {
                downloadSpeechModel(); write("downloading-speech-cpp"); try await completedWork()
            }
            guard speechInstalled, canCompare || config["verifyReleaseOnly"] as? Bool == true else {
                throw IrodoriError.invalid("Required models must be installed for smoke verification")
            }
            if let relative = config["reference"] as? String {
                let source = try ModelBundle.safeURL(relative, under: documents)
                consent = true; importReference(source); try await completedWork()
            }
            if config["verifyReleaseOnly"] as? Bool == true {
                selectBackend(.speechCpp); try await completedWork()
                speak(); try await completedWork(); stop()
                speak(); try await completedWork(); stop()
                report["reuseRtf"] = result?.rtf
                report["reuseLoadMs"] = result?.modelLoadMilliseconds
                report["loadedMiB"] = ProcessMemory.currentMiB()
                unloadModels(); try await completedWork()
                report["releasedMiB"] = releaseAfterMiB
                try await Task.sleep(nanoseconds: 500_000_000)
                report["releasedSettledMiB"] = ProcessMemory.currentMiB()
                report["status"] = "complete"; write("complete")
                return
            }
            write("generating-comparison")
            compare(); try await completedWork()
            guard savedTrials.count == 2 else { throw IrodoriError.invalid("Both comparison outputs are required") }
            report["comparison"] = try savedTrials.map { trial -> [String: Any] in
                var row: [String: Any] = ["backend": trial.backend.rawValue, "device": trial.device,
                    "synthesisMs": trial.synthesisMilliseconds, "firstPcmMs": trial.firstPCMMilliseconds,
                    "rtf": trial.rtf, "audioSeconds": trial.audioSeconds, "seed": trial.seed,
                    "watermark": trial.watermark, "modelLoadMs": trial.modelLoadMilliseconds,
                    "referenceMs": trial.referenceMilliseconds,
                    "wavBytes": (try FileManager.default.attributesOfItem(atPath: trial.url.path)[.size]) ?? 0]
                if let memory = trial.memory { row["memory"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) }
                if let memory = trial.loadMemory { row["loadMemory"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) }
                return row
            }
            stop()
            let replayResidentBefore = residentDescription
            replayCurrent()
            report["replayStarted"] = isPlaying
            report["replayResidentUnchanged"] = residentDescription == replayResidentBefore
            stop()
            selectBackend(.speechCpp); try await completedWork()
            write("checking-model-reuse")
            speak(); try await completedWork(); stop()
            speak(); try await completedWork(); stop()
            guard let last = result, last.modelLoadMilliseconds == 0 else { throw IrodoriError.invalid("Model was unexpectedly reloaded") }
            report["reuseLoadMs"] = last.modelLoadMilliseconds
            report["reuseRtf"] = last.rtf
            let previousGroup = last.group
            write("checking-cancellation")
            speak()
            try await Task.sleep(nanoseconds: 80_000_000)
            stop(); try await completedWork()
            guard errorMessage == nil, result?.group == previousGroup, residentDescription == "未ロード" else {
                throw IrodoriError.invalid("Cancelled generation left a result or model resident")
            }
            report["cancelledGenerationDiscarded"] = true
            unloadModels(); try await completedWork()
            report["releasedMiB"] = releaseAfterMiB
            try await Task.sleep(nanoseconds: 500_000_000)
            report["releasedSettledMiB"] = ProcessMemory.currentMiB()
            report["residentAfterRelease"] = residentDescription
            report["status"] = "complete"; write("complete")
            status = "実機検証が完了しました。保存済み音声を試聴できます。"
        } catch {
            unloadModels(); try? await waitForCurrentOperation()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            write("failed"); self.report(error)
        }
    }

}

#if os(iOS) && canImport(IrodoriSpeechCpp)
@MainActor private extension SampleModel {
    func verifyRecognition(_ config: [String: Any], documents: URL) async throws -> [String: Any] {
        openRecognition(); try await waitForCurrentOperation()
        if config["downloadRecognition"] as? Bool == true {
            downloadRecognitionModel(); try await waitForCurrentOperation()
        }
        guard recognitionInstalled, let inputs = config["recognitionFiles"] as? [String], !inputs.isEmpty else {
            throw IrodoriError.invalid("Recognition model and audio fixtures are required")
        }
        let savedCount = savedTrials.count
        var rows = [[String: Any]]()
        for path in inputs {
            importRecognitionAudio(try ModelBundle.safeURL(path, under: documents))
            try await waitForCurrentOperation()
            var beam: String?
            for mode in [RecognitionDecoding.beam, .greedy, .beam] {
                recognitionDecoding = mode
                recognizeInput(); try await waitForCurrentOperation()
                guard let trial = recognitionTrial, !trial.result.text.isEmpty else { throw IrodoriError.invalid("No transcript returned") }
                if !rows.isEmpty && trial.loadMilliseconds != 0 { throw IrodoriError.invalid("Recognition model unexpectedly reloaded") }
                if mode == .beam {
                    if let beam, beam != trial.result.text { throw IrodoriError.invalid("Repeated beam transcript changed") }
                    beam = trial.result.text
                }
                rows.append(["input": path, "mode": mode.rawValue, "text": trial.result.text,
                    "modelLoadMs": trial.loadMilliseconds, "inferenceMs": trial.result.inferenceMilliseconds,
                    "audioSeconds": trial.result.audioSeconds, "rtf": trial.result.rtf,
                    "device": trial.result.device, "decodeOnCPU": trial.result.decodeOnCPU,
                    "memory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(trial.result.memory))])
            }
        }
        let loaded = ProcessMemory.currentMiB()
        let previous = recognitionTrial?.result.text
        recognizeInput()
        try await Task.sleep(nanoseconds: 2_000_000)
        stop(); try await waitForCurrentOperation()
        guard recognitionTrial?.result.text == previous else { throw IrodoriError.invalid("Cancelled recognition replaced the transcript") }
        guard savedTrials.count == savedCount else { throw IrodoriError.invalid("Recognition removed saved TTS audio") }
        unloadModels(); try await waitForCurrentOperation()
        try await Task.sleep(nanoseconds: 500_000_000)
        var report: [String: Any] = ["rows": rows, "cancelledResultDiscarded": true, "savedTTSPreserved": true,
            "loadedMiB": loaded.map { $0 as Any } ?? NSNull(), "releasedMiB": ProcessMemory.currentMiB().map { $0 as Any } ?? NSNull()]
        if config["verifyTTSSwitch"] as? Bool == true {
            // Use generic synthesis for the probe; do not activate an existing
            // reference recording whose consent is intentionally reset at launch.
            let previousReference = referencePath
            referencePath = ""
            defer { referencePath = previousReference }
            selectBackend(.speechCpp); try await waitForCurrentOperation()
            speak(); try await waitForCurrentOperation(); stop()
            guard let trial = result else { throw IrodoriError.invalid("TTS failed after recognition") }
            report["ttsAfterRecognition"] = true
            report["ttsLoadStartMiB"] = trial.loadMemory?.startMiB
            recognitionDecoding = .beam; recognizeInput(); try await waitForCurrentOperation()
            guard recognitionLoadMilliseconds > 0 else { throw IrodoriError.invalid("ASR did not reload after TTS switched in") }
            report["recognitionAfterTTS"] = recognitionTrial?.result.text
            report["asrReloadMs"] = recognitionLoadMilliseconds
            unloadModels(); try await waitForCurrentOperation()
        }
        return report
    }
}
#endif

#endif
