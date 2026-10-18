"""Pause FastConformer's kept CPU workers between complete recognitions."""
from pathlib import Path
import argparse


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    root = parser.parse_args().source
    file = root / 'src/families/fastconformer/recognizer.cpp'
    source = file.read_text()
    before = '    return copy.transducer.decoder(name).decode(projected, copy.backend.get(), progress);'
    after = '''    const Decoding result = copy.transducer.decoder(name).decode(projected, copy.backend.get(), progress);
    // The next graph resumes the pool. Poll between small decoding graphs, but
    // sleep while the app is idle or the next encoder is running on Metal.
    if (stackchan_speech_asr_pause_cpu()) ggml_threadpool_pause(copy.pool.get());
    return result;'''
    if source.count(before) != 1:
        raise ValueError('The pinned FastConformer does not match the CPU idle patch')
    source = 'extern "C" bool stackchan_speech_asr_pause_cpu();\n' + source.replace(before, after, 1)
    file.write_text(source)
    helper = root / 'src/families/fastconformer/stackchan-cpu-policy.cpp'
    helper.write_text('''namespace {
thread_local bool pause_cpu = false;
}
extern "C" bool stackchan_speech_asr_pause_cpu() { return pause_cpu; }
extern "C" __attribute__((visibility("default")))
void stackchan_speech_asr_set_pause_cpu(int enabled) { pause_cpu = enabled != 0; }
''')
    with (root / 'CMakeLists.txt').open('a') as stream:
        stream.write('''
target_sources(fastconformer PRIVATE src/families/fastconformer/stackchan-cpu-policy.cpp)
target_link_options(speech PRIVATE "LINKER:-exported_symbol,_stackchan_speech_asr_set_pause_cpu")
''')
    print('Staged CPU worker sleep between recognitions; decoding graphs keep upstream polling.')


if __name__ == '__main__':
    main()
