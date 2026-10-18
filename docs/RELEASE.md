# 配布内容と互換性

[SDK導入](GETTING_STARTED.md) · [モデル取得](HUGGINGFACE.md) · [変更点](releases/0.3.0.md)

## コードとサンプル

| 内容 | 入口 |
| --- | --- |
| Core ML Swift SDK・Mac CLI | ルートの `Package.swift`、product `IrodoriTTS` / `irodori` |
| speech.cpp TTS・ASR Swift SDK | `Packages/IrodoriSpeechCpp`、product `IrodoriSpeechCpp`。リポジトリ一式からローカル追加 |
| iPhone比較アプリ | `Examples/IrodoriComparison.xcodeproj` |
| Core ML iPhone / Macサンプル | `Examples/IrodoriSamples.xcodeproj` |
| モデル変換・評価ツール | `Conversion/`、`Benchmarks/` |

[CoreML版リポジトリ](https://github.com/Corvelis/irodori-tts-coreml)のExact Version `0.2.0` から取得する `IrodoriTTS` はCore ML SDKです。
speech.cppと共通の追加計測APIを使う場合は、このリポジトリ一式のローカルパッケージを使用します。
プロジェクトZIPにはビルド済みspeech.cppライブラリを含み、Xcodeが自動展開します。モデル重み、音声、署名情報は含めません。

## モデル

| モデル | 容量 | 必要なOS | 互換性 |
| --- | ---: | --- | --- |
| Core ML 現行版 | 約2.99 GB | iOS 17 / macOS 14以降 | SDK 0.1.0以降、bundleVersion `0.1.0` |
| Core ML 軽量INT8版 | 約1.96 GB | iOS 18 / macOS 15以降 | SDK 0.2.0以降、bundleVersion `0.2.0-int8` |
| speech.cpp TTS F16 | 約1.92 GB＋AudioSeal | iOS 17以降、実機iPhone | `SpeechCppModelBundle` の指定モデル |
| ReazonSpeech Q4_K | 約357 MB | iOS 17以降、実機iPhone | `ReazonSpeechModel` の指定モデル |

Core MLモデルは[Hugging Face](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)で別配布しています。
現行版はルート、軽量版は `int8/` にあり、CLI・SDKは選択したモデルだけを取得します。
各モデルを完全な一式として保持し、別版の部品を混ぜないでください。取得先とハッシュ検証は[モデル取得ガイド](HUGGINGFACE.md)にあります。

比較アプリは方式ごとにモデルを取得・削除できます。ReazonSpeechは耳ボタンから任意取得します。
同時に保持する推論モデルは1つで、切替時は前の解放後に次をロードします。

## 実行要件

開発にはApple Silicon MacとXcodeを使用します。SDKはSwift tools 5.9以降が対象です。
モデル取得後の推論は端末内で行い、PythonやONNX Runtimeは不要です。
アプリのビルドには同梱ライブラリを使用します。speech.cppランタイムをソースから再ビルドする場合だけGit、CMake、Ninja、Python 3が必要です。

TTS出力は48 kHz mono PCM16です。AudioSeal透かしは既定で有効です。
初回のコンパイル・ロードには追加時間がかかり、モデル原本に加えてコピー・キャッシュ用容量が必要です。
入力上限・時間・RAMは[計測と制約](VALIDATION.md)を参照してください。

## 利用条件

SDK・サンプルの新規部分はApache-2.0です。モデルと上流由来部分にはMIT / Apache-2.0の部品別条件が適用されます。
`LICENSES/`、`NOTICE`、[部品別表示](../THIRD_PARTY_NOTICES.md)を保持し、[上流の使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。
