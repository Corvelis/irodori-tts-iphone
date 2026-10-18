"""Package and verify the bundled iPhone/Simulator speech.cpp runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = Path('Packages/IrodoriSpeechCpp')
ARCHIVE = PACKAGE / 'Artifacts/SpeechCpp.xcframework.zip'
MANIFEST = PACKAGE / 'Artifacts/runtime.json'
SPEECH_REVISION = 'a72f1bbedd50e293d5b3f4c2bf0fb44ec003227d'
GGML_REVISION = 'a655cf6910770404213bc338e622cd82b08ca277'
SLICES = ('ios-arm64', 'ios-arm64-simulator')
FRAMEWORK_FILES = ('Headers/speech.h', 'Headers/SpeechCppBuild.h', 'Info.plist',
                   'Modules/module.modulemap', 'SpeechCpp')
EXPECTED = {'SpeechCpp.xcframework/Info.plist'} | {
    f'SpeechCpp.xcframework/{slice}/SpeechCpp.framework/{file}'
    for slice in SLICES for file in FRAMEWORK_FILES}
PRIVATE_PATH = re.compile(rb'/(?:Users|home)/[^/\x00\s]+/|/private/(?:tmp|var/folders)/|/var/folders/')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def source_hashes(root):
    package = root / PACKAGE
    files = [package / 'Scripts/build-runtime.sh', root / 'Scripts/package_speech_runtime.py']
    files += sorted((package / 'Scripts/Patches').glob('*.py'))
    return {str(file.relative_to(root)): sha256(file.read_bytes()) for file in files}


def inspect_archive(path):
    """Read the exact framework layout; never extract an unchecked archive."""
    with zipfile.ZipFile(path) as archive:
        if len(archive.infolist()) != len(EXPECTED) or set(archive.namelist()) != EXPECTED:
            raise ValueError('Unexpected files in speech.cpp runtime archive')
        contents = {}
        for entry in archive.infolist():
            if entry.file_size > 20 * 1024 * 1024 or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Invalid runtime archive entry')
            data = archive.read(entry)
            if PRIVATE_PATH.search(data):
                raise ValueError(f'Private build path in runtime: {entry.filename}')
            contents[entry.filename] = data
    metadata = plistlib.loads(contents['SpeechCpp.xcframework/Info.plist'])
    libraries = {row['LibraryIdentifier']: row for row in metadata['AvailableLibraries']}
    if set(libraries) != set(SLICES):
        raise ValueError('Runtime must contain iPhone and Simulator slices')
    for slice in SLICES:
        library = libraries[slice]
        if (library['SupportedArchitectures'] != ['arm64'] or library['SupportedPlatform'] != 'ios'
                or library.get('SupportedPlatformVariant') != ('simulator' if slice.endswith('simulator') else None)):
            raise ValueError('Unexpected runtime platform or architecture')
        prefix = f'SpeechCpp.xcframework/{slice}/SpeechCpp.framework/'
        header = contents[prefix + 'Headers/SpeechCppBuild.h'].decode()
        if SPEECH_REVISION not in header or GGML_REVISION not in header:
            raise ValueError('Runtime does not match the pinned speech.cpp/ggml revisions')
        info = plistlib.loads(contents[prefix + 'Info.plist'])
        if info['CFBundleShortVersionString'] != '0.8.10':
            raise ValueError('Unexpected speech.cpp version')
        # MH_MAGIC_64, CPU_TYPE_ARM64. Link/build tests check the remaining load commands.
        if contents[prefix + 'SpeechCpp'][:8] != bytes.fromhex('cffaedfe0c000001'):
            raise ValueError('Expected an arm64 Mach-O framework')
    return {name: {'bytes': len(data), 'sha256': sha256(data)} for name, data in sorted(contents.items())}


def verify(root=ROOT):
    manifest = json.loads((root / MANIFEST).read_text())
    archive = root / ARCHIVE
    if (manifest['format'] != 'irodori-speechcpp-runtime-v1'
            or manifest['archive'] != str(ARCHIVE)
            or manifest['speechRevision'] != SPEECH_REVISION
            or manifest['ggmlRevision'] != GGML_REVISION):
        raise ValueError('Invalid runtime manifest')
    data = archive.read_bytes()
    if manifest['bytes'] != len(data) or manifest['sha256'] != sha256(data):
        raise ValueError('Runtime archive checksum mismatch')
    if manifest['sourceFiles'] != source_hashes(root):
        raise ValueError('Runtime build scripts changed; rebuild and package the runtime')
    if manifest['files'] != inspect_archive(archive):
        raise ValueError('Runtime file checksums do not match the manifest')
    return manifest


def package(root=ROOT):
    source = root / PACKAGE / 'Frameworks/SpeechCpp.xcframework'
    archive = root / ARCHIVE
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = archive.with_suffix('.tmp.zip')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
            for name in sorted(EXPECTED):
                path = source.parent / name
                if path.is_symlink() or not path.is_file():
                    raise ValueError(f'Missing runtime file: {name}')
                entry = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = ((stat.S_IFREG | (0o755 if path.name == 'SpeechCpp' else 0o644)) << 16)
                output.writestr(entry, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        files = inspect_archive(temporary)
        data = temporary.read_bytes()
        manifest = {'format': 'irodori-speechcpp-runtime-v1', 'archive': str(ARCHIVE),
                    'bytes': len(data), 'sha256': sha256(data), 'speechVersion': '0.8.10',
                    'speechRevision': SPEECH_REVISION, 'ggmlRevision': GGML_REVISION,
                    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines(),
                    'sourceFiles': source_hashes(root), 'files': files}
        temporary.replace(archive)
        (root / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
    finally:
        temporary.unlink(missing_ok=True)
    return verify(root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', action='store_true', help='Verify the bundled archive without rebuilding')
    args = parser.parse_args()
    result = verify() if args.verify else package()
    print(f"speech.cpp {result['speechVersion']}: {result['bytes']} bytes, SHA-256 {result['sha256']}")
