#if os(iOS) && canImport(IrodoriSpeechCpp)
import Foundation
import AVFoundation
import UIKit
import IrodoriTTS
import IrodoriSpeechCpp

struct RecognitionTrial {
    let result: RecognitionResult
    let inputName: String
    let loadMilliseconds: Double
    let loadMemory: MemoryObservation?
}

@MainActor extension SampleModel {
    var recognitionModelFile: URL { store.appendingPathComponent("Models/reazonspeech-q4/\(ReazonSpeechModel.fileName)") }
    var recognitionRecordingFile: URL { store.appendingPathComponent("Recognition/recording.wav") }

    func refreshRecognitionModel() { recognitionInstalled = (try? ReazonSpeechModel.validate(recognitionModelFile)) != nil }

    func openRecognition() {
        work {
            await self.releaseResident()
            self.showingRecognition = true
            self.status = self.recognitionInstalled ? "録音するか、音声ファイルを選んで認識できます。" : "まずQ4_Kモデルをダウンロードしてください。"
        }
    }

    func downloadRecognitionModel(importing source: URL? = nil) {
        work {
            await self.releaseResident()
            let identifier = UUID(); self.downloadIdentifier = identifier; self.downloadFraction = 0
            defer { self.downloadIdentifier = nil; self.downloadFraction = nil }
            self.status = source == nil ? "ReazonSpeech Q4_Kを取得しています…" : "Q4_Kをコピーして検証しています…"
            let target = self.recognitionModelFile
            if let source {
                let allowed = source.startAccessingSecurityScopedResource()
                defer { if allowed { source.stopAccessingSecurityScopedResource() } }
                try await Task.detached { try ReazonSpeechModel.importFile(source, to: target) }.value
            } else {
                try await ReazonSpeechModel.download(to: target) { count in
                    Task { @MainActor in
                        guard self.downloadIdentifier == identifier else { return }
                        self.downloadFraction = Double(count) / Double(ReazonSpeechModel.bytes)
                    }
                }
            }
            try Task.checkCancellation()
            self.refreshRecognitionModel(); self.status = "Q4_Kの取得と検証が完了しました。"
        }
    }

    func deleteRecognitionModel() {
        work {
            await self.releaseResident()
            if FileManager.default.fileExists(atPath: self.recognitionModelFile.path) {
                try FileManager.default.removeItem(at: self.recognitionModelFile)
            }
            self.refreshRecognitionModel(); self.status = "音声認識モデルを削除しました。"
        }
    }

    func importRecognitionAudio(_ source: URL) {
        work {
            let allowed = source.startAccessingSecurityScopedResource()
            defer { if allowed { source.stopAccessingSecurityScopedResource() } }
            let target = self.store.appendingPathComponent("Recognition/input-\(UUID().uuidString).\(source.pathExtension)")
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: target) } }
            try await Task.detached {
                _ = try RecognitionAudio.read(source)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            }.value
            try Task.checkCancellation()
            if let old = self.recognitionInput, old != self.recognitionRecordingFile { try? FileManager.default.removeItem(at: old) }
            self.recognitionInput = target; self.recognitionTrial = nil
            committed = true
            self.status = "音声を取り込みました。「認識する」で試せます。"
        }
    }

    func recognizeInput() {
        guard let input = recognitionInput else { status = "録音するか、音声ファイルを選んでください。"; return }
        let decoding = recognitionDecoding
        work {
            guard self.recognitionInstalled else { throw IrodoriError.invalid("Q4_Kモデルをダウンロードしてください。") }
            self.recognitionLoadMilliseconds = 0
            self.status = "\(decoding.rawValue)で音声を認識しています…"
            let engine = self.recognitionEngine, file = self.recognitionModelFile
            let result = try await self.residency.withModel(identifier: "recognition:" + file.path, load: {
                let memory = ProcessMemorySampler()
                defer { _ = memory.finish() }
                let ms = try await engine.prepare(modelFile: file)
                await self.noteRecognitionLoaded(ms, memory: memory.finish())
            }, release: { await engine.release() }, operation: {
                try await engine.transcribe(input, decoding: decoding)
            })
            try Task.checkCancellation()
            self.recognitionTrial = RecognitionTrial(result: result, inputName: input == self.recognitionRecordingFile ? "録音した音声" : "取り込んだ音声",
                loadMilliseconds: self.recognitionLoadMilliseconds, loadMemory: self.recognitionLoadMemory)
            self.status = result.text.isEmpty ? "認識できる発話がありませんでした。" : "音声認識が完了しました。"
        }
    }

    private func noteRecognitionLoaded(_ ms: Double, memory: MemoryObservation) {
        recognitionLoadMilliseconds = ms; recognitionLoadMemory = memory
        residentDescription = "ReazonSpeech Q4_K"; loadMemory = memory
    }

    func startRecognitionRecording() {
        work {
            guard self.recognitionInstalled else { throw IrodoriError.invalid("Q4_Kモデルをダウンロードしてください。") }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw IrodoriError.invalid("マイクのアクセスが許可されていません。設定アプリで許可できます。")
            }
            try Task.checkCancellation()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let file = self.recognitionRecordingFile
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                self.recognitionRecorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                guard self.recognitionRecorder?.record(forDuration: 60) == true else { throw IrodoriError.invalid("録音を開始できません。") }
            } catch {
                self.recognitionRecorder = nil; try? session.setActive(false)
                throw error
            }
            self.recognitionRecordingSeconds = 0; self.recording = true
            self.status = "録音中。話し終えたら「録音を終了して認識」を押してください。"
            self.startRecognitionTimer()
        }
    }

    private func startRecognitionTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recognitionRecorder else { return }
                self.recognitionRecordingSeconds = recorder.currentTime
                if recorder.currentTime >= 60 || !recorder.isRecording { self.finishRecognitionRecording() }
            }
        }
        recognitionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    func finishRecognitionRecording(recognize: Bool = true) {
        guard recognitionRecorder != nil else { return }
        recognitionTimer?.invalidate(); recognitionTimer = nil
        recognitionRecorder?.stop(); recognitionRecorder = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        if recognize {
            if let old = recognitionInput, old != recognitionRecordingFile { try? FileManager.default.removeItem(at: old) }
            recognitionInput = recognitionRecordingFile; recognitionTrial = nil
            recognizeInput()
        } else {
            try? FileManager.default.removeItem(at: recognitionRecordingFile)
            if recognitionInput == recognitionRecordingFile { recognitionInput = nil }
            status = "録音を停止しました。"
        }
    }
}
#endif
