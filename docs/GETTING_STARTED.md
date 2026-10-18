# Irodori TTS SDKをXcodeに組み込む

[README](../README.md) · [Core ML・共通API](API.md) · [speech.cpp API](../Packages/IrodoriSpeechCpp/README.md)

## SDKを選ぶ

| product | 主なクラス | 対応環境 | 追加する場所 |
| --- | --- | --- | --- |
| `IrodoriTTS` | `IrodoriEngine`、`AudioWatermarker` | iOS 17 / macOS 14以降 | リポジトリルート |
| `IrodoriSpeechCpp` | `SpeechCppEngine`、`SpeechRecognitionEngine` | iOS 17以降、実機iPhone | `Packages/IrodoriSpeechCpp` |

開発にはApple Silicon Mac、XcodeとCommand Line Toolsを使用します。SDKにモデルは内蔵されていないため、使用するモデルを取得します。
Core MLの軽量INT8版にはiOS 18 / macOS 15以降が必要です。

## Core ML SDKを追加する

取得したソースを使用する場合は、Xcodeの **File → Add Package Dependencies… → Add Local…** でリポジトリルートを選び、アプリtargetへ **IrodoriTTS** productを追加します。

公開済みCore ML SDKを使う場合は、同じ画面で `https://github.com/Corvelis/irodori-tts-coreml.git` を入力し、**Exact Version 0.2.0** と **IrodoriTTS** productを選びます。
この版はCore ML向けです。seed指定・RAM計測・排他モデル管理の追加APIを使う場合は、このソースのローカルパッケージを使用します。

モデルは[取得ガイド](HUGGINGFACE.md)から一式を取得するか、SDKで取得します。`models` にはモデル一式の親フォルダを指定します。

```swift
import Foundation
import IrodoriTTS

func downloadCoreML(to newDirectory: URL) async throws {
    try await ModelDownloader().download(
        manifestURL: ModelVariant.standard.manifestURL,
        to: newDirectory
    )
}

func makeCoreMLWAV(engine: IrodoriEngine, models: URL,
                   reference: URL?, output: URL) async throws -> SynthesisResult {
    try await engine.prepare(modelDirectory: models)
    try await engine.registerReference(reference)
    let audio = try await engine.synthesize("こんにちは。", splitSentences: false)
    try audio.writeWAV(to: output)
    return audio
}
```

`newDirectory` は新しい保存先、`output` は親フォルダを作成済みのWAV保存先です。参照なしでは `reference: nil` を渡します。
`IrodoriEngine()` を保持して連続生成で再利用し、利用終了時に `await engine.release()` を呼びます。
文分割を利用する場合は `splitSentences` を省略します。[文章整形と長文](API.md#文章整形と長文)を参照してください。

## speech.cpp SDKを追加する

1. リポジトリ全体を取得します。ビルド済みライブラリを同梱しているため、セットアップは不要です。
2. Xcodeの **Add Local…** から `Packages/IrodoriSpeechCpp` を選び、iOS targetへ **IrodoriSpeechCpp** productを追加します。
3. 共通型を直接使う場合は、同じソースのルートから **IrodoriTTS** productも追加します。

このパッケージはルートの `IrodoriTTS` を相対参照し、同梱ZIPの `SpeechCpp.xcframework` をXcodeが自動展開してリンクします。
**リポジトリ一式の階層を保持し、ルートSDKと追加パッケージには同じソースを使ってください。**
`IrodoriSpeechCpp` の導入には上記のローカル追加を使用します。

```swift
import Foundation
import IrodoriTTS
import IrodoriSpeechCpp

func downloadMetal(to models: URL) async throws {
    try await SpeechCppModelBundle.download(to: models)
}

func makeMetalWAV(engine: SpeechCppEngine, models: URL,
                  output: URL) async throws -> SynthesisResult {
    try await engine.prepare(modelDirectory: models)
    try await engine.registerReference(nil)
    let audio = try await engine.synthesize("こんにちは。", seed: 12345)
    try audio.writeWAV(to: output)
    return audio
}
```

`models` はアプリが書き込めるモデル保存先です。ダウンロードと完全ハッシュ検証は初回導入・更新時に行い、通常の発話では `prepare` 以降を呼びます。
`SpeechCppEngine()` を保持して再利用し、使用終了時に `await engine.release()` を呼びます。音声認識には [ASRの例](ASR.md#sdk)を使います。

## 複数モデルを排他利用する

TTS方式やASRを切り替える場合は、アプリで1つの `ExclusiveModelSession` を共有します。
モデルの準備と推論をこのsession経由で行うと、前のモデルの解放完了後に次をロードします。同じ識別子は再利用します。

```swift
let session = ExclusiveModelSession() // アプリで保持し、全方式で共有する
let engine = SpeechCppEngine()       // 連続生成で再利用する

func speak(models: URL, text: String) async throws -> SynthesisResult {
    try await session.withModel(
        identifier: "speech:" + models.standardizedFileURL.path,
        load: { _ = try await engine.prepare(modelDirectory: models) },
        release: { await engine.release() },
        operation: {
            try await engine.registerReference(nil)
            return try await engine.synthesize(text)
        }
    )
}
```

Core MLやASRも同じsessionを通し、識別子には方式とモデルの場所を含めます。sessionを使用する場合、解放も `await session.release()` で行います。
個々のengineを直接呼ぶだけでは、別engineのロードを自動的に抑止しません。

## RAMとロード時間を測る

両TTSの `SynthesisResult.memory` とASRの `RecognitionResult.memory` には、推論中のアプリ全体RAMの観測値が入ります。
ロード中のRAMは、ロードの前後に別のサンプラーを使います。

```swift
let sampler = ProcessMemorySampler()
defer { _ = sampler.finish() }
let loadMs = try await engine.prepare(modelDirectory: models)
let loadMemory = sampler.finish()
print(loadMs, loadMemory.peakMiB as Any)
```

`prepare` の戻り値はロード時間msで、同じモデルを保持中なら0です。RAMの単位・最大値の範囲は[計測ガイド](VALIDATION.md)を参照してください。

## アプリ側の設定

録音には `NSMicrophoneUsageDescription` とマイク許可要求が必要です。
MacのサンドボックスアプリではAudio Input、ユーザー選択ファイルのアクセス、モデル取得用Outgoing Connectionsを使用します。[サンプルのentitlements](../Examples/macOS/IrodoriMac.entitlements)を参照してください。

Filesで選んだモデルや音声は、セキュリティスコープが有効な間に検証・アプリ内へコピーし、そのURLで使用します。
音声再生、Audio Session、割り込み、バックグラウンド動作、モデル・音声の保存管理はアプリ側で実装します。
[サンプル操作](SAMPLES.md)、[音声登録と削除](VOICE_REGISTRATION.md)、[チャンク再生と停止](STREAMING.md)に実装例があります。
