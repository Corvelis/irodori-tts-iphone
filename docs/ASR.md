# iPhoneの音声認識

[サンプル操作](SAMPLES.md) · [SDK導入](GETTING_STARTED.md) · [計測ガイド](VALIDATION.md)

比較アプリの耳ボタンから、ReazonSpeech NeMo v2 Q4_Kで日本語音声を文字起こしできます。
モデルは任意の追加ダウンロードです。取得後は端末内で認識し、音声認識サービスへの送信は行いません。

## アプリで使う

1. 耳ボタンを押し、「Q4_Kモデルをダウンロード」で約357 MBをWi-Fi取得します。手元の同じGGUFも取り込めます。
2. `beam` または `greedy` を選びます。
3. 「録音して認識」でマイクを許可して話し、「録音を終了して認識」で処理します。録音は最大60秒です。
4. ファイル入力は「音声ファイルを選ぶ」→「選んだ音声を認識する」を使います。WAV / M4AなどAVAudioFileで読める0.16〜60秒の音声に対応します。
5. 同じファイルで方式を切り替えて再認識できます。beam／greedy切替と連続認識ではモデルを再利用します。
6. 結果をコピーするか、「読み上げ画面へ」でTTS本文へ転記できます。

録音を終了してから認識する方式です。VADによる自動区切りや常時聞き取りは提供していません。

## モデルの保持と計測

耳ボタンを開くとTTSモデルを解放し、認識開始時にASRモデルをロードします。
連続認識中は保持し、画面を閉じる・手動解放・バックグラウンド移行・メモリ警告・処理停止時に解放します。
録音中にバックグラウンドへ移行すると、その録音を破棄します。

ロード、音声変換、認識時間を別々に表示します。RTFは認識時間÷無音追加前の入力音声長です。
入力の前後には各900 msの無音を追加します。エンコーダーはMetalで処理し、beamはCPUデコーダーを使用します。
`preferGpuGreedy: true` では、対応するiPhoneのgreedyにMetal 4 tensorのGPUデコーダーを使用します。

RAMはアプリ全体のphysical footprint（MiB）です。現在値は約0.5秒、ロード・認識中は約10 ms間隔で測定します。
結果には最大観測値、取得回数、取得エラー数、最大サンプル間隔を表示します。[性能と計測の定義](VALIDATION.md)を参照してください。

## SDK

[導入手順](GETTING_STARTED.md#speechcpp-sdkを追加する)に従い、`IrodoriSpeechCpp` を追加します。
初回にモデルを取得し、通常の認識では保持したengineを使用します。

```swift
import Foundation
import IrodoriSpeechCpp

func installASR(to models: URL) async throws {
    let model = models.appendingPathComponent(ReazonSpeechModel.fileName)
    try await ReazonSpeechModel.download(to: model)
}

func recognize(engine: SpeechRecognitionEngine, models: URL,
               input: URL) async throws -> RecognitionResult {
    let model = models.appendingPathComponent(ReazonSpeechModel.fileName)
    let loadMs = try await engine.prepare(modelFile: model)
    let result = try await engine.transcribe(input, decoding: .beam)
    print(loadMs, result.inferenceMilliseconds, result.memory.peakMiB as Any)
    return result
}
```

`SpeechRecognitionEngine(preferGpuGreedy: true)` を保持し、利用終了時に `await engine.release()` を呼びます。
`preferGpuGreedy` の既定値はfalseです。`.greedy` を使う場合も `transcribe` の `decoding` で選びます。

| 結果の項目 | 内容 |
| --- | --- |
| `text` / `decoding` | 認識文字列とデコード方式 |
| `audioSeconds` | 無音追加前の入力音声長 |
| `conversionMilliseconds` | ファイル読込・16 kHzモノラルPCM16への変換時間 |
| `inferenceMilliseconds` / `rtf` | 認識時間と音声長に対する比率 |
| `memory` | 認識中のアプリ全体RAMの観測値 |
| `device` / `decodeOnCPU` | Metalの実行経路とデコーダーのCPU使用有無 |

TTSと併用する場合は、全方式を同じ `ExclusiveModelSession` 経由で呼びます。
Simulatorでは画面とビルドを確認でき、推論には実機iPhoneが必要です。

## モデルとライセンス

- 元モデル：[reazon-research/reazonspeech-nemo-v2](https://huggingface.co/reazon-research/reazonspeech-nemo-v2)（Apache-2.0）。
- [Q4_K GGUF](https://huggingface.co/sakasegawa/reazonspeech-nemo-v2-GGUF/tree/ed04d9ee2cd156414982a7c0f6123c6fd1093904)、固定revision `ed04d9ee2cd156414982a7c0f6123c6fd1093904`。
- ファイル `reazonspeech-nemo-619M-v2-Q4_K.gguf`、357,216,832 bytes。
- SHA-256 `d761f6b65572a0ec46db04f3f9cc829d25084608bcdcb86bc2aae4b95e4bb4c9`。
