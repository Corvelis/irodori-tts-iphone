import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
import package_speech_runtime as runtime


class RuntimeArchiveTests(unittest.TestCase):
    def copy_package(self, destination):
        paths = [runtime.ARCHIVE, runtime.MANIFEST]
        paths += [Path(name) for name in runtime.source_hashes(ROOT)]
        for path in paths:
            target = destination / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, target)

    def test_bundled_runtime_matches_hashes_revisions_and_platforms(self):
        manifest = runtime.verify(ROOT)
        self.assertLess(manifest['bytes'], 5 * 1024 * 1024)
        self.assertEqual(len(manifest['files']), 11)

    def test_changed_binary_or_build_source_is_rejected(self):
        for tamper in ['binary', 'build-source']:
            with self.subTest(tamper=tamper), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                self.copy_package(root)
                path = root / (runtime.ARCHIVE if tamper == 'binary' else
                               runtime.PACKAGE / 'Scripts/Patches/patch_mobile_memory.py')
                with path.open('ab') as file:
                    file.write(b'changed')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch|build scripts changed'):
                    runtime.verify(root)

    def test_extra_files_and_private_build_paths_are_rejected(self):
        for tamper in ['extra-file', 'private-path']:
            with self.subTest(tamper=tamper), tempfile.TemporaryDirectory() as folder:
                target = Path(folder) / 'runtime.zip'
                with zipfile.ZipFile(ROOT / runtime.ARCHIVE) as source, zipfile.ZipFile(target, 'w') as output:
                    for entry in source.infolist():
                        data = source.read(entry)
                        if tamper == 'private-path' and entry.filename.endswith('/Headers/speech.h'):
                            data += b'\n// /Users/example/private-project/source.cpp\n'
                        output.writestr(entry, data)
                    if tamper == 'extra-file':
                        output.writestr('private.wav', b'not a framework file')
                with self.assertRaisesRegex(ValueError, 'Unexpected files|Private build path'):
                    runtime.inspect_archive(target)

    def test_project_export_includes_verified_runtime_archive(self):
        spec = importlib.util.spec_from_file_location('runtime_export_test', ROOT / 'Scripts/export_source.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'project'
            module.export(target)
            self.assertEqual(runtime.verify(target), runtime.verify(ROOT))
            self.assertFalse((target / runtime.PACKAGE / 'Frameworks').exists())
            self.assertFalse((target / runtime.PACKAGE / '.build').exists())


if __name__ == '__main__':
    unittest.main()
