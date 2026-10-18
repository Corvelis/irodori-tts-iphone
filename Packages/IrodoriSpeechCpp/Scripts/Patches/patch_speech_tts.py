"""Add TTS kernel validation and existing stage timings to the staged runtime."""
from pathlib import Path
import argparse
import shutil


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    root = args.source
    engine = root / 'src/engines/irodori-tts-engine.cpp'
    source = engine.read_text()
    before = '        synth_.synthesize(r, voices_.at(values.string(SPEECH_OPT_VOICE)), [&](const float * samples, size_t n) { return run.audio(samples, n); });'
    after = '''        stackchan_tts_stats = {};
        stackchan_tts_margin = synth_.codec().decoder_margin();
        stackchan_tts_flash = synth_.attention() == irodori::Attention::Flash;
        synth_.synthesize(r, voices_.at(values.string(SPEECH_OPT_VOICE)), [&](const float * samples, size_t n) { return run.audio(samples, n); }, &stackchan_tts_stats);'''
    if source.count(before) != 1:
        raise ValueError('The pinned Irodori engine does not match the timing patch')
    source = source.replace(before, after, 1)
    source = 'extern "C" int stackchan_speech_tts_decoder_window();\n' + source.replace('namespace {', '''namespace {
thread_local irodori::Stats stackchan_tts_stats;
thread_local int stackchan_tts_margin = 0;
thread_local bool stackchan_tts_flash = false;''', 1)
    source += '''
extern "C" __attribute__((visibility("default")))
int stackchan_speech_tts_stats(char *report, size_t capacity) {
    const auto &s = stackchan_tts_stats;
    std::snprintf(report, capacity,
        "{\\"textEncoderMs\\":%.9g,\\"ditSamplingMs\\":%.9g,\\"decoderMs\\":%.9g,\\"latentFrames\\":%d,\\"textTokens\\":%d,\\"decoderWindowFrames\\":%d,\\"decoderMarginFrames\\":%d,\\"flashAttention\\":%d}",
        s.text * 1000, s.sampling * 1000, s.codec * 1000, s.frames, s.tokens,
        stackchan_speech_tts_decoder_window(), stackchan_tts_margin, stackchan_tts_flash ? 1 : 0);
    return 0;
}
'''
    engine.write_text(source)
    synthesizer = root / 'src/families/irodori-tts/synthesizer.cpp'
    source = synthesizer.read_text()
    before = 'return next_window(rule, p);'
    if source.count(before) != 1:
        raise ValueError('The pinned Irodori decoder does not match the window patch')
    source = 'extern "C" int stackchan_speech_tts_decoder_window();\n' + source.replace(
        before, '''// Keep the first 12 frames; enlarge subsequent windows to avoid
            // repeatedly decoding their identical receptive-field context.
            const int window = stackchan_speech_tts_decoder_window();
            return window > 0 && p.frames_done > 0
                ? (int) std::min<int64_t>(window, p.frames_left)
                : next_window(rule, p);''', 1)
    synthesizer.write_text(source)
    policy = root / 'src/families/irodori-tts/stackchan-decoder-policy.cpp'
    policy.write_text('''namespace {
thread_local int decoder_window = 0;
}
extern "C" __attribute__((visibility("default")))
void stackchan_speech_tts_set_decoder_window(int frames) { decoder_window = frames; }
extern "C" int stackchan_speech_tts_decoder_window() { return decoder_window; }
''')
    shutil.copyfile(Path(__file__).with_name('tts_metal_check.cpp'),
                    root / 'src/api/stackchan-tts-metal-check.cpp')
    with (root / 'CMakeLists.txt').open('a') as stream:
        stream.write('''
target_sources(speech PRIVATE src/api/stackchan-tts-metal-check.cpp)
target_sources(irodoritts PRIVATE src/families/irodori-tts/stackchan-decoder-policy.cpp)
target_link_options(speech PRIVATE "LINKER:-exported_symbol,_stackchan_speech_tts_metal_check" "LINKER:-exported_symbol,_stackchan_speech_tts_stats" "LINKER:-exported_symbol,_stackchan_speech_tts_set_decoder_window")
''')
    print('Staged TTS matrix validation and stage timings.')


if __name__ == '__main__':
    main()
