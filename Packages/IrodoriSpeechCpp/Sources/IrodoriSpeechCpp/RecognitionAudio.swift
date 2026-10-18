import Foundation
import AVFoundation
import IrodoriTTS

public enum RecognitionAudio {
    /// Decode at most 60 seconds to 16 kHz mono PCM16. No microphone or speech-service permission is needed for files.
    public static func read(_ url: URL) throws -> Data {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= 256 * 1024 * 1024 else {
            throw IrodoriError.invalid("音声ファイルは256 MB以内にしてください。")
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let seconds = Double(file.length) / format.sampleRate
        guard format.channelCount <= 2, format.sampleRate <= 192_000,
              seconds.isFinite, seconds >= 0.16, seconds <= 60 else {
            throw IrodoriError.invalid("音声は0.16〜60秒のファイルを選んでください。")
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let target = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(seconds * 16_000)) + 4096),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw IrodoriError.invalid("音声を変換できません。")
        }
        try file.read(into: source)
        var consumed = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard let samples = target.floatChannelData?[0], target.frameLength > 0, target.frameLength <= 960_000 else {
            throw IrodoriError.invalid("変換した音声が空か、60秒を超えています。")
        }
        var pcm = Data(count: Int(target.frameLength) * 2)
        try pcm.withUnsafeMutableBytes { output in
            for index in 0..<Int(target.frameLength) {
                guard samples[index].isFinite else { throw IrodoriError.invalid("音声に無効な値が含まれています。") }
                let sample = Int16(max(-32768, min(32767, (Double(samples[index]) * 32768).rounded())))
                output.storeBytes(of: sample.littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return pcm
    }
}
