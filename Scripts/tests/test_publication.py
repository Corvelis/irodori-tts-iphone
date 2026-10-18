"""Public-source and Xcode entry-point contracts; no model weights required."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('source_export', ROOT / 'Scripts/export_source.py')
source_export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_export)


class PublicationTests(unittest.TestCase):
    def project(self, name):
        path = ROOT / 'Examples' / (name + '.xcodeproj')
        data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path / 'project.pbxproj')]))
        return path, data['objects']

    def test_coreml_sample_does_not_require_the_optional_binary_package(self):
        _, objects = self.project('IrodoriSamples')
        paths = [o['relativePath'] for o in objects.values() if o['isa'] == 'XCLocalSwiftPackageReference']
        self.assertEqual(paths, ['..'])
        self.assertEqual({o['productName'] for o in objects.values() if o['isa'] == 'XCSwiftPackageProductDependency'}, {'IrodoriTTS'})

    def test_schemes_reference_real_targets_and_diagnostics_is_opt_in(self):
        for name in ['IrodoriSamples', 'IrodoriComparison']:
            directory, objects = self.project(name)
            targets = {key for key, value in objects.items() if value['isa'] == 'PBXNativeTarget'}
            for scheme in (directory / 'xcshareddata/xcschemes').glob('*.xcscheme'):
                xml = ET.parse(scheme)
                for ref in xml.findall('.//BuildableReference'):
                    self.assertIn(ref.attrib['BlueprintIdentifier'], targets)
            for obj in objects.values():
                if obj['isa'] != 'XCBuildConfiguration':
                    continue
                settings = obj['buildSettings']
                enabled = 'IRODORI_SAMPLE_DIAGNOSTICS' in str(settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ''))
                if enabled:
                    self.assertEqual(name, 'IrodoriComparison')
                    self.assertEqual(obj['name'], 'Diagnostics')
                if 'MARKETING_VERSION' in settings:
                    self.assertEqual(settings['MARKETING_VERSION'], (ROOT / 'VERSION').read_text().strip())

    def test_export_keeps_entry_points_and_omits_local_data(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'source'
            paths = ['VERSION', 'Scripts/setup.sh', 'Examples/Demo.app/private',
                     'Packages/Local.xcframework/binary', 'Sources/.env.development',
                     'Sources/.build/cache', 'Examples/xcuserdata/private']
            for name in paths:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('test')
            destination = Path(folder) / 'export'
            with patch.object(source_export, 'ROOT', root):
                source_export.export(destination)
            actual = {str(p.relative_to(destination)) for p in destination.rglob('*') if p.is_file()}
            self.assertEqual(actual, {'VERSION', 'Scripts/setup.sh'})

    def test_export_refuses_model_weights_and_signing_keys(self):
        for name in ['personal.p12', 'AuthKey.p8', 'private.key', 'model.gguf']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                root = Path(folder) / 'source'
                path = root / 'Sources' / name; path.parent.mkdir(parents=True); path.write_bytes(b'private')
                destination = Path(folder) / 'export'
                with patch.object(source_export, 'ROOT', root), self.assertRaises(ValueError):
                    source_export.export(destination)
                self.assertFalse(destination.exists())


if __name__ == '__main__':
    unittest.main()
