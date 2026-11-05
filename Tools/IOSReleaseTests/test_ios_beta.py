import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('ios_beta', Path(__file__).parents[1] / 'ios_beta.py')
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)


class BetaChecks(unittest.TestCase):
    def test_shipped_icon_has_no_alpha_channel(self):
        path = beta.ROOT / 'iOS/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png'
        beta.validate_icon(path)
        with tempfile.TemporaryDirectory() as temp:
            invalid = Path(temp) / 'alpha.png'
            data = bytearray(path.read_bytes()); data[25] = 6
            invalid.write_bytes(data)
            with self.assertRaises(beta.BetaError): beta.validate_icon(invalid)

    def test_versions_reject_reused_shape_and_injected_arguments(self):
        self.assertEqual(beta.version_pair('1.1.0', '101'), ('1.1.0', '101'))
        for version, build in [('1.1', '1'), ('1.1.0', '0'), ('1.1.0', '1; echo bad'), ('1.1.0', '1000000000')]:
            with self.assertRaises(beta.BetaError): beta.version_pair(version, build)

    def test_target_signatures_must_match_version_team_and_group(self):
        info = {'CFBundleIdentifier': beta.APP, 'CFBundleShortVersionString': '1.1.0',
                'CFBundleVersion': '101', 'MinimumOSVersion': '18.0'}
        entitlements = {'application-identifier': beta.TEAM + '.' + beta.APP,
                        'com.apple.developer.team-identifier': beta.TEAM,
                        'com.apple.security.application-groups': [beta.GROUP], 'get-task-allow': False}
        self.assertEqual(beta.validate_bundle(info, entitlements, '1.1.0', '101', distribution=True), beta.APP)
        for key, value in [('application-identifier', 'wrong.bundle'),
                           ('com.apple.developer.team-identifier', 'WRONGTEAM'),
                           ('com.apple.security.application-groups', []), ('get-task-allow', True)]:
            with self.assertRaises(beta.BetaError):
                beta.validate_bundle(info, dict(entitlements, **{key: value}), '1.1.0', '101', distribution=True)
        with self.assertRaises(beta.BetaError): beta.validate_bundle(info, entitlements, '1.1.0', '102')

    def test_ipa_path_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp); ipa = directory / 'bad.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive: archive.writestr('../escape', 'not allowed')
            with self.assertRaises(beta.BetaError): beta.unpack_ipa(ipa, directory / 'extract')
            self.assertFalse((directory / 'escape').exists())

    def test_external_or_wrong_app_groups_cannot_receive_build(self):
        connect = object.__new__(beta.Connect)
        def record(internal=True, public=False, app='123'):
            return {'data': {'attributes': {'isInternalGroup': internal, 'publicLinkEnabled': public},
                             'relationships': {'app': {'data': {'id': app}}}}}
        for result in [record(False), record(public=True), record(app='456')]:
            connect.request = lambda *args, value=result: value
            with self.assertRaises(beta.BetaError): connect.internal_group('123', 'group')
        connect.request = lambda *args: record()
        connect.internal_group('123', 'group')


if __name__ == '__main__': unittest.main()
