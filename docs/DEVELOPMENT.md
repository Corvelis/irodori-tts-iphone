# ビルドと検証

[サンプル操作](SAMPLES.md) · [SDK導入](GETTING_STARTED.md) · [モデル変換](CONVERSION.md)

## プロジェクト

| プロジェクト | 対象 | 事前ビルド |
| --- | --- | --- |
| `Examples/IrodoriSamples.xcodeproj` | Core ML iPhone / Mac | 不要 |
| `Examples/IrodoriComparison.xcodeproj` | iPhone Core ML / speech.cpp比較・ASR | 不要（ライブラリ同梱） |

両プロジェクトは `Examples/Shared` の画面とモデル管理を使用します。
比較アプリの通常schemeは `IrodoriiOS`、診断用schemeは `IrodoriiOS-Diagnostics` です。
診断用は最適化した `Diagnostics` 構成で `IRODORI_SAMPLE_DIAGNOSTICS` を定義し、`Examples/Diagnostics/ComparisonSmoke.swift` の起動処理を有効にします。

## プロジェクトの再生成

生成済みプロジェクトを通常ビルドする場合はRubyは不要です。
再生成する場合は、`Gemfile` に指定したxcodeprojをインストールします。

```sh
bundle install
bundle exec ruby Scripts/generate_project.rb --force
```

`--force` は上記2つのプロジェクトを作り直します。Signing Team等のローカル設定は再設定してください。
アプリバージョンは `VERSION` から設定し、UUIDは入力から安定生成します。

## speech.cppランタイム

| 依存 | 固定commit |
| --- | --- |
| speech.cpp 0.8.10 | `a72f1bbedd50e293d5b3f4c2bf0fb44ec003227d` |
| ggml v0.27.0ベースのfork | `a655cf6910770404213bc338e622cd82b08ca277` |

通常のアプリ・SDKビルドでは `Packages/IrodoriSpeechCpp/Artifacts/SpeechCpp.xcframework.zip` を使用し、Xcodeが自動展開します。`Artifacts/runtime.json` にアーカイブと各ファイルのSHA-256、上流revision、ビルドスクリプトのハッシュを記録しています。

ランタイムを変更・再ビルドする場合だけ、Git、CMake、Ninja、Python 3を用意して次を実行します。

```sh
bash Scripts/setup.sh --comparison --build-runtime
python3 Scripts/package_speech_runtime.py --verify
```

`Packages/IrodoriSpeechCpp/Scripts/build-runtime.sh` が固定ソースを取得し、コピーへ `Packages/IrodoriSpeechCpp/Scripts/Patches/` の変更を適用して、iPhone / arm64 Simulator用のXCFrameworkと同梱ZIPを生成します。
上流checkoutは未変更の状態を使用します。既存のcheckoutは `SPEECH_CPP_SOURCE`、並列数は `SPEECH_CPP_BUILD_JOBS` で指定できます。

同梱パッチは通常Metal／Metal 4 tensorの明示選択と行列検証、TTSの後続デコード窓128と時間内訳、ASRワーカーの認識間休止、iOS共有MetalバッファのVM確保・解放を追加します。
上流0.8.10の行列カーネルとQ4のfloatスケール処理を使用します。
TTSはF16・4ステップ、ASRはQ4_K・beam／greedyです。性能の測定条件は[計測ガイド](VALIDATION.md)にあります。

## テストとビルド

```sh
swift test -c release
python3 -m unittest discover -s Scripts/tests
bash Scripts/setup.sh --coreml --check
xcodebuild -project Examples/IrodoriSamples.xcodeproj -scheme IrodoriMac -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
bash Scripts/setup.sh --comparison
xcodebuild -project Examples/IrodoriComparison.xcodeproj -scheme IrodoriiOS -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

モデルを使うテストは、次の環境変数を指定すると実行します。未指定なら省略します。

```sh
IRODORI_TEST_MODELS='../Irodori-CoreML-Standard' \
IRODORI_TEST_REFERENCE='./authorized-reference.wav' \
  swift test -c release --filter EngineIntegrationTests
```

AudioSealの実モデルテストには `IRODORI_TEST_WATERMARK_PCM` で48 kHz mono PCM16のヘッダーなしfixtureを指定します。

CIはXcode 27向けランナーでCore ML SDKテスト、配布ツールテスト、Core MLサンプル、同梱ライブラリを使うiPhone / Simulatorアプリのビルドと、ランタイムのソースビルドを確認します。
実音声の録音・再生、Metal推論、RAM、性能は実機で確認してください。

## ソースZIP

```sh
python3 Scripts/export_source.py --destination dist/irodori-tts-iphone-source-0.3.0 --archive dist/irodori-tts-iphone-source-0.3.0.zip
```

新しい出力先を指定します。SDK、追加パッケージ、Xcodeプロジェクト、ビルド・変換・検証ツール、ライセンスを含みます。
検証済みのspeech.cppライブラリZIPとハッシュ情報を含みます。モデル・音声・署名鍵・展開済みランタイム・キャッシュは除外します。
