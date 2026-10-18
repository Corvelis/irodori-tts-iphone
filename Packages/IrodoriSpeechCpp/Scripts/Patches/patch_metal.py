"""Expose the pinned upstream Metal 4 kernel on device 1 and simdgroup on device 0."""
from pathlib import Path
import argparse
import shutil


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.destination.resolve():
        raise ValueError('The pinned source must remain separate from the patched copy')
    # A new upstream can delete files. Never retain them from an older staging.
    if args.destination.exists():
        shutil.rmtree(args.destination)
    shutil.copytree(args.source, args.destination,
                    ignore=shutil.ignore_patterns('.git', 'build', '__pycache__'))

    def replace(path: str, before: str, after: str) -> None:
        file = args.destination / path
        source = file.read_text()
        if source.count(before) != 1:
            raise ValueError(f'Pinned source does not match the expected patch: {path}')
        file.write_text(source.replace(before, after, 1))

    # The staging copy has no Git metadata. Do not report the app repository's
    # HEAD as ggml's commit when CMake walks up to the enclosing checkout.
    replace('ggml/CMakeLists.txt', 'if(GIT_EXE)',
            'if(GIT_EXE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")')
    replace('ggml/src/ggml-metal/ggml-metal.cpp', 'static int g_devices = 1;',
            'static int g_devices = 2;')
    replace('ggml/src/ggml-metal/ggml-metal-device.m',
            'if (getenv("GGML_METAL_TENSOR_DISABLE") != NULL) {',
            'if (device == 0 || (device != 1 && getenv("GGML_METAL_TENSOR_DISABLE") != NULL)) {')
    # The pinned fork enables its non-relaxed tensor kernel on A19/M5 and newer.
    # Its partial tiles use threadgroup memory with explicit bounded writes;
    # keep that kernel intact and validate device 1 before using a model.
    metal = args.destination / 'ggml/src/ggml-metal/ggml-metal.cpp'
    with metal.open('a') as stream:
        stream.write('''
extern "C" bool stackchan_ggml_metal_has_tensor(ggml_backend_dev_t dev);
extern "C" bool stackchan_ggml_metal_has_tensor(ggml_backend_dev_t dev) {
    return ggml_metal_device_get_props((ggml_metal_device_t)dev->context)->has_tensor;
}
''')
    shutil.copyfile(Path(__file__).with_name('metal_boundary_check.cpp'),
                    args.destination / 'src/api/stackchan-metal-check.cpp')
    with (args.destination / 'CMakeLists.txt').open('a') as stream:
        stream.write('''
target_sources(speech PRIVATE src/api/stackchan-metal-check.cpp)
target_link_options(speech PRIVATE "LINKER:-exported_symbol,_stackchan_speech_metal_check")
''')
    print('Staged upstream non-relaxed Metal kernels with explicit device validation; pinned sources remain unchanged.')


if __name__ == '__main__':
    main()
