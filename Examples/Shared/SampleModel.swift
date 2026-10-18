import SwiftUI
import AVFoundation
import CryptoKit
import IrodoriTTS
#if os(iOS) && canImport(IrodoriSpeechCpp)
import IrodoriSpeechCpp
#endif

@MainActor final class SampleModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var text = "こんにちは。今日はいい天気なので、近くの公園まで散歩に行きましょう。"
    @Published var caption = UserDefaults.standard.string(forKey: "caption") ?? "" {
        didSet { UserDefaults.standard.set(caption, forKey: "caption") }
    }
    @Published var modelPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
    @Published var referencePath = UserDefaults.standard.string(forKey: "referencePath") ?? ""
    @Published var manifestURL = ""
    @Published var downloadVariant: ModelVariant = ModelVariant.lightINT8.isSupported ? .lightINT8 : .standard
    struct InstalledModel: Identifiable {
        let url: URL
        let information: ModelBundleInformation
        var id: String { url.path }
    }
    @Published var installedModels: [InstalledModel] = []
    @Published var modelDetail = "現行版 約2.99 GB / 軽量INT8版 約1.96 GB"
    @Published var status = "モデルをダウンロードするか、取り込んでください。"
    @Published var statistics = ""
    @Published var busy = false { didSet { updateIdleTimer() } }
    @Published var recording = false { didSet { updateIdleTimer() } }
    @Published var consent = false
    @Published var outputURL: URL?
    private let engine = IrodoriEngine()
    let residency = ExclusiveModelSession()
    #if os(iOS) && canImport(IrodoriSpeechCpp)
    private let speechEngine = SpeechCppEngine()
    let recognitionEngine = SpeechRecognitionEngine(preferGpuGreedy: UIDevice.current.userInterfaceIdiom == .phone)
    @Published var showingRecognition = false
    @Published var recognitionInstalled = false
    @Published var recognitionDecoding = RecognitionDecoding(rawValue: UserDefaults.standard.string(forKey: "recognitionDecoding") ?? "beam") ?? .beam {
        didSet { UserDefaults.standard.set(recognitionDecoding.rawValue, forKey: "recognitionDecoding") }
    }
    @Published var recognitionInput: URL?
    @Published var recognitionTrial: RecognitionTrial?
    @Published var recognitionRecordingSeconds = 0.0
    var recognitionRecorder: AVAudioRecorder?
    var recognitionTimer: Timer?
    var recognitionLoadMilliseconds = 0.0
    var recognitionLoadMemory: MemoryObservation?
    #endif
    @Published private(set) var backend: SynthesisBackend = .coreML {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "comparisonBackend") }
    }
    @Published var seed = UserDefaults.standard.string(forKey: "comparisonSeed") ?? "12345" {
        didSet { UserDefaults.standard.set(seed, forKey: "comparisonSeed") }
    }
    @Published var watermarkEnabled = true
    @Published var speechInstalled = false
    @Published var downloadFraction: Double?
    @Published var currentMemoryMiB: Double?
    @Published var loadMemory: MemoryObservation?
    @Published var releaseBeforeMiB: Double?
    @Published var releaseAfterMiB: Double?
    @Published var residentDescription = "未ロード"
    @Published var savedTrials: [SynthesisTrial] = []
    var selectedTrial: SynthesisTrial? { savedTrials.first { $0.backend == backend } }
    private var memoryTimer: Timer?
    var downloadIdentifier: UUID?
    private var activeLoadMilliseconds = 0.0
    private var activeLoadMemory: MemoryObservation?
    private var referenceURLForRun: URL? { referencePath.isEmpty ? nil : URL(fileURLWithPath: referencePath) }
    private var speechDirectory: URL { store.appendingPathComponent("Models/speech-cpp-v4.1-f16") }
    var hasSelectedModel: Bool { backend == .coreML ? !modelPath.isEmpty : speechInstalled }
    var canCompare: Bool { !modelPath.isEmpty && speechInstalled && SynthesisBackend.available.count > 1 && SynthesisBackend.available.allSatisfy(\.supportsSynthesis) }
    var activeModelTitle: String { backend == .coreML ? modelDetail : "speech.cpp · F16 · 約1.92 GB＋透かしモデル" }

    @Published var result: SynthesisTrial?
    @Published var errorMessage: String?
    @Published var ready = false
    @Published var modelPreparationMilliseconds: Double?
    @Published var referencePreparationMilliseconds: Double?
    @Published var referenceCacheHit = false
    @Published var isPlaying = false
    @Published var playbackPosition = 0.0
    @Published var waveform: [Double] = []
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var task: Task<Void, Never>?
    let store: URL

    override init() {
        store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IrodoriSample", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        // Recorded files stay inside this app's container; only persist their basename.
        if !referencePath.isEmpty {
            referencePath = store.appendingPathComponent("References/\(URL(fileURLWithPath: referencePath).lastPathComponent)").path
        }
        if !modelPath.isEmpty && !FileManager.default.fileExists(atPath: modelPath) {
            let replacement = store.appendingPathComponent("Models/\(URL(fileURLWithPath: modelPath).lastPathComponent)")
            if FileManager.default.fileExists(atPath: replacement.path) { modelPath = replacement.path }
            else {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let moved = documents.appendingPathComponent(URL(fileURLWithPath: modelPath).lastPathComponent)
                if FileManager.default.fileExists(atPath: moved.path) { modelPath = moved.path }
            }
        }
        refreshInstalledModels()
        refreshSpeechModel()
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        refreshRecognitionModel()
        #endif
        if let stored = UserDefaults.standard.string(forKey: "comparisonBackend"),
           let backend = SynthesisBackend(rawValue: stored), SynthesisBackend.available.contains(backend) { self.backend = backend }
        restoreSavedTrials()
        currentMemoryMiB = ProcessMemory.currentMiB()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.currentMemoryMiB = ProcessMemory.currentMiB() }
        }
        memoryTimer = timer; RunLoop.main.add(timer, forMode: .common)
        if hasSelectedModel {
            status = referencePath.isEmpty
                ? "文章を入力して、音声を生成できます。"
                : "登録音声の利用許可を確認して、音声を生成してください。"
        }
    }

    deinit {
        memoryTimer?.invalidate(); playbackTimer?.invalidate()
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        recognitionTimer?.invalidate(); recognitionRecorder?.stop()
        #endif
        let session = residency
        Task { await session.release() }
    }

    func refreshInstalledModels() {
        let files = FileManager.default
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var roots = [URL]()
        for parent in [store.appendingPathComponent("Models"), documents] {
            roots += (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        if !modelPath.isEmpty { roots.append(URL(fileURLWithPath: modelPath)) }
        var seen = Set<String>()
        installedModels = roots.compactMap { root in
            guard seen.insert(root.path).inserted, let info = try? ModelBundle.information(at: root) else { return nil }
            return InstalledModel(url: root, information: info)
        }.sorted { $0.information.variant.rawValue < $1.information.variant.rawValue }
        if let current = installedModels.first(where: { $0.id == modelPath }) { modelDetail = current.information.description }
    }

    func selectModel(_ path: String) {
        guard path != modelPath else { return }
        work {
            self.status = "モデルを検証しています…"
            let url = URL(fileURLWithPath: path)
            try await Task.detached { try ModelBundle.validate(at: url, verifyHashes: true) }.value
            try Task.checkCancellation()
            await self.activateModel(url)
            self.status = "モデルを切り替えました。"
        }
    }

    private func activateModel(_ url: URL) async {
        stopPlayback()
        await releaseResident()
        ready = false
        modelPreparationMilliseconds = nil
        referencePreparationMilliseconds = nil
        referenceCacheHit = false
        statistics = ""
        modelPath = url.path
        UserDefaults.standard.set(url.path, forKey: "modelPath")
        refreshInstalledModels()
    }

    func downloadSelectedVariant() {
        guard downloadVariant.isSupported else { status = "軽量INT8版には \(downloadVariant.minimumOS) 以降が必要です。"; return }
        manifestURL = downloadVariant.manifestURL.absoluteString
        download()
    }

    private func updateIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = busy || recording
        #if IRODORI_SAMPLE_DIAGNOSTICS
        if didRunDeviceSmoke { UIApplication.shared.isIdleTimerDisabled = true }
        #endif
        #endif
    }

    func work(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy, !recording else { return }
        stopPlayback()
        errorMessage = nil
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            do { try await body() }
            catch {
                await releaseResident()
                if Task.isCancelled || error is CancellationError { status = "停止しました。" }
                else { report(error) }
            }
        }
    }

    func importModel(_ source: URL) {
        work {
            await self.releaseResident()
            self.status = "モデルをコピーして検証しています…"
            let allowed = source.startAccessingSecurityScopedResource()
            defer { if allowed { source.stopAccessingSecurityScopedResource() } }
            let destination = self.store.appendingPathComponent("Models/\(UUID().uuidString)")
            try await Task.detached {
                try ModelBundle.validate(at: source, verifyHashes: true)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try FileManager.default.copyItem(at: source, to: destination) }
                catch { try? FileManager.default.removeItem(at: destination); throw error }
            }.value
            await self.activateModel(destination)
            self.status = "モデルを取り込みました。音声の準備を実行してください。"
        }
    }

    func download() {
        guard let url = URL(string: manifestURL), url.scheme == "https" else { status = "HTTPSのmanifest.json URLを入力してください。"; return }
        work {
            await self.releaseResident()
            let downloadID = UUID(); self.downloadIdentifier = downloadID
            self.downloadFraction = 0
            defer { self.downloadFraction = nil; self.downloadIdentifier = nil }
            self.status = "モデルを取得しています…"
            let suffix = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
            let destination = self.store.appendingPathComponent("Models/download-\(suffix)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try await Task.detached { try ModelBundle.validate(at: destination, verifyHashes: true) }.value
            } else {
                try await ModelDownloader().download(manifestURL: url, to: destination) { done, total, file in
                    Task { @MainActor in
                        guard self.downloadIdentifier == downloadID else { return }
                        self.status = "取得 \(done)/\(total): \(file)"
                    }
                } byteProgress: { received, total in
                    Task { @MainActor in
                        guard self.downloadIdentifier == downloadID else { return }
                        self.downloadFraction = Double(received) / Double(max(total, 1))
                    }
                }
            }
            try Task.checkCancellation()
            await self.activateModel(destination)
            self.status = "取得と検証が完了しました。"
        }
    }

    func importReference(_ source: URL) {
        guard consent else { status = "利用する声の許可を確認してください。"; return }
        work {
            let allowed = source.startAccessingSecurityScopedResource()
            defer { if allowed { source.stopAccessingSecurityScopedResource() } }
            let destination = self.store.appendingPathComponent("References/\(UUID().uuidString).\(source.pathExtension)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached { _ = try ReferenceAudio.read(source); try FileManager.default.copyItem(at: source, to: destination) }.value
            self.ready = false
            self.referencePath = destination.path
            UserDefaults.standard.set(destination.path, forKey: "referencePath")
            self.status = "参照音声を登録しました。"
        }
    }

    func prepare() {
        work { try await self.prepareEngine() }
    }
    private func prepareEngine() async throws {
        let snapshot = try inputSnapshot()
        let target = backend
        try await withBackend(target, snapshot: snapshot) {
            try await self.prepareReference(for: target, reference: snapshot.reference)
        }
        status = "準備できました。"
    }

    private func inputSnapshot() throws -> SynthesisInput {
        if !referencePath.isEmpty && !consent { throw IrodoriError.invalid("利用する声の許可を確認してください。") }
        guard let seed = UInt32(seed) else { throw IrodoriError.invalid("seedは0〜4294967295の整数にしてください。") }
        return SynthesisInput(text: text, caption: caption, seed: seed, reference: referenceURLForRun,
            coreMLDescription: modelDetail, coreMLDirectory: modelPath.isEmpty ? nil : URL(fileURLWithPath: modelPath),
            speechDirectory: speechDirectory, watermark: watermarkEnabled, group: UUID())
    }

    private func withBackend<T: Sendable>(_ target: SynthesisBackend, snapshot: SynthesisInput,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let directory: URL
        if target == .coreML {
            guard let root = snapshot.coreMLDirectory else { throw IrodoriError.invalid("Core MLモデルをダウンロードしてください。") }
            directory = root
        } else {
            guard speechInstalled else { throw IrodoriError.invalid("speech.cppモデルをダウンロードしてください。") }
            directory = snapshot.speechDirectory
        }
        let unloader: @Sendable () async -> Void
        if target == .coreML { let engine = self.engine; unloader = { await engine.release() } }
        else {
            #if os(iOS) && canImport(IrodoriSpeechCpp)
            let engine = self.speechEngine; unloader = { await engine.release() }
            #else
            unloader = {}
            #endif
        }
        return try await residency.withModel(identifier: target.rawValue + ":" + directory.path, load: {
            await self.noteReleaseBeforeLoad()
            let sampler = ProcessMemorySampler()
            defer { _ = sampler.finish() }
            let milliseconds: Double
            if target == .coreML { milliseconds = try await self.engine.prepare(modelDirectory: directory) }
            else {
                #if os(iOS) && canImport(IrodoriSpeechCpp)
                milliseconds = try await self.speechEngine.prepare(modelDirectory: directory)
                #else
                throw IrodoriError.invalid("speech.cppはiPhoneサンプルで利用できます。")
                #endif
            }
            await self.noteLoaded(target, milliseconds: milliseconds, memory: sampler.finish())
        }, release: unloader, operation: operation)
    }

    private func noteReleaseBeforeLoad() {
        releaseAfterMiB = ProcessMemory.currentMiB()
        residentDescription = "準備中"
    }
    private func noteLoaded(_ target: SynthesisBackend, milliseconds: Double, memory: MemoryObservation) {
        activeLoadMilliseconds = milliseconds; activeLoadMemory = memory
        loadMemory = memory; modelPreparationMilliseconds = milliseconds; residentDescription = target.title
    }

    private func prepareReference(for target: SynthesisBackend, reference: URL?) async throws {
        let registration: ReferenceRegistration
        if target == .coreML { registration = try await engine.registerReference(reference) }
        else {
            #if os(iOS) && canImport(IrodoriSpeechCpp)
            registration = try await speechEngine.registerReference(reference)
            #else
            throw IrodoriError.invalid("speech.cppはiPhoneサンプルで利用できます。")
            #endif
        }
        referencePreparationMilliseconds = registration.milliseconds
        referenceCacheHit = registration.cacheHit; ready = true
    }

    private func generate(_ target: SynthesisBackend, snapshot: SynthesisInput) async throws -> SynthesisTrial {
        activeLoadMilliseconds = 0
        // A separate prepare call is unnecessary: withModel keeps the engine resident on repeated use.
        let result = try await withBackend(target, snapshot: snapshot) {
            try await self.prepareReference(for: target, reference: snapshot.reference)
            if target == .coreML {
                return try await self.engine.synthesize(snapshot.text, caption: snapshot.caption, seed: snapshot.seed,
                    splitSentences: false, watermark: snapshot.watermark ? WatermarkOptions() : nil)
            } else {
                #if os(iOS) && canImport(IrodoriSpeechCpp)
                return try await self.speechEngine.synthesize(snapshot.text, caption: snapshot.caption, seed: snapshot.seed,
                    watermark: snapshot.watermark ? WatermarkOptions() : nil)
                #else
                throw IrodoriError.invalid("speech.cppはiPhoneサンプルで利用できます。")
                #endif
            }
        }
        try Task.checkCancellation()
        // Consume load metadata once, so reused requests show 0 ms without losing the last real load result.
        let loadedThisCall = activeLoadMilliseconds > 0
        let loadMs = activeLoadMilliseconds; activeLoadMilliseconds = 0
        let url = store.appendingPathComponent("generated-\(target.rawValue).wav")
        try result.writeWAV(to: url)
        let trial = SynthesisTrial(backend: target, group: snapshot.group, url: url, text: result.preparedText,
            seed: result.generationSeeds.first ?? snapshot.seed, watermark: snapshot.watermark,
            synthesisMilliseconds: result.synthesisMilliseconds, firstPCMMilliseconds: result.firstPCMMilliseconds,
            audioSeconds: result.audioSeconds, modelLoadMilliseconds: loadedThisCall ? loadMs : 0,
            referenceMilliseconds: referencePreparationMilliseconds ?? 0,
            loadMemory: activeLoadMemory, memory: result.memory, waveform: Self.envelope(result.pcm16),
            device: result.diagnostics.first?["metalKernel"] ?? "Core ML",
            modelDescription: target == .coreML ? snapshot.coreMLDescription : "Irodori v4.1 Small MF · F16")
        savedTrials.removeAll { $0.backend == target }; savedTrials.append(trial)
        persistSavedTrials()
        showTrial(trial)
        return trial
    }

    func speak() {
        work {
            let snapshot = try self.inputSnapshot()
            self.status = "\(self.backend.title)で生成しています…"
            _ = try await self.generate(self.backend, snapshot: snapshot)
            try self.startPlayback()
        }
    }

    func compare() {
        work {
            guard self.canCompare else { throw IrodoriError.invalid("比較する両方のモデルをダウンロードしてください。") }
            let snapshot = try self.inputSnapshot()
            for target in SynthesisBackend.available {
                try Task.checkCancellation()
                self.status = "\(target.title)で比較音声を生成しています…"
                _ = try await self.generate(target, snapshot: snapshot)
                await self.releaseResident()
            }
            if let selected = self.selectedTrial, selected.group == snapshot.group {
                self.showTrial(selected); try self.startPlayback()
            }
        }
    }

    private func persistSavedTrials() {
        if let bytes = try? JSONEncoder().encode(savedTrials) {
            try? bytes.write(to: store.appendingPathComponent("generated-results.json"), options: .atomic)
        }
    }
    private func restoreSavedTrials() {
        guard let bytes = try? Data(contentsOf: store.appendingPathComponent("generated-results.json")), bytes.count < 1_048_576,
              let trials = try? JSONDecoder().decode([SynthesisTrial].self, from: bytes) else { return }
        var seen = Set<SynthesisBackend>()
        savedTrials = trials.compactMap { original in
            guard seen.insert(original.backend).inserted, SynthesisBackend.available.contains(original.backend) else { return nil }
            var trial = original
            // App-container UUIDs can change after installation. Never trust a stored absolute path.
            trial.url = store.appendingPathComponent("generated-\(trial.backend.rawValue).wav")
            return FileManager.default.fileExists(atPath: trial.url.path) ? trial : nil
        }
        showSelectedTrial()
    }

    private func showSelectedTrial() {
        if let selectedTrial { showTrial(selectedTrial) }
        else {
            stopPlayback(); result = nil; outputURL = nil; waveform = []; statistics = ""
            modelPreparationMilliseconds = nil
        }
    }

    private func showTrial(_ trial: SynthesisTrial) {
        stopPlayback(); result = trial; outputURL = trial.url; waveform = trial.waveform
        modelPreparationMilliseconds = trial.modelLoadMilliseconds
        statistics = String(format: "モデル %.0f ms / 参照 %.0f ms / 生成 %.0f ms / RTF %.3f",
            trial.modelLoadMilliseconds, trial.referenceMilliseconds, trial.synthesisMilliseconds, trial.rtf)
    }
    func replay(_ trial: SynthesisTrial) {
        guard !busy, !recording else { return }
        showTrial(trial)
        do { try startPlayback() } catch { report(error) }
    }
    func replayCurrent() { if let result { replay(result) } }

    func releaseResident() async {
        releaseBeforeMiB = ProcessMemory.currentMiB()
        await residency.release()
        releaseAfterMiB = ProcessMemory.currentMiB(); currentMemoryMiB = releaseAfterMiB
        ready = false; residentDescription = "未ロード"; activeLoadMilliseconds = 0; activeLoadMemory = nil
    }
    func unloadModels() { work { await self.releaseResident(); self.status = "モデルを解放しました。保存済み音声は再生できます。" } }
    func suspend() {
        stopPlayback()
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        if recognitionRecorder != nil { finishRecognitionRecording(recognize: false) }
        else if recording { toggleRecording() }
        #else
        if recording { toggleRecording() }
        #endif
        if busy { task?.cancel() }
        else { unloadModels() }
    }
    func selectBackend(_ target: SynthesisBackend) {
        guard target != backend else { return }
        work {
            await self.releaseResident(); self.backend = target
            self.showSelectedTrial()
            self.status = self.hasSelectedModel ? "文章を入力して生成できます。" : "モデルをダウンロードしてください。"
        }
    }
    private func refreshSpeechModel() {
        #if os(iOS) && canImport(IrodoriSpeechCpp)
        speechInstalled = SpeechCppModelBundle.isInstalled(at: speechDirectory)
        #else
        speechInstalled = false
        #endif
    }
    func downloadSpeechModel(importing source: URL? = nil) {
        work {
            #if os(iOS) && canImport(IrodoriSpeechCpp)
            await self.releaseResident()
            let downloadID = UUID(); self.downloadIdentifier = downloadID
            self.downloadFraction = 0
            defer { self.downloadFraction = nil; self.downloadIdentifier = nil }
            self.status = "speech.cppモデルを取得しています…"
            let allowed = source?.startAccessingSecurityScopedResource() ?? false
            defer { if allowed { source?.stopAccessingSecurityScopedResource() } }
            try await SpeechCppModelBundle.download(to: self.speechDirectory, importingGGUF: source) { done, total, name in
                Task { @MainActor in
                    guard self.downloadIdentifier == downloadID else { return }
                    self.downloadFraction = Double(done) / Double(max(total, 1))
                    self.status = String(format: "取得 %.1f / %.1f GB", Double(done)/1e9, Double(total)/1e9)
                }
            }
            try Task.checkCancellation()
            self.refreshSpeechModel(); self.status = "speech.cppの取得と検証が完了しました。"
            #endif
        }
    }
    func deleteSelectedModel() {
        work {
            await self.releaseResident()
            if self.backend == .speechCpp {
                if FileManager.default.fileExists(atPath: self.speechDirectory.path) { try FileManager.default.removeItem(at: self.speechDirectory) }
                self.refreshSpeechModel()
            } else if !self.modelPath.isEmpty {
                let url = URL(fileURLWithPath: self.modelPath).standardizedFileURL.resolvingSymlinksInPath()
                let own = self.store.appendingPathComponent("Models").standardizedFileURL.resolvingSymlinksInPath().path + "/"
                guard url.path.hasPrefix(own) else { throw IrodoriError.invalid("このアプリで取り込んだモデルだけ削除できます。") }
                try FileManager.default.removeItem(at: url)
                self.modelPath = ""; UserDefaults.standard.removeObject(forKey: "modelPath"); self.refreshInstalledModels()
            }
            self.status = "モデルを削除しました。"
        }
    }

    #if IRODORI_SAMPLE_DIAGNOSTICS
    var didRunDeviceSmoke = false
    func waitForCurrentOperation() async throws {
        let pending = task
        await pending?.value
        if let errorMessage { throw IrodoriError.invalid(errorMessage) }
    }
    #endif

    func stop() {
        task?.cancel()
        stopPlayback()
        status = busy ? "停止しています…" : "停止しました。"
    }

    var playbackFraction: Double {
        guard let duration = result?.audioSeconds, duration > 0 else { return 0 }
        return min(1, playbackPosition / duration)
    }
    var playbackTime: String {
        let elapsed = Int(playbackPosition)
        let duration = Int(result?.audioSeconds ?? 0)
        return String(format: "%d:%02d / %d:%02d", elapsed / 60, elapsed % 60, duration / 60, duration % 60)
    }

    func togglePlayback() {
        guard !busy, !recording else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            playbackTimer?.invalidate(); playbackTimer = nil
            status = "一時停止中です。"
        } else {
            do { try startPlayback() }
            catch { report(error) }
        }
    }

    private func startPlayback() throws {
        guard let url = outputURL else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        if player == nil {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        guard let player else { return }
        if playbackFraction >= 1 { player.currentTime = 0; playbackPosition = 0 }
        guard player.play() else { throw IrodoriError.invalid("音声を再生できませんでした。") }
        errorMessage = nil; isPlaying = true; status = "再生中です。"
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.playbackPosition = self.player?.currentTime ?? 0
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlayback() {
        playbackTimer?.invalidate(); playbackTimer = nil
        player?.stop(); player = nil
        isPlaying = false; playbackPosition = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.playbackTimer?.invalidate(); self.playbackTimer = nil
            self.isPlaying = false
            self.playbackPosition = self.result?.audioSeconds ?? 0
            self.status = flag ? "再生が完了しました。" : "音声の再生を完了できませんでした。"
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stopPlayback()
            self.report(error ?? IrodoriError.invalid("音声を再生できませんでした。"))
        }
    }

    func report(_ error: Error) {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError { return }
        let message = error.localizedDescription
        status = message.contains("sentence exceeds model limit")
            ? "文章がモデルの上限を超えています。短くして、もう一度生成してください。"
            : message
        errorMessage = status
    }

    // Display actual peak amplitudes from the generated PCM, without changing the audio.
    private static func envelope(_ pcm: Data) -> [Double] {
        let count = pcm.count / 2
        guard count > 0 else { return [] }
        return pcm.withUnsafeBytes { raw in
            (0..<32).map { bin in
                let start = bin * count / 32, end = (bin + 1) * count / 32
                var peak = 0.0
                for index in start..<end {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    peak = max(peak, abs(Double(sample)) / 32768)
                }
                return sqrt(peak)
            }
        }
    }

    func deleteReference() {
        work {
            self.stopPlayback()
            await self.releaseResident()
            try await self.engine.clearReferenceCache()
            // Delete only this sample's imported/recorded files, never the selected original.
            let directory = self.store.appendingPathComponent("References")
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            self.ready = false
            self.referencePath = ""; UserDefaults.standard.removeObject(forKey: "referencePath")
            self.status = "登録音声と参照特徴キャッシュを削除しました。"
        }
    }

    func toggleRecording() {
        if recording {
            recorder?.stop(); recorder = nil; recording = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false)
            #endif
            guard let url = recordingURL else { return }
            do { _ = try ReferenceAudio.read(url)
                ready = false
                referencePath = url.path; UserDefaults.standard.set(url.path, forKey: "referencePath")
                status = "録音を登録しました。"
            } catch { try? FileManager.default.removeItem(at: url); report(error) }
            return
        }
        guard consent, !busy else { status = "自分の声、または許可のある声を録音してください。"; return }
        work {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw IrodoriError.invalid("マイクのアクセスが許可されていません。") }
            self.stopPlayback()
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let url = self.store.appendingPathComponent("References/\(UUID().uuidString).wav")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            guard self.recorder?.record() == true else { throw IrodoriError.invalid("録音を開始できません。") }
            self.recordingURL = url; self.recording = true; self.status = "録音中。3〜10秒を目安に停止してください。"
        }
    }
}
