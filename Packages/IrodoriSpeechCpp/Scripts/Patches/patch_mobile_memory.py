"""Use page-backed VM storage for owned shared Metal buffers on physical iOS."""
from pathlib import Path
import argparse


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    root = parser.parse_args().source
    file = root / 'ggml/src/ggml-metal/ggml-metal-device.m'
    source = file.read_text()
    edits = [
        ('#include <stdatomic.h>', '#include <stdatomic.h>\n#include <mach/mach.h>'),
        ('#if TARGET_OS_OSX\n    kern_return_t err = vm_allocate',
         '#if TARGET_OS_OSX || (TARGET_OS_IOS && !TARGET_OS_SIMULATOR)\n    kern_return_t err = vm_allocate'),
        ('#if TARGET_OS_OSX\n        vm_deallocate',
         '#if TARGET_OS_OSX || (TARGET_OS_IOS && !TARGET_OS_SIMULATOR)\n        vm_deallocate'),
    ]
    # Match both allocation and disposal together. No change to model bytes,
    # Metal storage mode, graph scheduling or the existing macOS allocation path.
    for before, after in edits:
        if source.count(before) != 1:
            raise ValueError('The pinned Metal allocator does not match the iOS VM patch')
        source = source.replace(before, after, 1)
    file.write_text(source)
    print('Staged iOS shared Metal VM allocation and matching deallocation.')


if __name__ == '__main__':
    main()
