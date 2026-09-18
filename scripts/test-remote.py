#!/usr/bin/env python3
"""Real stdin-only probe/discovery/watcher tests; run on macOS or Linux."""
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

RESOURCES = Path(__file__).resolve().parents[1] / 'Sources/RepobotCore/Resources'

def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], stderr=subprocess.DEVNULL).decode().strip()

def make_repo(path):
    path.mkdir(parents=True)
    git(path, 'init', '-b', 'main')
    git(path, 'config', 'user.name', 'Repobot fixture')
    git(path, 'config', 'user.email', 'fixture@example.invalid')
    (path / 'tracked').write_text('initial\n')
    git(path, 'add', '.')
    git(path, 'commit', '-m', 'Initial')

def script(name, args):
    return subprocess.check_output(['sh', '-s', '--', *map(str, args)], input=(RESOURCES / name).read_bytes(), timeout=15)

with tempfile.TemporaryDirectory(prefix='repobot-remote-') as temporary:
    root = Path(temporary).resolve()
    repo = root / "repo with ' quote\tand\nnewline"
    make_repo(repo)
    linked = root / 'worktree'
    git(repo, 'worktree', 'add', '-b', 'linked', str(linked))
    discovered = set(script('discover.sh', [root]).split(b'\0')) - {b''}
    assert discovered == {os.fsencode(repo), os.fsencode(linked)}, discovered
    before = (repo / '.git/index').read_bytes()
    (repo / 'tracked').write_text('modified\n')
    probed = script('probe.sh', ['off', repo, '', linked, ''])
    assert b'COUNTS\x000\x000\x000\x001\x000\x000\x00' in probed, probed
    assert (repo / '.git/index').read_bytes() == before
    copy = root / 'copy'
    git(root, 'clone', str(repo), str(copy))
    git(copy, 'config', 'user.name', 'Fixture')
    git(copy, 'config', 'user.email', 'fixture@example.invalid')
    git(copy, 'commit', '--allow-empty', '-m', 'Unpublished')
    tip = git(copy, 'rev-parse', 'HEAD').encode()
    copy_probe = script('probe.sh', ['off', copy, ''])
    assert b'LOCALCOMMITS\0' + tip + b'\0' in copy_probe
    assert b'BRANCHWORK\0main\0origin/main\x001\x000\0' in copy_probe
    watcher = subprocess.Popen([sys.executable, '-', str(root), '--', str(repo), str(linked)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    watcher.stdin.write((RESOURCES / 'watcher.py').read_bytes())
    watcher.stdin.close()
    buffer = b''
    def until(token, timeout=8):
        global buffer
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if token in buffer:
                buffer = buffer.split(token, 1)[1]
                return
            if watcher.poll() is not None:
                raise AssertionError(watcher.stderr.read().decode())
            ready, _, _ = select.select([watcher.stdout], [], [], .1)
            if ready:
                buffer += os.read(watcher.stdout.fileno(), 65536)
        raise AssertionError(f'Missing {token!r}; output {buffer!r}')
    try:
        until(b'READY\0')
        (repo / 'tracked').write_text('watched\n')
        until(b'CHANGED\0' + os.fsencode(repo) + b'\0')
        (repo / 'new-directory').mkdir()
        time.sleep(.2)
        (repo / 'new-directory' / 'file').write_text('new\n')
        until(b'CHANGED\0' + os.fsencode(repo) + b'\0')
        git(linked, 'commit', '--allow-empty', '-m', 'Worktree commit')
        until(b'CHANGED\0' + os.fsencode(linked) + b'\0')
        (root / 'new-clone').mkdir()
        until(b'RESCAN\0')
    finally:
        watcher.terminate()
        try:
            watcher.wait(timeout=3)
        except subprocess.TimeoutExpired:
            watcher.kill()
            watcher.wait()
print(f'PASS: {sys.platform} discovery, read-only probe, unusual paths, new directories, worktrees, and root events')
