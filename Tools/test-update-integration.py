#!/usr/bin/env python3
"""Native Sparkle smoke tests. Run serially after desktop E2E checks on a logged-in Mac."""
import base64
import functools
import http.server
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import uuid
import release


def main():
    tools = release.sparkle_tools(release.ROOT / '.build/sparkle-tools')
    framework = release.ROOT / '.build/updater-debug/Build/Products/Debug/Sparkle.framework'
    if not framework.is_dir():
        raise SystemExit('First build OnAir Debug with -derivedDataPath .build/updater-debug.')
    identifier = 'com.danbarclay.onair.update-integration.' + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix='on-air-updater-integration-') as temporary:
        folder = Path(temporary)
        contents = folder / 'Update Checks.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        executable = contents / 'MacOS/UpdateChecks'
        release.run('Compile real Sparkle integration checks', ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
            '-F', framework.parent, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(framework.parent),
            release.ROOT / 'OnAir/Updates/UpdateModel.swift', release.ROOT / 'OnAir/Updates/SparkleUpdateDriver.swift',
            release.ROOT / 'Tools/UpdateIntegrationChecks.swift', '-o', executable])
        seed = base64.b64encode(os.urandom(32))
        public = release.run('Derive disposable public key', [executable, 'public-key'], input=seed).stdout.decode().strip()
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                # The fixture changes within one second; never serve a cached
                # earlier feed because the HTTP last-modified time is rounded.
                if 'If-Modified-Since' in self.headers:
                    del self.headers['If-Modified-Since']
                super().do_GET()
            def end_headers(self):
                self.send_header('Cache-Control', 'no-store')
                super().end_headers()
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(folder)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        feed = folder / 'appcast.xml'
        url = f'http://127.0.0.1:{server.server_port}/appcast.xml'
        info = {'CFBundleIdentifier': identifier, 'CFBundleName': 'On Air Update Checks', 'CFBundleExecutable': 'UpdateChecks',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '10', 'CFBundleShortVersionString': '1.0.7',
                'SUFeedURL': url, 'SUPublicEDKey': public, 'SUEnableAutomaticChecks': False,
                'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True, 'SUSignedFeedFailureExpirationInterval': 0,
                'SUAllowsAutomaticUpdates': False, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        try:
            for mode, version in [('current', '10'), ('available', '11'), ('background-available', '11'), ('error', '12')]:
                feed.write_text(f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="{release.SPARKLE_NS}"><channel>
                    <title>Disposable fixture</title><item><title>Fixture release</title>
                    <sparkle:version>{version}</sparkle:version><sparkle:shortVersionString>1.0.8</sparkle:shortVersionString>
                    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                    <enclosure url="http://127.0.0.1:{server.server_port}/fixture.zip" length="4" type="application/octet-stream"
                    sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}"/></item></channel></rss>''')
                release.run('Sign local test feed', [tools / 'sign_update', '--ed-key-file', '-', feed], input=seed)
                if mode == 'error':
                    feed.write_bytes(feed.read_bytes().replace(b'Fixture release', b'Tampered release'))
                result = release.run('Exercise real Sparkle ' + mode, [executable, mode],
                                     log=release.ROOT / ('.build/sparkle-' + mode + '.log'))
                print(result.stdout.decode().strip())
            for mode in ('preferences-write', 'preferences-read'):
                print(release.run('Exercise real Sparkle ' + mode, [executable, mode]).stdout.decode().strip())
            feed.unlink()
            print(release.run('Exercise missing feed recovery', [executable, 'error']).stdout.decode().strip())
        finally:
            server.shutdown()
            subprocess.run(['defaults', 'delete', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('PASS: real Sparkle current/update/tampered/missing feeds, quiet background discovery, visible update windows, and persisted settings. No app replacement performed.')


if __name__ == '__main__':
    main()
