#!/usr/bin/env python3
"""Portable tests of remote watcher preparation, routing and Linux failure diagnostics."""
import ctypes, errno, importlib.util, os, pathlib, subprocess, sys, tempfile, time, unittest
from unittest.mock import patch
source = pathlib.Path(__file__).resolve().parent.parent / 'Sources/RepobotCore/Resources/watcher.py'
spec = importlib.util.spec_from_file_location('watcher', source)
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
class RemoteWatcherTests(unittest.TestCase):
    def test_known_git_directories_skip_subprocesses_and_compact_roots(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = os.path.realpath(temporary); child = root + '/repo'
            w.known_git_directories = {child: [child + '/.git', child + '/.git']}
            with patch.object(w.subprocess, 'run', side_effect=AssertionError('Unexpected Git query')):
                self.assertEqual(w.git_directories(child), [child + '/.git'])
            self.assertEqual(w.compact_roots([root, child, child + '/.git', root + '-sibling']), [root, root + '-sibling'])
    def test_routing_matches_nested_and_external_git_directories(self):
        owners = {'/repo': {'outer'}, '/repo/nested': {'inner'}, '/external/git': {'inner'}, '/': {'root'}}
        self.assertEqual(w.matching_repositories(owners, '/repo/nested/source'), {'outer', 'inner', 'root'})
        self.assertEqual(w.matching_repositories(owners, '/external/git/HEAD'), {'inner', 'root'})
        self.assertEqual(w.matching_repositories(owners, '/repo-other/source'), {'root'})
    def test_linux_reports_actual_errno_and_closes_failed_registration(self):
        class Function:
            def __init__(self, call): self.call = call
            def __call__(self, *args): return self.call(*args)
        class LibC: pass
        with tempfile.TemporaryDirectory() as temporary:
            root = os.path.realpath(temporary); os.mkdir(root + '/.git')
            w.roots = [root]; w.repos = [root]; w.known_git_directories = {root: [root + '/.git']}
            fd = os.open('/dev/null', os.O_RDONLY)
            libc = LibC(); libc.inotify_init1 = Function(lambda flags: fd)
            def failed(*args): ctypes.set_errno(errno.ENOSPC); return -1
            libc.inotify_add_watch = Function(failed)
            with patch.object(w.ctypes, 'CDLL', return_value=libc):
                with self.assertRaisesRegex(RuntimeError, 'errno 28.*No space left'):
                    w.linux()
            with self.assertRaises(OSError): os.fstat(fd)
    def test_work_directories_omit_ignored_trees(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = os.path.realpath(temporary)
            subprocess.run(['git', 'init', '-q', repo], check=True)
            for directory in ('src/deep', 'untracked', 'models/cache', 'node_modules/package'):
                os.makedirs(os.path.join(repo, directory))
                open(os.path.join(repo, directory, 'file'), 'w').close()
            with open(repo + '/.gitignore', 'w') as ignore: ignore.write('models/\n')
            subprocess.run(['git', '-C', repo, 'add', 'src'], check=True)
            self.assertEqual(w.work_directories(repo), [repo] + [repo + '/' + d for d in ('src', 'untracked', 'src/deep')])
    def test_watcher_exits_when_client_closes_stdout(self):
        # Orphans accumulated per reconnect: a quiet watcher never wrote, so never noticed.
        with tempfile.TemporaryDirectory() as temporary:
            repo = os.path.realpath(temporary)
            subprocess.run(['git', 'init', '-q', repo], check=True)
            with open(source, 'rb') as script:
                process = subprocess.Popen([sys.executable, '-', repo, '--', repo], stdin=script,
                                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                self.assertEqual(process.stdout.read(6), b'READY\0')
                process.stdout.close()
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                process.kill()
if __name__ == '__main__': unittest.main()
