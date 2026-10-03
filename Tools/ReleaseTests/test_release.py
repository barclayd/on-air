"""Release safety boundaries: no signing credentials, network, or shell execution."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_version_and_prerelease_classification(self):
        self.assertEqual(release.metadata('v1.2.3', '42'),
                         {'tag': 'v1.2.3', 'version': '1.2.3', 'build': '42', 'prerelease': False})
        self.assertTrue(release.metadata('v0.1.0-beta.2', '1')['prerelease'])
        for tag in ['main', '1.2.3', 'v1.2', 'v01.2.3', 'v1.2.3\n', 'v1.2.3;echo test', '../v1.2.3', 'v1.2.3-beta.0']:
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.metadata(tag, '1')
        for build in ['0', '-1', '10000', '1\n', '1.2']:
            with self.subTest(build=build), self.assertRaises(release.ReleaseError):
                release.metadata('v1.2.3', build)

    def test_missing_credentials_fails_before_build_or_output(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {}, clear=True), patch.object(release, 'run') as run:
            destination = Path(folder) / 'output'
            with self.assertRaisesRegex(release.ReleaseError, 'Missing release configuration'):
                release.build_package('v1.2.3', '1', destination)
            run.assert_not_called()
            self.assertFalse(destination.exists())

    def test_archive_validation_rejects_wrong_version_architecture_and_test_bridge(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder)
            (app / 'Contents').mkdir()
            info = {'CFBundleIdentifier': 'com.danbarclay.onair', 'CFBundleShortVersionString': '1.2.3',
                    'CFBundleVersion': '2', 'LSUIElement': True}
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            expected = release.metadata('v1.2.3', '2')
            for architectures, symbols, accepted in [(b'arm64 x86_64', b'production', True),
                                                       (b'arm64', b'production', False),
                                                       (b'arm64 x86_64', b'EndToEndBridge', False)]:
                results = [subprocess.CompletedProcess([], 0, architectures), subprocess.CompletedProcess([], 0, symbols)]
                with self.subTest(architectures=architectures, symbols=symbols), patch.object(release, 'run', side_effect=results):
                    if accepted:
                        release.verify_app(app, expected)
                    else:
                        with self.assertRaises(release.ReleaseError):
                            release.verify_app(app, expected)
            with self.assertRaisesRegex(release.ReleaseError, 'identity/version'):
                release.verify_app(app, release.metadata('v9.9.9', '2'))

    def test_identity_rejects_development_wrong_team_and_ambiguity(self):
        identity = 'A' * 40
        correct = f'1) {identity} "Developer ID Application: Example (ABCDE12345)"'
        self.assertEqual(release.developer_identity(correct, 'ABCDE12345'), identity)
        for output in [correct.replace('Developer ID Application', 'Apple Development'), correct.replace('ABCDE12345', 'OTHER12345'), correct + '\n' + correct]:
            with self.assertRaises(release.ReleaseError):
                release.developer_identity(output, 'ABCDE12345')

    def test_child_tools_do_not_inherit_secrets_and_errors_do_not_print_argv(self):
        with patch.dict(os.environ, {'APPLE_CERTIFICATE_PASSWORD': 'secret-pass', 'OPENAI_API_KEY': 'test-secret', 'GH_TOKEN': 'test-token'}):
            environment = release.child_environment()
            self.assertNotIn('APPLE_CERTIFICATE_PASSWORD', environment)
            self.assertNotIn('OPENAI_API_KEY', environment)
            self.assertNotIn('GH_TOKEN', environment)
            with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'')):
                with self.assertRaises(release.ReleaseError) as error:
                    release.run('Import certificate', ['security', '-P', 'secret-pass'])
                self.assertNotIn('secret-pass', str(error.exception))

    def test_only_explicit_accepted_notarization_succeeds(self):
        environment = {'APPLE_NOTARY_KEY_ID': 'fixture', 'APPLE_NOTARY_ISSUER_ID': 'fixture'}
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, environment):
            for status, code, accepted in [('Accepted', 0, True), ('Invalid', 0, False), ('In Progress', 0, False), ('Accepted', 1, False)]:
                with self.subTest(status=status, code=code), patch.object(release, 'run', return_value=subprocess.CompletedProcess([], code, json.dumps({'status': status}).encode())):
                    if accepted:
                        release.notarize('app.zip', 'key.p8', Path(folder), 'app')
                    else:
                        with self.assertRaises(release.ReleaseError):
                            release.notarize('app.zip', 'key.p8', Path(folder), 'app')
            with patch.object(release, 'run', return_value=subprocess.CompletedProcess([], 0, b'not json')):
                with self.assertRaises(release.ReleaseError):
                    release.notarize('app.zip', 'key.p8', Path(folder), 'app')

    def test_temporary_keychain_removed_when_signing_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            environment = {k: 'fixture' for k in release.CREDENTIALS}
            environment.update({'RUNNER_TEMP': folder, 'APPLE_TEAM_ID': 'ABCDE12345',
                                'APPLE_CERTIFICATE_P12_BASE64': base64.b64encode(b'fake p12').decode(),
                                'APPLE_NOTARY_KEY_P8_BASE64': base64.b64encode(b'fake p8').decode()})
            commands = []
            def fake_run(label, arguments, **kwargs):
                commands.append(arguments)
                if arguments[1] == 'create-keychain':
                    Path(arguments[-1]).touch()
                if arguments[1] == 'find-identity':
                    return subprocess.CompletedProcess([], 0, ('A' * 40 + ' "Developer ID Application: Fixture (ABCDE12345)"').encode())
                return subprocess.CompletedProcess([], 0, b'')
            with patch.dict(os.environ, environment), patch.object(release, 'run', side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, 'simulated signing error'):
                    with release.signing_assets():
                        raise RuntimeError('simulated signing error')
            self.assertTrue(any(command[1] == 'delete-keychain' for command in commands))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_unsigned_wrong_commit_and_tampered_artifacts_cannot_publish(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            name = 'On-Air-v1.2.3.dmg'
            data = b'fixture DMG bytes'
            digest = hashlib.sha256(data).hexdigest()
            (directory / name).write_bytes(data)
            (directory / (name + '.sha256')).write_text(digest + '  ' + name + '\n')
            good = {**release.metadata('v1.2.3', '1'), 'signed_notarized': True, 'file': name, 'sha256': digest, 'commit': 'source-commit'}
            manifest = directory / 'release.json'
            manifest.write_text(json.dumps(good))
            self.assertEqual(release.verify_publishable(directory, 'v1.2.3', 'source-commit'), good)
            for key, value in [('signed_notarized', False), ('commit', 'other'), ('tag', 'v9.9.9'), ('file', '../outside.dmg'), ('prerelease', True), ('sha256', '0' * 64)]:
                manifest.write_text(json.dumps({**good, key: value}))
                with self.subTest(key=key), self.assertRaises(release.ReleaseError):
                    release.verify_publishable(directory, 'v1.2.3', 'source-commit')
            manifest.write_text(json.dumps(good))
            (directory / name).write_bytes(b'changed after hashing')
            with self.assertRaisesRegex(release.ReleaseError, 'checksum'):
                release.verify_publishable(directory, 'v1.2.3', 'source-commit')

    def test_rejected_notarization_never_creates_release_receipt_or_dmg(self):
        with tempfile.TemporaryDirectory() as folder:
            def fake_run(label, arguments, **kwargs):
                if arguments[0] == 'xcodebuild':
                    archive = Path(arguments[arguments.index('-archivePath') + 1])
                    (archive / 'Products/Applications/On Air.app').mkdir(parents=True)
                return subprocess.CompletedProcess([], 0, b'')
            with patch.object(release, 'require_credentials'), patch.object(release, 'verify_app'), \
                 patch.object(release, 'run', side_effect=fake_run), \
                 patch.object(release, 'signing_assets') as signing, patch.object(release, 'create_dmg') as dmg, \
                 patch.object(release, 'notarize', side_effect=release.ReleaseError('Rejected')):
                signing.return_value.__enter__.return_value = ('keychain', 'identity', 'key.p8')
                with self.assertRaisesRegex(release.ReleaseError, 'Rejected'):
                    release.build_package('v1.2.3', '1', folder)
                dmg.assert_not_called()
                self.assertFalse((Path(folder) / 'dist/release.json').exists())


if __name__ == '__main__':
    unittest.main()
