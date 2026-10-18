# Irodori TTS for iPhone

[日本語](../README.md) · [SDK integration](GETTING_STARTED.md) · [Sample walkthrough](SAMPLES.md)

Generate and listen to Japanese Irodori TTS v4.1 Small MF on iPhone. Switch between Core ML and speech.cpp / Metal, and compare model loading, synthesis, RTF and RAM. The ear button opens optional ReazonSpeech Q4_K recognition.

The repository includes Swift SDKs, sample apps and conversion tools. The Core ML SDK, sample and CLI also support Apple Silicon Mac.

## Run the iPhone comparison app

Use an Apple Silicon Mac with Xcode. Builds have been checked with Xcode 27.0. Clone the repository or extract the project ZIP. The prebuilt speech.cpp library is included; CMake, Ninja, Python and setup commands are unnecessary.

1. On GitHub, choose **Code → Download ZIP** and extract it. The project ZIP from a Release also works.
2. Open **`Examples/IrodoriComparison.xcodeproj`** in Xcode.
3. Connect your iPhone to the Mac, complete pairing/trust prompts, and enable Developer Mode.
4. Select target **IrodoriiOS → Signing & Capabilities**, enable **Automatically manage signing**, select your **Team**, and enter a unique **Bundle Identifier**.
5. Select the **IrodoriiOS** scheme and your connected iPhone as the run destination, then press **Run (⌘R)**.

If no Team is available, sign in under **Xcode → Settings → Apple Accounts**. Follow [Apple's device setup](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) and [Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) for first-time setup. Xcode automatically extracts the bundled library; models are downloaded in the app. For speed comparisons, choose **Product → Scheme → Edit Scheme… → Run → Info → Build Configuration → Release**.

If you prefer Git:

```sh
git clone https://github.com/Corvelis/irodori-tts-iphone.git
cd irodori-tts-iphone
open Examples/IrodoriComparison.xcodeproj
```

Once the app opens, follow these steps. Start with just one model if you prefer.

1. Select Core ML or speech.cpp, then press **モデルをダウンロード**. Core ML offers standard and light INT8 bundles; speech.cpp uses F16.
2. Leave the reference unset and press **生成して再生**. Playback starts when the WAV is complete. Import or record an authorized reference voice to select a voice.
3. **もう一度再生** plays the saved WAV. Repeated synthesis reuses the loaded model. Switching backends releases the previous model first.
4. With both models installed, **両方式で生成して比較** generates sequentially. The result card shows the selected backend; saved backend WAVs survive app restarts.
5. The ear button opens optional ReazonSpeech Q4_K recognition. Download its model and use microphone or file input with beam/greedy decoding. See [ASR usage and API](ASR.md).

Downloads use Wi-Fi and verify file sizes and SHA-256 hashes. Inference works offline after download. RAM is whole-app physical footprint in MiB, sampled at approximately 10 ms during each operation. See [measurement definitions and performance](VALIDATION.md).
speech.cpp inference requires a physical iPhone; Simulator supports UI inspection.

## Video and screenshots

See Core ML and speech.cpp / Metal synthesis and playback, followed by microphone recognition from the ear button.
The video is about 46 seconds long, with Japanese captions and generated speech. Press Play and unmute the player to hear the audio.

https://github.com/user-attachments/assets/85402c9b-d4df-4186-8496-d47dbe176d64

[Open or download the MP4](media/irodori-demo-ja.mp4)

| Core ML · light INT8 | speech.cpp / Metal | Recognition · greedy |
| --- | --- | --- |
| [<img src="media/coreml-result.png" width="220" alt="Core ML synthesis result">](media/coreml-result.png) | [<img src="media/speechcpp-result.png" width="220" alt="speech.cpp Metal synthesis result">](media/speechcpp-result.png) | [<img src="media/asr-result.png" width="220" alt="ReazonSpeech recognition result">](media/asr-result.png) |

## Run the Core ML samples

```sh
open Examples/IrodoriSamples.xcodeproj
```

Choose **IrodoriiOS** for iPhone or **IrodoriMac** for Mac. These samples use only the root Core ML SDK, so CMake, Ninja and the speech.cpp runtime are unnecessary. Both support model downloads, reference recording/import, automatic playback and WAV export. UI labels are Japanese; see [the walkthrough](SAMPLES.md).

## Add the SDKs to your app

| Swift package / product | Features | Integration |
| --- | --- | --- |
| `IrodoriTTS` | Core ML TTS, AudioSeal, model downloads, timing/RAM utilities and exclusive model sessions | Use `https://github.com/Corvelis/irodori-tts-iphone.git` with Exact Version 0.3.0, or add the repository root as a local package. |
| `IrodoriSpeechCpp` | Metal TTS and ReazonSpeech Q4_K recognition | Add `Packages/IrodoriSpeechCpp` as a local package from the complete repository. The runtime is included; keep the repository layout. |

The speech.cpp package depends on the root `IrodoriTTS` package for shared types and AudioSeal. See [integration steps](GETTING_STARTED.md), [Core ML/shared APIs](API.md) and [speech.cpp APIs](../Packages/IrodoriSpeechCpp/README.md).

Keep one engine per active backend and reuse it across requests. Call `prepare`, `registerReference` and `synthesize`; use `registerReference(nil)` for no reference. Call `release()` when finished. Playback and audio-session management belong to the application. For multiple backends, route operations through one `ExclusiveModelSession` to release the previous model before loading another.

## Models and requirements

| Model | Download size | Minimum OS |
| --- | ---: | --- |
| Core ML standard | ~2.99 GB | iOS 17 / macOS 14 |
| Core ML light INT8 | ~1.96 GB | iOS 18 / macOS 15 |
| speech.cpp TTS F16 | ~1.92 GB + AudioSeal | iOS 17, physical iPhone |
| ReazonSpeech Q4_K | ~357 MB | iOS 17, physical iPhone |

The SDKs use Swift tools 5.9+. Models are separate downloads. Core ML bundles are available on [Hugging Face](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML); see [download URLs and layout](HUGGINGFACE.en.md). Allow extra space for app-owned copies and Core ML compilation caches.

TTS output is 48 kHz mono PCM16 WAV. Python and ONNX Runtime are unnecessary for inference. First use includes model compilation/loading. Performance depends on the device, input and thermal state.

Light INT8 compresses text-encoder weight storage while retaining FP32 text computation and outputs. Fixed-width decoder functions share weights. See [model layout](COMPACT_MODELS.en.md) and [quality measurements](QUALITY.en.md).

## Generate audio with the Mac CLI

Run from the source root:

```sh
swift build -c release
.build/release/irodori download --variant standard --destination ../Irodori-CoreML-Standard
.build/release/irodori verify --models ../Irodori-CoreML-Standard
.build/release/irodori synthesize --models ../Irodori-CoreML-Standard --text 'こんにちは。今日はいい天気ですね。' --output ./irodori-output.wav
afplay ./irodori-output.wav
```

Use `--variant light-int8` with a separate destination for the light bundle. Add `--reference ./reference.wav` for a voice reference or `--caption '落ち着いた、やさしい話し方。'` for a speaking-style instruction. See [CLI usage](CLI.md).

## Timing, playback and input limits

RTF is synthesis time divided by output duration. Model loading, reference preparation, WAV saving and physical speaker latency are measured separately. First PCM means audio-data readiness. The sample plays a completed WAV; [chunk playback](STREAMING.md) is available for custom Core ML integrations.

Core ML synthesis splits sentences by default. Use `splitSentences: false` to retain text cleanup while synthesizing the whole input once, as the sample does. speech.cpp also synthesizes one whole input per call. The model limit is 256 text tokens including BOS and 768 latent frames. Shorten inputs that exceed these limits. Both SDKs retain completed PCM even when callbacks are used.

AudioSeal watermarking is enabled by default for both TTS backends and included in synthesis timing. See [watermark APIs and detection](WATERMARK.en.md). Voice references derive speaker features without modifying model weights; see [storage and deletion](VOICE_REGISTRATION.md).

## More documentation

[Performance and RAM](VALIDATION.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Build and test](DEVELOPMENT.md) · [Conversion](CONVERSION.md) · [Compatibility](RELEASE.md) · [Changes](releases/0.3.0.md)

SDK/sample additions are Apache-2.0. Preserve component MIT / Apache-2.0 terms, [notices](../THIRD_PARTY_NOTICES.md) and [model conditions](LICENSE_REVIEW.md). This is a community implementation. Use authorized reference voices and follow the [upstream model's use conditions](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF).
