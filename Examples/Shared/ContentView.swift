import SwiftUI
import IrodoriTTS
import UniformTypeIdentifiers

private enum StudioStyle {
    static let accent = adaptive(light: (0.08, 0.43, 0.39), dark: (0.42, 0.79, 0.71))
    static let buttonInk = adaptive(light: (1, 1, 1), dark: (0.06, 0.15, 0.13))
    static let mutedAccent = Color(red: 0.68, green: 0.87, blue: 0.79)
    static let canvas = adaptive(light: (0.955, 0.963, 0.960), dark: (0.085, 0.095, 0.098))
    static let surface = adaptive(light: (1, 1, 1), dark: (0.125, 0.138, 0.140))
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #endif
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: SampleModel
    @State private var importing = false
    @State private var importKind: ImportKind = .model
    @State private var downloadExpanded = false
    #if os(macOS)
    @State private var exportingWAV = false
    @State private var wavDocument: SampleWAVDocument?
    #endif
    @FocusState private var focusedField: Field?
    private enum Field { case text, caption, url }
    private enum ImportKind { case model, speechModel, reference }
    private var importTypes: [UTType] {
        switch importKind { case .model: return [.folder]; case .speechModel: return [.data]; case .reference: return [.audio] }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if geometry.size.width >= 840 {
                        HStack(alignment: .top, spacing: 24) {
                            workspace.frame(maxWidth: .infinity)
                            settings.frame(width: 310)
                        }
                    } else {
                        workspace
                        settings
                    }
                    Text(SynthesisBackend.available.count > 1 ? "Irodori TTS v4.1 Small MF · Core ML / speech.cpp" : "Irodori TTS v4.1 Small MF · Core ML")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(geometry.size.width >= 840 ? 32 : 20)
                .frame(maxWidth: 1160)
                .frame(maxWidth: .infinity)
            }
            .background(StudioStyle.canvas)
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(StudioStyle.accent)
        #if IRODORI_SAMPLE_DIAGNOSTICS
        .task { await model.runDeviceSmokeIfRequested() }
        #endif
        .onDisappear { model.suspend() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.suspend() } }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.suspend() }
        #if canImport(IrodoriSpeechCpp)
        .sheet(isPresented: $model.showingRecognition, onDismiss: { model.suspend() }) {
            RecognitionPanel(model: model)
        }
        #endif
        #endif
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url):
                if importKind == .model { model.importModel(url) }
                else if importKind == .speechModel { model.downloadSpeechModel(importing: url) }
                else { model.importReference(url) }
            case .failure(let error): model.report(error)
            }
        }
        #if os(macOS)
        .fileExporter(isPresented: $exportingWAV, document: wavDocument,
                      contentType: .wav, defaultFilename: "irodori") { result in
            switch result {
            case .success: model.status = "WAVを保存しました。"
            case .failure(let error): model.report(error)
            }
        }
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
            }
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(StudioStyle.accent)
                .frame(width: 54, height: 54)
                .background(StudioStyle.mutedAccent.opacity(0.45), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text("Irodori").font(.system(size: 32, weight: .bold, design: .rounded))
                Text(SynthesisBackend.available.count > 1 ? "音声合成・認識" : "オンデバイス音声合成")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            #if os(iOS) && canImport(IrodoriSpeechCpp)
            Button(action: model.openRecognition) {
                Image(systemName: "ear").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .accessibilityLabel("音声認識を試す").accessibilityIdentifier("openRecognition")
            .disabled(model.busy || model.recording)
            #endif
            Text(model.backend == .coreML ? "Core ML" : "Metal")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.primary.opacity(0.05), in: Capsule())
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            memoryPanel
            if SynthesisBackend.available.count > 1 {
                Picker("実行方式", selection: Binding(get: { model.backend }, set: { model.selectBackend($0) })) {
                    ForEach(SynthesisBackend.available) { backend in Text(backend.title).tag(backend) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("backend")
                .disabled(model.busy || model.recording)
            }
            if !model.hasSelectedModel { modelSettings }
            composer
            if model.selectedTrial != nil { savedAudio }
            if let result = model.result, result.backend == model.backend {
                metrics(result)
                playback
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("読み上げるテキスト", systemImage: "text.alignleft").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.text.count) 文字").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("声にしたい文章を入力してください。")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .accessibilityIdentifier("speechText")
                    .font(.system(size: 18)).lineSpacing(7)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180, maxHeight: 240)
                    .focused($focusedField, equals: .text)
                    .disabled(model.busy || model.recording)
            }
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
            HStack(spacing: 12) {
                Button {
                    focusedField = nil
                    model.speak()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "waveform")
                        Text(model.busy ? "処理中…" : "生成して再生")
                    }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(GenerateButtonStyle())
                .accessibilityIdentifier("speak")
                .disabled(model.busy || model.recording || !model.hasSelectedModel || !model.backend.supportsSynthesis || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("もう一度再生", action: model.replayCurrent)
                    .buttonStyle(.bordered).accessibilityIdentifier("replay")
                    .disabled(model.result == nil || model.busy || model.recording)
                if model.busy || model.isPlaying {
                    Button(action: model.stop) {
                        Image(systemName: "stop.fill").frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
                    .accessibilityLabel("停止").accessibilityIdentifier("stop")
                }
            }
            if SynthesisBackend.available.count > 1 {
                Button("両方式で生成して比較", action: model.compare)
                    .buttonStyle(.bordered).accessibilityIdentifier("compare")
                    .disabled(model.busy || model.recording || !model.canCompare || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("1方式ずつ生成・解放します。比較後は保存した音声を切り替えて聴けます。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let fraction = model.downloadFraction { ProgressView(value: fraction).accessibilityIdentifier("downloadProgress") }
            HStack(alignment: .top, spacing: 9) {
                if model.busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: model.errorMessage != nil ? "exclamationmark.circle" : "circle.fill")
                        .font(.system(size: model.errorMessage != nil ? 14 : 6))
                        .padding(.top, model.errorMessage != nil ? 1 : 5)
                }
                Text(model.status).accessibilityIdentifier("status")
                    .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(model.errorMessage != nil ? Color.red : Color.secondary)
        }
        .studioCard()
    }

    private func metrics(_ result: SynthesisTrial) -> some View {
        HStack(spacing: 0) {
            metric("RTF", value: String(format: "%.3f", result.rtf))
            Divider().frame(height: 34)
            metric("生成時間", value: String(format: "%.2f s", result.synthesisMilliseconds / 1000))
            Divider().frame(height: 34)
            metric("音声の長さ", value: String(format: "%.2f s", result.audioSeconds))
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("statistics")
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("生成した音声 · \(model.result?.backend.title ?? "")").font(.subheadline.weight(.semibold))
                Spacer()
                if let url = model.outputURL {
                    #if os(macOS)
                    Button {
                        do {
                            wavDocument = SampleWAVDocument(data: try Data(contentsOf: url))
                            exportingWAV = true
                        } catch { model.report(error) }
                    } label: { Label("WAVを保存", systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("saveOutput")
                    .font(.caption.weight(.medium)).disabled(model.busy || model.recording)
                    #else
                    ShareLink(item: url) { Label("WAVを保存", systemImage: "square.and.arrow.up") }
                        .font(.caption.weight(.medium)).disabled(model.busy || model.recording)
                    #endif
                }
            }
            HStack(spacing: 14) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(StudioStyle.accent.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("playOutput")
                .accessibilityLabel(model.isPlaying ? "一時停止" : "生成音声を再生")
                .disabled(model.busy || model.recording)
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        ForEach(Array(model.waveform.enumerated()), id: \.offset) { index, value in
                            Capsule()
                                .fill(Double(index) / Double(max(model.waveform.count, 1)) < model.playbackFraction
                                      ? StudioStyle.accent : StudioStyle.accent.opacity(0.2))
                                .frame(width: max(2, (geometry.size.width - 3 * CGFloat(model.waveform.count - 1)) / CGFloat(max(model.waveform.count, 1))),
                                       height: max(4, CGFloat(value) * 36))
                        }
                    }.frame(height: 40)
                }.frame(height: 40)
                Text(model.playbackTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(model.result?.watermark == true ? "AIによる合成音声 · AudioSeal透かし付き · 48 kHz / WAV" : "AIによる合成音声 · 透かしなし · 48 kHz / WAV")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .studioCard()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.hasSelectedModel { modelSettings }
            voiceSettings
            comparisonSettings
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("モデル", systemImage: "cpu").font(.subheadline.weight(.semibold))
                Spacer()
                Text(!model.hasSelectedModel ? "未取得" : model.ready ? "準備済み" : "保存済み")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(!model.hasSelectedModel ? Color.secondary : StudioStyle.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(StudioStyle.accent.opacity(0.07), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Irodori v4.1 Small MF").font(.subheadline.weight(.medium))
                Text(model.activeModelTitle).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("modelDetail")
            }
            if model.backend == .coreML {
            if !model.installedModels.isEmpty {
                Picker("保存済みモデル", selection: Binding(get: { model.modelPath }, set: { model.selectModel($0) })) {
                    if model.modelPath.isEmpty { Text("選択してください").tag("") }
                    ForEach(model.installedModels) { installed in
                        Text(installed.information.description).tag(installed.id)
                    }
                }
                .pickerStyle(.menu).font(.caption)
                .accessibilityIdentifier("installedModels")
                .disabled(model.busy || model.recording)
            }
            Button(action: model.refreshInstalledModels) {
                Label("保存済みモデルを更新", systemImage: "arrow.clockwise")
            }.font(.caption).buttonStyle(.plain)
                .disabled(model.busy || model.recording)
            HStack {
                Button {
                    focusedField = nil; importKind = .model; importing = true
                } label: { Label(model.modelPath.isEmpty ? "フォルダを選ぶ" : "モデルを変更", systemImage: "folder") }
                    .accessibilityIdentifier("importModel")
                Spacer(minLength: 8)
                Button("準備", action: model.prepare).accessibilityIdentifier("prepare")
                    .disabled(model.modelPath.isEmpty)
            }
            .font(.caption.weight(.medium)).buttonStyle(.bordered)
            .disabled(model.busy || model.recording)
            VStack(alignment: .leading, spacing: 10) {
                Picker("取得するモデル", selection: $model.downloadVariant) {
                    ForEach(ModelVariant.allCases) { variant in
                        Text(String(format: "%@ · %.2f GB", variant.title, Double(variant.approximateBytes) / 1_000_000_000)).tag(variant)
                    }
                }
                .pickerStyle(.menu).accessibilityIdentifier("downloadVariant")
                Text("\(model.downloadVariant.minimumOS)以降")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("モデルをダウンロード", action: model.downloadSelectedVariant)
                    .buttonStyle(.bordered).accessibilityIdentifier("downloadModel")
                    .disabled(!model.downloadVariant.isSupported)
            }.font(.caption).disabled(model.busy || model.recording)
            DisclosureGroup("URLからダウンロード", isExpanded: $downloadExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("manifest.json のHTTPS URL", text: $model.manifestURL)
                        .textFieldStyle(.roundedBorder).focused($focusedField, equals: .url)
                    Button("ダウンロードして検証", action: model.download)
                        .buttonStyle(.bordered).disabled(model.manifestURL.isEmpty)
                }.padding(.top, 10)
            }
            .font(.caption).disabled(model.busy || model.recording)
            } else {
                #if targetEnvironment(simulator)
                Text("speech.cppの生成は実機iPhoneでお試しください。Simulatorは画面確認用です。")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                Text("Irodori v4.1 Small MF F16と、共通のAudioSealモデルを取得します。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button(model.speechInstalled ? "モデルを再検証" : "モデルをダウンロード") { model.downloadSpeechModel() }
                    .buttonStyle(.bordered).accessibilityIdentifier("downloadSpeechModel")
                    .disabled(model.busy || model.recording || !model.backend.supportsSynthesis)
                Button("GGUFを取り込む") { importKind = .speechModel; importing = true }
                    .buttonStyle(.bordered).font(.caption)
                    .disabled(model.busy || model.recording || model.speechInstalled || !model.backend.supportsSynthesis)
            }
            HStack {
                Button("モデルを解放", action: model.unloadModels).accessibilityIdentifier("unloadModels")
                Spacer()
                Button("モデルを削除", role: .destructive, action: model.deleteSelectedModel)
                    .disabled(!model.hasSelectedModel)
            }.font(.caption).buttonStyle(.bordered).disabled(model.busy || model.recording)
            if let milliseconds = model.modelPreparationMilliseconds {
                Text(String(format: "準備 %.0f ms · 参照 %.0f ms%@", milliseconds,
                            model.referencePreparationMilliseconds ?? 0, model.referenceCacheHit ? "（キャッシュ）" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("モデル取得はWi-Fi接続で行います。初回の準備には時間がかかることがあります。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.studioCard()
    }

    private func memoryText(_ value: Double?) -> String {
        value.map { String(format: "%.1f MiB", $0) } ?? "—"
    }
    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("RAM（アプリ全体）", systemImage: "memorychip").font(.caption.weight(.semibold))
                Spacer()
                Text(memoryText(model.currentMemoryMiB)).monospacedDigit().font(.headline)
                    .accessibilityIdentifier("currentMemory")
            }
            Text("使用中のモデル：\(model.residentDescription)").font(.caption2).foregroundStyle(.secondary)
            if model.releaseBeforeMiB != nil {
                Text("解放前 \(memoryText(model.releaseBeforeMiB)) → 解放後 \(memoryText(model.releaseAfterMiB))")
                    .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("releaseMemory")
            }
            DisclosureGroup("計測について") {
                Text("アプリ全体のphysical footprint。現在値は約0.5秒ごと、処理中の最大観測値は約10 ms間隔で取得します。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.font(.caption2).foregroundStyle(.secondary)
        }.studioCard()
    }
    private var savedAudio: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("生成結果").font(.subheadline.weight(.semibold))
            if let trial = model.selectedTrial {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(trial.backend.title).font(.subheadline.weight(.medium))
                        Spacer()
                        Button("再生") { model.replay(trial) }
                            .accessibilityIdentifier("replay-" + trial.backend.rawValue)
                            .disabled(model.busy || model.recording)
                        ShareLink(item: trial.url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("\(trial.backend.title)のWAVを保存")
                            .disabled(model.busy || model.recording)
                    }
                    if let description = trial.modelDescription { Text(description).font(.caption2).foregroundStyle(.secondary) }
                    Text(trial.text).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "RTF %.3f · 生成 %.0f ms · 音声データ出力まで %.0f ms", trial.rtf, trial.synthesisMilliseconds, trial.firstPCMMilliseconds))
                        .font(.caption).monospacedDigit()
                    Text(String(format: "モデルロード %.0f ms%@ · 参照準備 %.0f ms", trial.modelLoadMilliseconds,
                        trial.modelLoadMilliseconds == 0 ? "（再利用）" : "", trial.referenceMilliseconds))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("ロード中の最大観測 \(memoryText(trial.loadMemory?.peakMiB))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("推論中の最大観測 \(memoryText(trial.memory?.peakMiB)) · 終了時 \(memoryText(trial.memory?.endMiB))")
                        .font(.caption.weight(.medium)).accessibilityIdentifier("peakMemory-" + trial.backend.rawValue)
                    Text("\(trial.device) · seed \(trial.seed) · \(trial.watermark ? "透かしあり" : "透かしなし")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let memory = trial.memory {
                        Text(String(format: "RAM取得 %d回 · エラー %d回 · 最大間隔 %.1f ms", memory.sampleCount, memory.readErrorCount, memory.maximumSampleGapMilliseconds))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }.studioCard()
    }
    private var comparisonSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("生成・比較の設定").font(.subheadline.weight(.semibold))
            TextField("seed（0〜4294967295）", text: $model.seed)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("seed")
            Toggle("AudioSealの透かし", isOn: $model.watermarkEnabled).font(.caption)
                .accessibilityIdentifier("watermark")
            Text("両方式に同じseedを渡します。演算や乱数生成の違いにより波形・音声長は変わります。")
                .font(.caption2).foregroundStyle(.secondary)
        }.studioCard().disabled(model.busy || model.recording)
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("声と話し方", systemImage: "person.wave.2").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.referencePath.isEmpty ? "参照なし" : "登録音声あり")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("落ち着いた、やさしい話し方。", text: $model.caption, axis: .vertical)
                .accessibilityIdentifier("voiceCaption").lineLimit(2...4).textFieldStyle(.plain)
                .focused($focusedField, equals: .caption)
                .padding(12).background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
                .disabled(model.busy || model.recording)
            Text("声や話し方を短く指定できます。空欄でも生成できます。")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: $model.consent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("利用できる声を登録").font(.caption.weight(.medium))
                    Text("自分の声、または明示的に許可を得た声")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("voiceConsent").toggleStyle(.switch)
            .disabled(model.busy || model.recording)
            HStack {
                Button {
                    focusedField = nil; importKind = .reference; importing = true
                } label: { Label("音声を選ぶ", systemImage: "waveform.badge.plus") }
                    .accessibilityIdentifier("importReference")
                    .disabled(model.recording || !model.consent)
                Spacer(minLength: 4)
                Button(action: model.toggleRecording) {
                    Label(model.recording ? "録音を停止" : "録音する", systemImage: model.recording ? "stop.circle" : "mic")
                }
                .accessibilityIdentifier("recordReference")
                .tint(model.recording ? .red : StudioStyle.accent)
                .disabled(!model.recording && !model.consent)
            }
            .font(.caption.weight(.medium)).buttonStyle(.bordered).disabled(model.busy)
            if model.recording {
                Label("録音中 · 3〜10秒を目安に停止してください", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            if !model.referencePath.isEmpty {
                Button(role: .destructive, action: model.deleteReference) {
                    Label("登録音声とキャッシュを削除", systemImage: "trash")
                }
                .font(.caption).buttonStyle(.plain).accessibilityIdentifier("deleteReference")
                .disabled(model.busy || model.recording)
            }
        }.studioCard()
    }
}

private struct GenerateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? StudioStyle.buttonInk : Color.secondary)
            .background(enabled ? StudioStyle.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private extension View {
    func studioCard() -> some View {
        padding(22)
            .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.045), lineWidth: 1))
    }
}

#if os(macOS)
/// Export the completed WAV without changing its header or PCM bytes.
private struct SampleWAVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
