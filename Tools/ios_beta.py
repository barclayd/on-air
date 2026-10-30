#!/usr/bin/env python3
"""Archive, verify and distribute the internal iPhone beta. Never publishes to the App Store."""
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TEAM = 'R2GGK3VN2C'
GROUP = 'group.com.danbarclay.onair.ios'
APP = 'com.danbarclay.onair.ios'
TARGETS = {APP: 'APP', APP + '.keyboard': 'KEYBOARD', APP + '.activities': 'ACTIVITY'}


class BetaError(Exception):
    pass


def run(arguments, log=None, env=None):
    result = subprocess.run([str(a) for a in arguments], cwd=ROOT, env=env, capture_output=True)
    if log:
        Path(log).write_bytes(result.stdout + result.stderr)
    if result.returncode:
        # Do not print credentials, arguments, provider response bodies or raw auth errors.
        raise BetaError(f'{Path(str(arguments[0])).name} failed' + (f'; see {log}' if log else ''))
    return result.stdout


def version_pair(version, build):
    if not re.fullmatch(r'[1-9]\d*\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d{0,8}', build):
        raise BetaError('Use a semantic version and a new positive numeric build (at most nine digits)')
    return version, build


def validate_bundle(info, entitlements, version, build, *, distribution=False):
    identifier = info.get('CFBundleIdentifier')
    if identifier not in TARGETS:
        raise BetaError('Unexpected bundle in beta archive')
    if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (version, build):
        raise BetaError('App and extension version/build must match')
    if entitlements.get('com.apple.developer.team-identifier') != TEAM:
        raise BetaError('Unexpected signing team')
    if entitlements.get('application-identifier') != TEAM + '.' + identifier:
        raise BetaError('Signing identity does not match bundle')
    if entitlements.get('com.apple.security.application-groups') != [GROUP]:
        raise BetaError('Missing or unexpected App Group')
    if distribution and entitlements.get('get-task-allow', False):
        raise BetaError('Development signature cannot be distributed through TestFlight')
    if float(info.get('MinimumOSVersion', '0').split('.')[0]) < 18:
        raise BetaError('Unexpected deployment target')
    return identifier


def verify_app(app, version, build, distribution=False):
    records = []
    bundles = [app] + sorted((app / 'PlugIns').glob('*.appex'))
    if len(bundles) != 3:
        raise BetaError('Expected the app, keyboard and activity extension only')
    for bundle in bundles:
        run(['codesign', '--verify', '--strict', bundle])
        entitlements = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', bundle]))
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        identifier = validate_bundle(info, entitlements, version, build, distribution=distribution)
        profile = plistlib.loads(run(['security', 'cms', '-D', '-i', bundle / 'embedded.mobileprovision']))
        if TEAM not in profile.get('TeamIdentifier', []):
            raise BetaError('Provisioning profile belongs to another team')
        if profile['ExpirationDate'].timestamp() <= time.time():
            raise BetaError('Provisioning profile has expired')
        records.append({'bundle': identifier, 'version': version, 'build': build,
                        'entitlements': entitlements, 'profileUUID': profile['UUID'],
                        'sdk': info.get('DTSDKName'), 'sdkBuild': info.get('DTSDKBuild')})
    if {r['bundle'] for r in records} != set(TARGETS):
        raise BetaError('Duplicate or missing target')
    return records


def unpack_ipa(ipa, directory):
    with zipfile.ZipFile(ipa) as archive:
        for name in archive.namelist():
            path = Path(name)
            if path.is_absolute() or '..' in path.parts:
                raise BetaError('Unsafe IPA member')
        archive.extractall(directory)
    apps = list((directory / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise BetaError('IPA must contain exactly one app')
    return apps[0]


def required(name):
    value = os.environ.get(name, '').strip()
    if not value:
        raise BetaError(f'Missing {name}')
    return value


def secret_file(directory, name, variable):
    path = directory / name
    try:
        data = base64.b64decode(required(variable), validate=True)
    except ValueError as error:
        raise BetaError(f'Invalid encoding for {variable}') from error
    path.write_bytes(data); path.chmod(0o600)
    return path


@contextlib.contextmanager
def signing_material(automatic):
    with tempfile.TemporaryDirectory(prefix='on-air-ios-signing-', dir=os.environ.get('RUNNER_TEMP')) as work:
        directory = Path(work)
        keychain = directory / 'beta.keychain-db'
        installed = []
        original_keychains = None
        try:
            mapping = {}
            if not automatic:
                password = secrets.token_urlsafe(24)
                certificate = secret_file(directory, 'distribution.p12', 'IOS_DISTRIBUTION_P12_BASE64')
                run(['security', 'create-keychain', '-p', password, keychain])
                run(['security', 'set-keychain-settings', '-lut', '21600', keychain])
                run(['security', 'unlock-keychain', '-p', password, keychain])
                run(['security', 'import', certificate, '-k', keychain, '-P', required('IOS_DISTRIBUTION_PASSWORD'),
                     '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
                run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain])
                original_keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
                run(['security', 'list-keychains', '-d', 'user', '-s', keychain, *original_keychains])
                profile_dir = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
                profile_dir.mkdir(parents=True, exist_ok=True)
                for identifier, target in TARGETS.items():
                    source = secret_file(directory, target + '.mobileprovision', f'IOS_{target}_PROFILE_BASE64')
                    profile = plistlib.loads(run(['security', 'cms', '-D', '-i', source]))
                    if profile.get('Entitlements', {}).get('application-identifier') != TEAM + '.' + identifier:
                        raise BetaError(f'{target} provisioning profile does not match its target')
                    destination = profile_dir / (profile['UUID'] + '.mobileprovision')
                    if destination.exists():
                        raise BetaError('Refusing to overwrite an existing provisioning profile; use a clean CI runner')
                    shutil.copyfile(source, destination); installed.append(destination)
                    mapping[identifier] = profile['UUID']
            yield directory, keychain, mapping
        finally:
            if original_keychains is not None:
                subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original_keychains], capture_output=True)
            for profile in installed:
                profile.unlink(missing_ok=True)
            if keychain.exists():
                subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)


class Connect:
    def __init__(self, directory):
        self.key_id = required('APP_STORE_CONNECT_KEY_ID')
        self.issuer = required('APP_STORE_CONNECT_ISSUER_ID')
        self.key = secret_file(directory, f'AuthKey_{self.key_id}.p8', 'APP_STORE_CONNECT_KEY_P8_BASE64')
        self.signer = directory / 'sign-token'
        run(['xcrun', 'swiftc', ROOT / 'Tools/IOS/SignToken.swift', '-o', self.signer])

    def request(self, path, method='GET', body=None):
        token = run([self.signer, self.key, self.key_id, self.issuer]).decode().strip()
        request = urllib.request.Request('https://api.appstoreconnect.apple.com/v1/' + path,
            data=json.dumps(body).encode() if body is not None else None, method=method,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
                return json.loads(data) if data else {}
        except urllib.error.HTTPError as error:
            raise BetaError(f'App Store Connect rejected {method} request (HTTP {error.code})') from error

    def internal_group(self, app_id, group_id):
        group = self.request('betaGroups/' + group_id + '?include=app')['data']
        if not group['attributes'].get('isInternalGroup') or group['attributes'].get('publicLinkEnabled'):
            raise BetaError('Distribution requires an internal group with no public link')
        if group['relationships']['app']['data']['id'] != app_id:
            raise BetaError('Internal group belongs to another app')

    def builds(self, app_id, version, build):
        query = urllib.parse.urlencode({'filter[app]': app_id, 'filter[version]': build,
                                      'filter[preReleaseVersion.version]': version, 'limit': 10})
        return self.request('builds?' + query)['data']

    def wait_and_assign(self, app_id, group_id, version, build, deadline):
        while time.monotonic() < deadline:
            values = self.builds(app_id, version, build)
            if values:
                value = values[0]
                phase = value['attributes']['processingState']
                if phase == 'VALID':
                    self.internal_group(app_id, group_id)
                    self.request('betaGroups/' + group_id + '/relationships/builds', 'POST',
                                 {'data': [{'type': 'builds', 'id': value['id']}]})
                    assigned = self.request('betaGroups/' + group_id + '/builds?limit=200')['data']
                    if not any(item['id'] == value['id'] for item in assigned):
                        raise BetaError('Processed build was not assigned to the internal group')
                    return value['id']
                if phase in ('FAILED', 'INVALID'):
                    raise BetaError('Apple rejected processing; inspect the build in App Store Connect')
            time.sleep(20)
        raise BetaError('Apple is still processing this build; follow its exact version/build in App Store Connect')


def release(arguments):
    version, build = version_pair(arguments.version, arguments.build)
    if run(['git', 'status', '--porcelain', '--untracked-files=no']).strip():
        raise BetaError('Commit tracked changes before building a distributable beta')
    commit = run(['git', 'rev-parse', 'HEAD']).decode().strip()
    output = Path(arguments.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    logs = output / 'logs'; logs.mkdir()
    manifest = {'sourceCommit': commit, 'version': version, 'build': build, 'internalOnly': True,
                'xcode': run(['xcodebuild', '-version']).decode().strip(), 'status': 'building'}
    manifest_file = output / 'build.json'
    def save(): manifest_file.write_text(json.dumps(manifest, indent=2) + '\n')
    save()
    with signing_material(arguments.automatic) as (temporary, keychain, profiles):
        connect = Connect(temporary) if arguments.upload and not arguments.automatic else None
        if connect:
            app_id = required('APP_STORE_CONNECT_APP_ID'); group_id = required('IOS_INTERNAL_GROUP_ID')
            connect.internal_group(app_id, group_id)
            if connect.builds(app_id, version, build):
                raise BetaError('This version/build already exists. Use a new build number.')
        archive = output / 'OnAirPhone.xcarchive'
        command = ['xcodebuild', '-project', 'OnAir.xcodeproj', '-scheme', 'OnAirPhone',
                   '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archive,
                   '-derivedDataPath', output / 'DerivedData', f'MARKETING_VERSION={version}', f'CURRENT_PROJECT_VERSION={build}']
        if arguments.automatic:
            command += ['-allowProvisioningUpdates']
        else:
            command += ['ON_AIR_IOS_SIGNING_STYLE=Manual', 'CODE_SIGN_IDENTITY=Apple Distribution',
                        'OTHER_CODE_SIGN_FLAGS=--keychain ' + str(keychain)]
            command += [f'ON_AIR_{TARGETS[identifier]}_PROFILE={profile}' for identifier, profile in profiles.items()]
        print('Archiving exact source revision', flush=True)
        run(command + ['archive'], logs / 'archive.log')
        app = archive / 'Products/Applications/OnAirPhone.app'
        manifest['archiveTargets'] = verify_app(app, version, build)
        run(['ditto', '-c', '-k', '--keepParent', archive, output / 'OnAirPhone.xcarchive.zip'])
        manifest['archiveSHA256'] = hashlib.file_digest((output / 'OnAirPhone.xcarchive.zip').open('rb'), 'sha256').hexdigest()
        options = {'method': 'app-store-connect', 'destination': 'export', 'teamID': TEAM,
                   'signingStyle': 'automatic' if arguments.automatic else 'manual',
                   'testFlightInternalTestingOnly': True, 'manageAppVersionAndBuildNumber': False,
                   'uploadSymbols': True}
        if profiles:
            options['provisioningProfiles'] = profiles; options['signingCertificate'] = 'Apple Distribution'
        options_path = temporary / 'ExportOptions.plist'; options_path.write_bytes(plistlib.dumps(options))
        export = output / 'export'
        export_command = ['xcodebuild', '-exportArchive', '-archivePath', archive,
                          '-exportOptionsPlist', options_path, '-exportPath', export]
        if arguments.automatic: export_command += ['-allowProvisioningUpdates']
        print('Exporting internal-only beta', flush=True)
        run(export_command, logs / 'export.log')
        ipas = list(export.glob('*.ipa'))
        if len(ipas) != 1: raise BetaError('Expected exactly one exported IPA')
        ipa = ipas[0]
        unpacked = temporary / 'unpacked'
        manifest['targets'] = verify_app(unpack_ipa(ipa, unpacked), version, build, distribution=True)
        manifest['ipaSHA256'] = hashlib.file_digest(ipa.open('rb'), 'sha256').hexdigest()
        (output / 'OnAirPhone.ipa.sha256').write_text(manifest['ipaSHA256'] + '  export/' + ipa.name + '\n')
        manifest['status'] = 'exported'; save()
        if arguments.upload:
            print('Uploading beta; this does not yet mean it is available to testers', flush=True)
            if connect:
                environment = dict(os.environ, API_PRIVATE_KEYS_DIR=str(temporary))
                authentication = ['--apiKey', connect.key_id, '--apiIssuer', connect.issuer]
                run(['xcrun', 'altool', '--validate-app', '-f', ipa, '-t', 'ios', *authentication], logs / 'validate.log', environment)
                run(['xcrun', 'altool', '--upload-app', '-f', ipa, '-t', 'ios', *authentication], logs / 'upload.log', environment)
            else:
                options['destination'] = 'upload'; options_path.write_bytes(plistlib.dumps(options))
                run(export_command, logs / 'upload.log')
            manifest['status'] = 'uploaded'; save()
            if connect:
                print('Waiting for Apple processing and internal-group assignment', flush=True)
                manifest['appStoreConnectBuildID'] = connect.wait_and_assign(app_id, group_id, version, build, time.monotonic() + 1800)
                manifest['appStoreConnectAppID'] = app_id
                manifest['internalGroupID'] = group_id
                manifest['status'] = 'assigned-internal-group'; save()
    print('Beta status: ' + manifest['status'], flush=True)
    print('Manifest: ' + str(manifest_file), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--automatic', action='store_true', help='Use the signed-in local Xcode account instead of CI signing secrets')
    parser.add_argument('--upload', action='store_true', help='Upload internal-only; automatic mode requires checking processing/group access in App Store Connect')
    try:
        release(parser.parse_args())
    except (BetaError, OSError, ValueError) as error:
        raise SystemExit(str(error))
