# Irodori TTS for iPhoneの使い方

[README](../README.md) · [SDK導入](GETTING_STARTED.md) · [音声登録](VOICE_REGISTRATION.md) · [困ったとき](TROUBLESHOOTING.md)

## ビルドして起動する

ソースを取得するかプロジェクトZIPを展開し、使うXcodeプロジェクトを直接開きます。セットアップコマンドは不要です。

| 用途 | プロジェクト | Scheme |
| --- | --- | --- |
| iPhoneのCore ML / speech.cpp比較・ASR | `Examples/IrodoriComparison.xcodeproj` | `IrodoriiOS` |
| Core MLだけのiPhone / Macサンプル | `Examples/IrodoriSamples.xcodeproj` | `IrodoriiOS` / `IrodoriMac` |

アプリを試す場合は、上のプロジェクトを開くだけで依存ライブラリが読み込まれます。

### 初回のXcodeとiPhoneの準備

1. Xcodeを初めて使う場合は一度起動し、追加コンポーネントの取得を完了します。実行先の横にiOS用の **Get** が出た場合は取得します。
2. **Xcode → Settings → Apple Accounts** で自分のApple Accountにサインインします。バージョンによっては **Accounts** と表示されます。
3. iPhoneをケーブルでMacへ接続し、ロックを解除します。信頼の確認が表示されたら、MacとiPhoneの案内に従ってペアリングします。
4. iPhoneの **設定 → プライバシーとセキュリティ → デベロッパモード** をオンにし、再起動後の確認を完了します。項目が出ない場合は、先にXcodeからiPhoneとのペアリングを開始してください。

端末の準備については[Appleの実機実行ガイド](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)と[開発者モードの説明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)も参照できます。

### 署名を設定してRunする

1. Xcode左側のプロジェクト名を選び、中央の **TARGETS → IrodoriiOS → Signing & Capabilities** を開きます。
2. **Automatically manage signing** をオンにし、**Team** に自分のチームを選びます。Personal Teamを使う場合の条件は[Appleのアカウント案内](https://developer.apple.com/help/account/basics/about-your-developer-account)を確認してください。
3. **Bundle Identifier** を、自分用の一意な値へ変更します。例えば `com.example.yourname.irodori` の `yourname` を自分の識別子に置き換えます。
4. 上部のschemeを **IrodoriiOS**、Run Destinationを接続したiPhoneにし、**Run（⌘R）** を押します。初回の署名・端末登録の確認が表示されたら、Xcodeの案内に従います。

Core MLのMacサンプルではtargetとschemeを **IrodoriMac**、実行先を **My Mac** にします。
比較アプリのspeech.cpp推論には実機iPhoneが必要です。Simulatorでは画面を確認できます。

速度を比較する場合は **Product → Scheme → Edit Scheme… → Run → Info → Build Configuration** を **Release** にします。
起動後のモデル取得と最初の生成は、次の手順で行います。

画面はiPhoneで縦並び、広いMacウィンドウで2列になります。モデルはアプリから別途取得します。

## 最初の音声を生成する

1. 比較アプリではCore MLまたはspeech.cppを選びます。
2. 「モデル」で使用するモデルを選び、「モデルをダウンロード」を押します。取得済みなら「フォルダを選ぶ」で一式を取り込めます。
3. 「声と話し方」は参照なし、話し方の指示は空欄のまま、「生成して再生」を押します。
4. 準備・生成が終わると再生が始まり、生成時間・音声長・RTF・RAMが表示されます。

モデルの「準備」は任意です。「生成して再生」でも必要な準備を行います。
同じ方式・モデルでの連続生成はロード済みモデルを再利用します。「もう一度再生」にはモデルのロードも再生成も必要ありません。

## モデルの取得・切替・削除

Core MLは現行版／軽量INT8版、speech.cppはF16 GGUFとAudioSealを取得します。
Wi-Fiで取得し、ファイルサイズとSHA-256を検証します。中断後は検証済みの完成ファイルを再利用し、未完了ファイルは取り直します。
ダウンロード中はアプリを開いた状態にしてください。

Core MLモデルをFilesから取り込む場合は、`manifest.json` と `.mlpackage` が並ぶ親フォルダを選びます。
[モデルの配置](HUGGINGFACE.md)を参照してください。選択した一式をアプリ内へコピーするため、原本に加えてコピー・コンパイルキャッシュ分の容量が必要です。

「保存済みモデル」で取得済みの版を選択できます。方式・モデルを切り替えると保持中のモデルを解放し、次の生成で選択したモデルをロードします。
参照音声・話し方の指示と、保存済みの方式別WAVは保持します。

「モデルを解放」はRAM内の推論モデルを解放します。「モデルを削除」はアプリ内のモデルファイルを削除します。
保存済みWAVはその後も再生できます。軽量INT8版にはiOS 18 / macOS 15以降が必要です。

## 声・話し方を指定する

1. 参照音声を使う場合は「利用できる声を登録」をオンにします。
2. 「音声を選ぶ」でファイルを取り込むか、「録音する」で3〜10秒程度話して「録音を停止」を押します。
3. 「生成して再生」で、選択した参照を使って生成します。「準備」で先に参照特徴を用意することもできます。

話し方の欄には「落ち着いた、やさしい話し方。」など短い日本語の指示を入力できます。参照音声あり・なしの両方で利用でき、空欄で無効です。
使用許可のある明瞭な1人の音声を使ってください。登録は1つずつ選択します。

「登録音声とキャッシュを削除」でアプリが持つ録音・取り込みコピーと特徴キャッシュを削除します。
選択元の音声、モデル、生成WAVは残ります。登録音声と指示は保存され、声の許可スイッチは起動ごとに確認します。
保存場所とSDKの削除APIは[音声登録ガイド](VOICE_REGISTRATION.md)にあります。

## 再生・保存・比較

「生成して再生」は入力全体を1回で合成し、完成したWAVを再生します。
再生欄で一時停止・再開・再生し直しができます。「WAVを保存」はiPhoneの共有画面、Macの保存ダイアログを開きます。
方式別の最新WAVは次の生成成功で上書きされるため、残す音声は別の場所へ保存してください。

比較アプリで両モデルを取得すると「両方式で生成して比較」を使えます。
Core MLの生成・保存・解放後にspeech.cppをロードして生成します。完了後に両モデルを解放し、選択中の方式のWAVを再生します。
「生成結果」には選択中の方式だけを表示し、方式を切り替えるとその保存結果に切り替わります。結果は再起動後も復元します。

同じseedでも方式間で波形や音声長は一致しません。それぞれのWAVを聴き比べてください。

「停止」は再生を止め、合成Taskをキャンセルします。実行中の処理の終了を待つ場合があります。
本文がモデルの上限（BOSを含む256トークン、潜在系列768フレーム）を超えたら、短くして再生成してください。
SDKの文分割・チャンク通知は[独自アプリ向けの再生例](STREAMING.md)にあります。

## 計測値を読む

| 表示 | 意味 |
| --- | --- |
| ロード | モデルの準備時間。同じモデルを保持中なら0 ms・再利用 |
| 参照 | 音声読込・変換と参照特徴の準備時間。再利用時はキャッシュ表示 |
| 生成時間 | 音声合成とAudioSeal透かしの処理時間 |
| 音声長 / RTF | 完成音声の長さ / 生成時間÷音声長 |
| 最初のPCM | 最初の音声データが用意されるまでの時間 |
| RAM | アプリ全体physical footprintの現在値・処理中の最大観測値（MiB） |

ロード・参照準備・WAV保存・スピーカー遅延はRTFに含みません。このサンプルは全文完成後に再生するため、最初のPCMと再生開始は異なります。

RAMの現在値は約0.5秒、ロードと推論の最大観測値は約10 ms間隔で計測します。取得失敗は「—」とし、取得回数・エラー数・最大間隔も表示します。
モデル単独の専有RAMではなく、OS・Core ML・Metalのキャッシュを含むアプリ全体の値です。短い増加をサンプル間で取り逃す可能性があります。
方式単独で比較する場合は、アプリを再起動して測定してください。[性能とRAMの計測](VALIDATION.md)に詳しい条件があります。

## 音声認識を試す

比較アプリ右上の耳ボタンでReazonSpeech Q4_Kを任意取得し、録音またはファイルから認識できます。
beam／greedyを選べ、ロード・音声変換・推論時間・RTF・RAMを表示します。TTSとASRは1つずつロードし、認識画面を閉じるとASRモデルを解放します。
[音声認識ガイド](ASR.md)を参照してください。

## サンプルの実装

| ファイル | 役割 |
| --- | --- |
| [ContentView.swift](../Examples/Shared/ContentView.swift) | 文章入力、設定、結果と再生操作 |
| [SampleModel.swift](../Examples/Shared/SampleModel.swift) | モデル管理、参照音声、排他利用、合成・WAV再生・保存 |
| [SampleRecognition.swift](../Examples/Shared/SampleRecognition.swift) | ASRモデル管理、録音・認識 |
| [RecognitionPanel.swift](../Examples/Shared/RecognitionPanel.swift) | 音声認識画面 |
| [PCMPlayer.swift](../Examples/Shared/PCMPlayer.swift) | 独自アプリにチャンク再生を組み込む補助クラス |

[アイコンの差し替え](APP_ICON.md) · [AudioSeal透かし](WATERMARK.md)
