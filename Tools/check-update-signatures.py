#!/usr/bin/env python3
"""Exercise the pinned Sparkle verifier with ephemeral keys, never the release key."""
import base64
import os
from pathlib import Path
import tempfile
import release


def main():
    tools = release.sparkle_tools(release.ROOT / '.build/sparkle-tools')
    seed = base64.b64encode(os.urandom(32))
    other_seed = base64.b64encode(os.urandom(32))
    with tempfile.TemporaryDirectory(prefix='on-air-signature-checks-') as folder:
        folder = Path(folder)
        archive = folder / 'fixture.zip'
        archive.write_bytes(b'These bytes stand in for the final notarized archive.')
        signature = release.run('Sign disposable archive', [tools / 'sign_update', '--ed-key-file', '-', '-p', archive], input=seed).stdout.decode().strip()
        verify = [tools / 'sign_update', '--ed-key-file', '-', '--verify', archive, signature]
        release.run('Accept the original archive', verify, input=seed)
        assert release.run('Reject an archive signed by another key', verify, input=other_seed, check=False).returncode != 0
        archive.write_bytes(archive.read_bytes() + b' altered')
        assert release.run('Reject altered archive bytes', verify, input=seed, check=False).returncode != 0

        feed = folder / 'appcast.xml'
        original = b'<?xml version="1.0"?><rss version="2.0"><channel><title>Disposable fixture</title></channel></rss>'
        feed.write_bytes(original)
        verify_feed = [tools / 'sign_update', '--ed-key-file', '-', '--verify', feed]
        assert release.run('Reject an unsigned feed', verify_feed, input=seed, check=False).returncode != 0
        release.run('Sign disposable feed', [tools / 'sign_update', '--ed-key-file', '-', feed], input=seed)
        release.run('Accept the original signed feed', verify_feed, input=seed)
        assert release.run('Reject a feed signed by another key', verify_feed, input=other_seed, check=False).returncode != 0
        feed.write_bytes(feed.read_bytes().replace(b'Disposable fixture', b'Altered feed title'))
        assert release.run('Reject altered feed bytes', verify_feed, input=seed, check=False).returncode != 0
    print('PASS: real Sparkle signatures accept originals and reject unsigned, altered, and wrong-key updates/feeds.')


if __name__ == '__main__':
    main()
