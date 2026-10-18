#!/usr/bin/env python3
"""Build a universal DMG; only Developer ID + accepted notarization can be published."""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CREDENTIALS = (
    'APPLE_CERTIFICATE_P12_BASE64', 'APPLE_CERTIFICATE_PASSWORD',
    'APPLE_NOTARY_KEY_P8_BASE64', 'APPLE_NOTARY_KEY_ID', 'APPLE_NOTARY_ISSUER_ID',
    'SPARKLE_PRIVATE_KEY',
)
SPARKLE_VERSION = '2.10.0'
SPARKLE_TOOLS_SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
FEED_URL = 'https://github.com/barclayd/on-air/releases/latest/download/appcast.xml'
RELEASE_URL = 'https://github.com/barclayd/on-air/releases/'


class ReleaseError(Exception):
    pass


def metadata(tag, build):
    match = re.fullmatch(r'v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(-(alpha|beta|rc)\.[1-9]\d*)?', tag)
    if not match or not re.fullmatch(r'[1-9]\d{0,3}', build):
        raise ReleaseError('Use vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N] and a build number from 1 to 9999.')
    return {'tag': tag, 'version': match[1], 'build': build, 'prerelease': bool(match[2])}


def child_environment():
    # Build tools have no reason to inherit release credentials or an OpenAI key.
    return {k: v for k, v in os.environ.items() if k not in CREDENTIALS and k not in ('OPENAI_API_KEY', 'GH_TOKEN', 'GITHUB_TOKEN')}


def run(label, arguments, log=None, check=True, input=None):
    print(label, flush=True)
    result = subprocess.run([str(x) for x in arguments], cwd=ROOT, env=child_environment(),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, input=input)
    if log:
        Path(log).write_bytes(result.stdout)
    if check and result.returncode:
        # Never print argv: security commands contain private keychain passwords.
        raise ReleaseError(f'{label} failed (exit {result.returncode}).' + (f' See {log}.' if log else ''))
    return result


def require_credentials():
    missing = [k for k in (*CREDENTIALS, 'APPLE_TEAM_ID') if not os.environ.get(k)]
    if missing:
        raise ReleaseError('Missing release configuration: ' + ', '.join(missing))
    if not re.fullmatch(r'[A-Z0-9]{10}', os.environ['APPLE_TEAM_ID']):
        raise ReleaseError('APPLE_TEAM_ID must be the 10-character Apple team identifier.')


def developer_identity(output, team):
    identities = re.findall(r'\b([A-F0-9]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(team) + r'\)"', output)
    if len(identities) != 1:
        raise ReleaseError('The P12 must contain exactly one valid Developer ID Application identity for APPLE_TEAM_ID.')
    return identities[0]


@contextmanager
def signing_assets():
    require_credentials()
    # A dedicated directory permits the workflow's always() cleanup after cancellation.
    parent = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir()))
    with tempfile.TemporaryDirectory(prefix='on-air-signing-', dir=parent) as directory:
        directory = Path(directory)
        keychain = directory / 'release.keychain-db'
        password = secrets.token_urlsafe(32)
        original_keychains = shlex.split(run('Read keychain search list',
            ['security', 'list-keychains', '-d', 'user']).stdout.decode())
        search_list_changed = False
        try:
            for name, variable in [('certificate.p12', 'APPLE_CERTIFICATE_P12_BASE64'), ('AuthKey.p8', 'APPLE_NOTARY_KEY_P8_BASE64')]:
                try:
                    data = base64.b64decode(''.join(os.environ[variable].split()), validate=True)
                except ValueError:
                    raise ReleaseError(f'{variable} must contain valid base64.') from None
                path = directory / name
                path.write_bytes(data)
                path.chmod(0o600)
            run('Create temporary signing keychain', ['security', 'create-keychain', '-p', password, keychain])
            run('Unlock signing keychain', ['security', 'unlock-keychain', '-p', password, keychain])
            run('Set keychain timeout', ['security', 'set-keychain-settings', '-lut', '7200', keychain])
            run('Import Developer ID certificate', ['security', 'import', directory / 'certificate.p12', '-k', keychain,
                 '-P', os.environ['APPLE_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
            run('Allow noninteractive signing', ['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain])
            # codesign resolves the issuer chain through the search list, even
            # when --keychain selects the private key explicitly.
            search_list_changed = True
            run('Make signing certificate chain discoverable',
                ['security', 'list-keychains', '-d', 'user', '-s', keychain, *original_keychains])
            output = run('Validate Developer ID identity', ['security', 'find-identity', '-v', '-p', 'codesigning', keychain]).stdout.decode()
            identity = developer_identity(output, os.environ['APPLE_TEAM_ID'])
            yield keychain, identity, directory / 'AuthKey.p8'
        finally:
            try:
                if search_list_changed:
                    run('Restore keychain search list',
                        ['security', 'list-keychains', '-d', 'user', '-s', *original_keychains], check=False)
            finally:
                if keychain.exists():
                    run('Delete temporary signing keychain', ['security', 'delete-keychain', keychain], check=False)


def notarize(artifact, key, logs, name):
    auth = ['--key', key, '--key-id', os.environ['APPLE_NOTARY_KEY_ID'], '--issuer', os.environ['APPLE_NOTARY_ISSUER_ID']]
    result = run('Notarize ' + name, ['xcrun', 'notarytool', 'submit', artifact, *auth,
                 '--wait', '--timeout', '20m', '--output-format', 'json'], log=logs / (name + '-notary.json'), check=False)
    try:
        receipt = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        raise ReleaseError('Notarization returned no valid receipt. See the notarization log.') from None
    if not isinstance(receipt, dict):
        raise ReleaseError('Notarization returned no valid receipt. See the notarization log.')
    submission = receipt.get('id', '')
    if re.fullmatch(r'[a-fA-F0-9-]{36}', submission):
        run('Download notarization diagnostics', ['xcrun', 'notarytool', 'log', submission, *auth,
            logs / (name + '-notary-details.json')], check=False)
    if result.returncode or receipt.get('status') != 'Accepted':
        raise ReleaseError('Notarization was not Accepted; no release can be published. See the notarization log.')


def verify_app(app, expected):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    checks = {'CFBundleIdentifier': 'com.danbarclay.onair', 'CFBundleShortVersionString': expected['version'],
              'CFBundleVersion': expected['build'], 'LSUIElement': True}
    if any(info.get(k) != v for k, v in checks.items()):
        raise ReleaseError('Archived app identity/version does not match this release.')
    resources = app / 'Contents/Resources'
    icon = resources / 'AppIcon.icns'
    catalog = resources / 'Assets.car'
    if (info.get('CFBundleIconName') != 'AppIcon' or
            info.get('CFBundleIconFile') not in ('AppIcon', 'AppIcon.icns') or
            not icon.is_file() or icon.stat().st_size <= 8 or icon.read_bytes()[:4] != b'icns' or
            not catalog.is_file() or catalog.stat().st_size == 0):
        raise ReleaseError('Archived app icon metadata or compiled icon resources are missing or invalid.')
    binary = app / 'Contents/MacOS/On Air'
    architectures = run('Verify both Mac architectures', ['xcrun', 'lipo', '-archs', binary]).stdout.decode().split()
    if set(architectures) != {'arm64', 'x86_64'}:
        raise ReleaseError('Release must contain both arm64 and x86_64 architectures.')
    symbols = run('Check production isolation', ['nm', binary]).stdout
    if b'EndToEndBridge' in symbols or b'FixtureTranscriber' in symbols:
        raise ReleaseError('Test controls must not be included in a release.')
    verify_updater(app, info)


def verify_updater(app, info):
    source = plistlib.loads((ROOT / 'OnAir/Info.plist').read_bytes())
    checks = {'SUFeedURL': FEED_URL, 'SUPublicEDKey': source['SUPublicEDKey'],
              'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
              'SUSignedFeedFailureExpirationInterval': 0,
              'SUAllowsAutomaticUpdates': False, 'SUEnableSystemProfiling': False}
    if any(info.get(k) != v for k, v in checks.items()):
        raise ReleaseError('Archived updater configuration does not match the signed stable feed.')
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    if not (framework / 'Sparkle').is_file():
        raise ReleaseError('Sparkle is not embedded in the app.')
    framework_info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    if framework_info.get('CFBundleShortVersionString') != SPARKLE_VERSION:
        raise ReleaseError('Embedded Sparkle version does not match the pinned signing tools.')


def sign_nested_code(app, keychain, identity, logs):
    framework = app / 'Contents/Frameworks/Sparkle.framework/Versions/B'
    # Sign from the inside out. Do not use --deep for signing or apply the
    # microphone entitlement to Sparkle's installer and downloader processes.
    paths = [framework / 'XPCServices/Downloader.xpc', framework / 'XPCServices/Installer.xpc',
             framework / 'Autoupdate', framework / 'Updater.app', framework]
    for index, path in enumerate(paths):
        if not path.exists():
            raise ReleaseError('Missing Sparkle signing component: ' + path.name)
        run('Sign Sparkle ' + path.name, ['codesign', '--force', '--sign', identity, '--keychain', keychain,
            '--options', 'runtime', '--timestamp', '--preserve-metadata=entitlements', path], log=logs / f'sparkle-signing-{index}.log')
    run('Verify nested Sparkle signatures', ['codesign', '--verify', '--deep', '--strict', framework])


def sparkle_tools(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f'Sparkle-{SPARKLE_VERSION}.tar.xz'
    if not archive.exists():
        url = f'https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/{archive.name}'
        with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_TOOLS_SHA256:
        raise ReleaseError('Sparkle signing tools checksum mismatch.')
    # Only the two self-contained tools are required, never extract arbitrary
    # archive paths or symlinks. Verify the archive before executing either.
    with tarfile.open(archive) as contents:
        for name in ('generate_appcast', 'sign_update'):
            member = contents.getmember('./bin/' + name)
            if not member.isfile():
                raise ReleaseError('Unexpected Sparkle tool archive entry.')
            target = directory / name
            target.write_bytes(contents.extractfile(member).read())
            target.chmod(0o755)
    return directory


def validate_appcast(feed, dmg, details):
    try:
        root = ET.fromstring(feed.read_bytes())
        items = root.findall('./channel/item')
        if len(items) != 1:
            raise ValueError('Expected one full update')
        item = items[0]
        enclosure = item.find('enclosure')
        signature = enclosure.get('{' + SPARKLE_NS + '}edSignature', '')
        expected_url = RELEASE_URL + 'download/' + details['tag'] + '/' + dmg.name
        if (item.findtext('{' + SPARKLE_NS + '}version') != details['build'] or
                item.findtext('{' + SPARKLE_NS + '}shortVersionString') != details['version'] or
                item.findtext('{' + SPARKLE_NS + '}minimumSystemVersion') != '14.0' or
                enclosure.get('url') != expected_url or enclosure.get('length') != str(dmg.stat().st_size) or
                len(base64.b64decode(signature, validate=True)) != 64):
            raise ValueError('Update metadata mismatch')
        # Prereleases live on their own release pages and may never be offered
        # as stable updates, even if somebody fetches their feed manually.
        channel = item.findtext('{' + SPARKLE_NS + '}channel')
        if channel != ('beta' if details['prerelease'] else None):
            raise ValueError('Update channel mismatch')
        return signature
    except (ET.ParseError, ValueError, AttributeError) as error:
        raise ReleaseError('Invalid update feed metadata.') from error


def create_appcast(dmg, details, work, logs):
    tools = sparkle_tools(work / 'sparkle-tools')
    updates = work / 'updates'
    updates.mkdir()
    shutil.copyfile(dmg, updates / dmg.name)
    feed = dmg.parent / 'appcast.xml'
    arguments = [tools / 'generate_appcast', '--ed-key-file', '-', '--maximum-deltas', '0',
                 '--maximum-versions', '1', '--download-url-prefix', RELEASE_URL + 'download/' + details['tag'] + '/',
                 '--full-release-notes-url', RELEASE_URL + 'tag/' + details['tag'], '-o', feed]
    if details['prerelease']:
        arguments += ['--channel', 'beta']
    arguments.append(updates)
    # Pass the signing seed on stdin, never in argv, logs, or a file artifact.
    key = os.environ['SPARKLE_PRIVATE_KEY'].strip().encode()
    run('Generate signed Sparkle feed', arguments, input=key, log=logs / 'appcast.log')
    signature = validate_appcast(feed, dmg, details)
    run('Verify update archive signature', [tools / 'sign_update', '--ed-key-file', '-', '--verify', dmg, signature], input=key)
    run('Verify signed update feed', [tools / 'sign_update', '--ed-key-file', '-', '--verify', feed], input=key)
    digest = hashlib.sha256(feed.read_bytes()).hexdigest()
    (feed.parent / 'appcast.xml.sha256').write_text(digest + '  appcast.xml\n')
    return digest


def build_package(tag, build, output, unsigned=False):
    details = metadata(tag, build)
    if not unsigned:
        require_credentials()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    dist, logs = output / 'dist', output / 'logs'
    if dist.exists():
        raise ReleaseError('Output dist directory already exists. Choose a fresh output directory; release assets are never overwritten.')
    dist.mkdir()
    logs.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='build-', dir=output) as temporary:
        work = Path(temporary)
        archive = work / 'OnAir.xcarchive'
        run('Archive universal Release', ['xcodebuild', '-project', 'OnAir.xcodeproj', '-scheme', 'OnAir',
            '-configuration', 'Release', '-destination', 'generic/platform=macOS', '-archivePath', archive,
            '-derivedDataPath', work / 'DerivedData', '-packageAuthorizationProvider', 'netrc', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
            'CODE_SIGN_IDENTITY=', 'ONLY_ACTIVE_ARCH=NO', 'ARCHS=arm64 x86_64', 'SKIP_INSTALL=NO',
            'MARKETING_VERSION=' + details['version'], 'CURRENT_PROJECT_VERSION=' + build, 'archive'], log=logs / 'archive.log')
        app = archive / 'Products/Applications/On Air.app'
        verify_app(app, details)
        name = 'On-Air-' + tag + ('-unsigned' if unsigned else '') + '.dmg'
        dmg = dist / name
        if unsigned:
            create_dmg(app, dmg, work, logs)
        else:
            with signing_assets() as (keychain, identity, key):
                sign_nested_code(app, keychain, identity, logs)
                run('Sign app with Developer ID', ['codesign', '--force', '--sign', identity, '--keychain', keychain,
                    '--options', 'runtime', '--timestamp', '--entitlements', ROOT / 'OnAir/OnAir.entitlements', app],
                    log=logs / 'app-signing.log')
                run('Verify app signature', ['codesign', '--verify', '--deep', '--strict', app])
                archive_zip = work / 'OnAir.zip'
                run('Package app for notarization', ['ditto', '-c', '-k', '--keepParent', app, archive_zip])
                notarize(archive_zip, key, logs, 'app')
                run('Staple app ticket', ['xcrun', 'stapler', 'staple', app])
                run('Validate app ticket', ['xcrun', 'stapler', 'validate', app])
                run('Assess app with Gatekeeper', ['spctl', '--assess', '--type', 'execute', '--verbose=2', app])
                create_dmg(app, dmg, work, logs)
                run('Sign disk image', ['codesign', '--sign', identity, '--keychain', keychain,
                    '--timestamp', '--identifier', 'com.danbarclay.onair.dmg', dmg], log=logs / 'dmg-signing.log')
                notarize(dmg, key, logs, 'dmg')
                run('Staple disk image ticket', ['xcrun', 'stapler', 'staple', dmg])
                run('Validate disk image ticket', ['xcrun', 'stapler', 'validate', dmg])
                run('Verify disk image signature', ['codesign', '--verify', '--strict', dmg])
                run('Assess disk image with Gatekeeper', ['spctl', '--assess', '--type', 'open', '--context',
                    'context:primary-signature', '--verbose=2', dmg])
        # Hash only the final bytes, after stapling. A receipt exists only on full success.
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        (dist / (name + '.sha256')).write_text(digest + '  ' + name + '\n')
        # Copy the final, stapled bytes. A fixed asset name gives the website a
        # permanent /releases/latest/download/On-Air.dmg URL.
        download_name = 'On-Air-unsigned.dmg' if unsigned else 'On-Air.dmg'
        shutil.copyfile(dmg, dist / download_name)
        (dist / (download_name + '.sha256')).write_text(digest + '  ' + download_name + '\n')
        details.update({'signed_notarized': not unsigned, 'file': name, 'sha256': digest,
                        'download_file': download_name,
                        'commit': run('Record source commit', ['git', 'rev-parse', 'HEAD']).stdout.decode().strip()})
        if not unsigned:
            details['appcast_sha256'] = create_appcast(dmg, details, work, logs)
        (dist / 'release.json').write_text(json.dumps(details, indent=2) + '\n')
    return details


def create_dmg(app, dmg, work, logs):
    staging = work / 'dmg-root'
    staging.mkdir()
    run('Stage app bundle', ['ditto', app, staging / 'On Air.app'])
    (staging / 'Applications').symlink_to('/Applications')
    run('Create drag-to-Applications disk image', ['hdiutil', 'create', '-volname', 'On Air', '-srcfolder', staging,
        '-format', 'UDZO', '-fs', 'HFS+', dmg], log=logs / 'dmg.log')
    run('Verify disk image', ['hdiutil', 'verify', dmg], log=logs / 'dmg-verify.log')


def verify_publishable(directory, tag, commit):
    directory = Path(directory)
    info = json.loads((directory / 'release.json').read_text())
    expected = metadata(tag, info['build'])
    name = 'On-Air-' + tag + '.dmg'
    if (info.get('signed_notarized') is not True or info.get('commit') != commit or
            info.get('file') != name or info.get('download_file') != 'On-Air.dmg' or
            any(info.get(k) != v for k, v in expected.items())):
        raise ReleaseError('Only the notarized artifact for this exact tag and commit can be published.')
    for asset in (name, 'On-Air.dmg'):
        if not (directory / asset).is_file() or not (directory / (asset + '.sha256')).is_file():
            raise ReleaseError('Release asset or checksum missing: ' + asset)
        digest = hashlib.sha256((directory / asset).read_bytes()).hexdigest()
        if digest != info.get('sha256') or (directory / (asset + '.sha256')).read_text() != digest + '  ' + asset + '\n':
            raise ReleaseError('Release asset checksum mismatch: ' + asset)
    feed = directory / 'appcast.xml'
    if not feed.is_file() or not (directory / 'appcast.xml.sha256').is_file():
        raise ReleaseError('Signed update feed is missing.')
    digest = hashlib.sha256(feed.read_bytes()).hexdigest()
    if (digest != info.get('appcast_sha256') or
            (directory / 'appcast.xml.sha256').read_text() != digest + '  appcast.xml\n'):
        raise ReleaseError('Signed update feed checksum mismatch.')
    validate_appcast(feed, directory / name, info)
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    package = commands.add_parser('package')
    package.add_argument('--tag', required=True)
    package.add_argument('--build', required=True)
    package.add_argument('--output', default='.build/release')
    package.add_argument('--unsigned', action='store_true', help='CI packaging check only; never publish this artifact.')
    publish = commands.add_parser('verify-publishable')
    publish.add_argument('--directory', required=True)
    publish.add_argument('--tag', required=True)
    publish.add_argument('--commit', required=True)
    meta = commands.add_parser('metadata')
    meta.add_argument('--tag', required=True)
    meta.add_argument('--build', required=True)
    args = parser.parse_args()
    if args.command == 'package':
        details = build_package(args.tag, args.build, args.output, args.unsigned)
    elif args.command == 'verify-publishable':
        details = verify_publishable(args.directory, args.tag, args.commit)
    else:
        details = metadata(args.tag, args.build)
    print(json.dumps(details))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('tag=' + details['tag'] + '\nprerelease=' + str(details['prerelease']).lower() + '\n')


if __name__ == '__main__':
    # GitHub cancellation should still unwind the temporary keychain context.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        # Exceptions from subprocess use the safe label, never credential-bearing argv.
        print('Release failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
