# IrodoriSpeechCpp — iPhone向けSwift SDK

Irodori v4.1 Small MFのMetal音声合成と、ReazonSpeech NeMo v2 Q4_Kの音声認識を提供します。
共通の音声型・AudioSeal・RAM計測にはルートの `IrodoriTTS` を使用します。

[SDK導入](../../docs/GETTING_STARTED.md) · [音声認識](../../docs/ASR.md) · [計測ガイド](../../docs/VALIDATION.md)

## ビルドと追加

Apple Silicon MacとXcodeでリポジトリ一式を開きます。iPhone arm64／Simulator arm64用のビルド済みライブラリを `Artifacts/SpeechCpp.xcframework.zip` に同梱し、Xcodeが自動展開します。
CMake・Ninja・Pythonやセットアップコマンドは不要です。
Xcodeでこの `Packages/IrodoriSpeechCpp` フォルダをローカルSwift Packageとして追加し、**IrodoriSpeechCpp** productをiOS targetにリンクします。
共通型を直接使う場合は、ルートの **IrodoriTTS** productも同じソースから追加します。
パッケージがルートを相対参照するため、リポジトリ全体の階層を維持してください。iOS 17以降が対象で、推論には実機iPhoneが必要です。

## TTS

初回導入時に `SpeechCppModelBundle.download(to:)` を呼びます。モデルはF16 GGUFとAudioSealの一式です。
取得済みファイルはサイズ・SHA-256を再検証して再利用します。通常の発話ではモデル取得を繰り返さず、保持したengineを使います。

```swift
import Foundation
import IrodoriTTS
import IrodoriSpeechCpp

func installTTS(to models: URL) async throws {
    try await SpeechCppModelBundle.download(to: models)
}

func makeWAV(engine: SpeechCppEngine, models: URL, output: URL) async throws -> SynthesisResult {
    try await engine.prepare(modelDirectory: models)
    try await engine.registerReference(nil)
    let audio = try await engine.synthesize("こんにちは。", seed: 12345)
    try audio.writeWAV(to: output)
    return audio
}
```

| API | 動作 |
| --- | --- |
| `SpeechCppEngine()` | 連続生成で保持するengineを作成 |
| `prepare(modelDirectory:) async throws -> Double` | モデルをロードし、時間msを返す。同じフォルダを保持中なら0 |
| `registerReference(_ url: URL?) async throws -> ReferenceRegistration` | 参照音声を準備。nilで参照なし |
| `synthesize(_:caption:seed:watermark:onChunk:) async throws -> SynthesisResult` | 読み上げ用整形後、全文を1回で合成 |
| `release() async` | モデル・参照状態を解放 |
| `SpeechCppModelBundle.validate(at:verifyHashes:)` | モデル一式を検証。新規取得・取り込み時はtrueで全ハッシュを検証 |
| `SpeechCppModelBundle.download(to:importingGGUF:progress:)` | 固定モデルを取得。手元の同一GGUFも取り込み可能 |

`caption` は日本語の話し方指定、`seed` は再現用のUInt32値です。AudioSealは既定で有効で、`watermark: nil` で無効化します。
`onChunk` は推論キュー上でPCM16を通知します。再生やUI更新はアプリ側のキューへ渡してください。
このAPIは全文を1回で合成し、Core ML SDKの `rawText` / `splitSentences` 引数は持ちません。
長さの上限と結果型の詳細は[APIリファレンス](../../docs/API.md)を参照してください。

## 音声認識

`SpeechRecognitionEngine` は `prepare(modelFile:)`、`transcribe(_:decoding:)`、`release()` を提供します。
`RecognitionDecoding.beam` / `.greedy` を指定でき、結果は文字列・音声長・変換時間・推論時間・RTF・RAMを含みます。
モデル取得とコード例は[ASRガイド](../../docs/ASR.md#sdk)にあります。

## メモリと計測

複数バックエンドを使う場合は、1つの `ExclusiveModelSession` をアプリで共有します。
前のモデルを解放してから次をロードし、同じ識別子での連続処理はモデルを再利用します。[排他利用の例](../../docs/GETTING_STARTED.md#複数モデルを排他利用する)を参照してください。

TTSの `SynthesisResult` は共通SDKの型です。生成時間・RTF・最初のPCM時間にはAudioSealを含み、モデルと参照音声の準備は含めません。
`memory` は約10 ms間隔で計測したアプリ全体physical footprintの最大観測値などです。
ロード中のRAMは `ProcessMemorySampler` で別に計測できます。

## ランタイム

Metalを明示的に選び、対応するGPUでは行列検証後にMetal 4 tensorを使用します。それ以外は通常のMetalを使用します。
TTSはF16・4ステップ・後続デコード窓128で実行します。
固定ソース、同梱パッチ、ビルド設定は[開発手順](../../docs/DEVELOPMENT.md#speechcppランタイム)にあります。

- [speech.cpp](https://github.com/nyosegawa/speech.cpp) / ggml: MIT。条文は `LICENSES/` に同梱。
- [Irodori GGUF](https://huggingface.co/sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF): 元モデルの部品別条件を保持。
- [共通部品・モデルの利用条件](../../THIRD_PARTY_NOTICES.md)。
