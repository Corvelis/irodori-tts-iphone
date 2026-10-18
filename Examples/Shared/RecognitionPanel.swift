#if os(iOS) && canImport(IrodoriSpeechCpp)
import SwiftUI
import UniformTypeIdentifiers
import IrodoriSpeechCpp
import IrodoriTTS

struct RecognitionPanel: View {
    @ObservedObject var model: SampleModel
    @State private var importing = false
    @State private var importingModel = false
    @State private var deleting = false
    private var simulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    private func memory(_ value: Double?) -> String { value.map { String(format: "%.1f MiB", $0) } ?? "—" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("RAM（アプリ全体）", value: memory(model.currentMemoryMiB))
                        .monospacedDigit().accessibilityIdentifier("recognitionCurrentRAM")
                    Text("使用中のモデル：\(model.residentDescription)").font(.caption).foregroundStyle(.secondary)
                    if let before = model.releaseBeforeMiB {
                        Text("解放前 \(memory(before)) → 解放後 \(memory(model.releaseAfterMiB))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: { Text("TTSと音声認識はモデルを交代で使います。保存済みの合成音声は保持します。") }

                Section {
                    Label(model.recognitionInstalled ? "取得済み · 約357 MB" : "未取得 · 約357 MB",
                          systemImage: model.recognitionInstalled ? "checkmark.circle" : "arrow.down.circle")
                    if !model.recognitionInstalled {
                        Button("Q4_Kモデルをダウンロード") { model.downloadRecognitionModel() }
                            .accessibilityIdentifier("downloadRecognitionModel").disabled(model.busy || model.recording)
                    }
                    DisclosureGroup("モデル管理") {
                        Button("Q4_K GGUFを取り込む") { importingModel = true; importing = true }
                            .disabled(model.busy || model.recording)
                        Button("モデルを解放", action: model.unloadModels).disabled(model.busy || model.recording)
                        Button("モデルを削除", role: .destructive) { deleting = true }
                            .disabled(model.busy || model.recording || !model.recognitionInstalled)
                    }
                    if let progress = model.downloadFraction { ProgressView(value: progress) }
                } header: { Text("ReazonSpeech NeMo v2 · Q4_K") }
                  footer: { Text("取得はWi-Fiで行い、サイズとSHA-256を検証します。認識は端末内で実行します。") }

                Section {
                    Picker("認識方式", selection: $model.recognitionDecoding) {
                        ForEach(RecognitionDecoding.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("recognitionDecoding").disabled(model.busy || model.recording)
                    Button {
                        if model.recording { model.finishRecognitionRecording() }
                        else { model.startRecognitionRecording() }
                    } label: {
                        Label(model.recording ? "録音を終了して認識" : "録音して認識", systemImage: model.recording ? "stop.circle.fill" : "mic.fill")
                    }
                    .tint(model.recording ? .red : .accentColor)
                    .accessibilityIdentifier("recordRecognition")
                    .disabled(model.busy || (!model.recording && !model.recognitionInstalled) || simulator)
                    if model.recording {
                        Text(String(format: "録音中 %.1f / 60 秒", model.recognitionRecordingSeconds)).monospacedDigit().foregroundStyle(.red)
                        Button("録音を破棄", role: .destructive) { model.finishRecognitionRecording(recognize: false) }
                    }
                    Button { importingModel = false; importing = true } label: {
                        Label("音声ファイルを選ぶ", systemImage: "waveform.badge.plus")
                    }.accessibilityIdentifier("importRecognitionAudio").disabled(model.busy || model.recording)
                    if model.recognitionInput != nil {
                        Button("選んだ音声を認識する", action: model.recognizeInput)
                            .accessibilityIdentifier("recognizeInput").disabled(model.busy || model.recording || !model.recognitionInstalled || simulator)
                    }
                    if simulator { Text("音声認識は実機iPhoneで試してください。").font(.caption).foregroundStyle(.secondary) }
                } header: { Text("音声入力") }
                  footer: { Text("録音を終了してから認識します。ファイルも最大60秒。同じ音声でbeam／greedyを比較でき、方式を変えてもモデルは再利用します。") }

                Section {
                    HStack {
                        if model.busy { ProgressView() }
                        Text(model.status).font(.callout).foregroundStyle(model.errorMessage == nil ? Color.secondary : .red)
                            .accessibilityIdentifier("recognitionStatus")
                    }
                    if model.busy { Button("処理を停止", role: .destructive, action: model.stop) }
                }

                if let trial = model.recognitionTrial {
                    Section("認識結果 · \(trial.result.decoding.rawValue)") {
                        Text(trial.result.text.isEmpty ? "発話を認識できませんでした。" : trial.result.text)
                            .textSelection(.enabled).accessibilityIdentifier("recognitionText")
                        HStack {
                            Button("コピー") { UIPasteboard.general.string = trial.result.text }
                            Spacer()
                            Button("読み上げ画面へ") { model.text = trial.result.text; model.showingRecognition = false }
                        }.disabled(model.busy || model.recording || trial.result.text.isEmpty)
                    }
                    Section("今回の計測") {
                        LabeledContent("モデルロード", value: trial.loadMilliseconds == 0 ? "0 ms（再利用）" : String(format: "%.0f ms", trial.loadMilliseconds))
                        LabeledContent("認識時間", value: String(format: "%.1f ms", trial.result.inferenceMilliseconds))
                        LabeledContent("音声の長さ", value: String(format: "%.2f s", trial.result.audioSeconds))
                        LabeledContent("RTF", value: String(format: "%.3f", trial.result.rtf))
                        LabeledContent("ロード中の最大観測RAM", value: trial.loadMilliseconds == 0 ? "—（再利用）" : memory(trial.loadMemory?.peakMiB))
                        LabeledContent("認識中の最大観測RAM", value: memory(trial.result.memory.peakMiB))
                        DisclosureGroup("計測の詳細") {
                            Text("\(trial.inputName) · \(trial.result.device)")
                            Text(trial.result.decodeOnCPU ? "エンコーダー：Metal／デコーダー：CPU" : "エンコーダー・デコーダー：Metal")
                            Text(String(format: "音声変換 %.1f ms（認識時間とは別）", trial.result.conversionMilliseconds))
                            Text(String(format: "RAM取得 %d回／エラー %d回／最大間隔 %.1f ms", trial.result.memory.sampleCount,
                                        trial.result.memory.readErrorCount, trial.result.memory.maximumSampleGapMilliseconds))
                            Text("RAMはアプリ全体のphysical footprint。現在値は約0.5秒、処理中の最大観測値は約10 ms間隔で取得します。")
                        }.font(.caption)
                    }.monospacedDigit()
                }
            }
            .navigationTitle("音声認識").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { model.showingRecognition = false }.disabled(model.busy || model.recording)
            }}
            .interactiveDismissDisabled(model.busy || model.recording)
            .fileImporter(isPresented: $importing, allowedContentTypes: importingModel ? [.data] : [.audio]) { result in
                switch result {
                case .success(let url):
                    if importingModel { model.downloadRecognitionModel(importing: url) }
                    else { model.importRecognitionAudio(url) }
                case .failure(let error): model.report(error)
                }
            }
            .confirmationDialog("音声認識モデルを削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("モデルを削除", role: .destructive, action: model.deleteRecognitionModel)
            }
        }
    }
}
#endif
