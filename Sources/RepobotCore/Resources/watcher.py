#!/usr/bin/env python3
"""Stdin-only Linux inotify / macOS FSEvents watcher. Python standard library only."""
import ctypes, os, select, socket, struct, subprocess, sys, threading, time, errno, collections

SKIP = {'.git', 'node_modules', '.venv', 'vendor', 'target', 'build', 'dist', 'Library', '.Trash'}
roots = sys.argv[1:sys.argv.index('--')] if '--' in sys.argv else []
repos = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
write_lock = threading.Lock()
def emit(*parts):
    # Python ignores SIGPIPE. A failed write means the client is gone; exit the whole
    # process, not only the calling thread, so no watcher outlives its connection.
    try:
        with write_lock:
            sys.stdout.buffer.write(b''.join(os.fsencode(p) + b'\0' for p in parts))
            sys.stdout.buffer.flush()
    except (OSError, ValueError):
        os._exit(0)
def heartbeat():
    while True:
        time.sleep(30)
        emit('PING')
def hangup_guard():
    # The script itself arrives on stdin, so stdin is at EOF from the start and says
    # nothing about the client. The read end of stdout closing does: exit at once
    # instead of waiting for the next write to fail.
    if hasattr(select, 'kqueue'):
        # macOS poll() does not report a closed pipe reader; an edge-triggered
        # kqueue write filter does.
        queue = select.kqueue()
        queue.control([select.kevent(sys.stdout.fileno(), select.KQ_FILTER_WRITE,
                                     select.KQ_EV_ADD | select.KQ_EV_CLEAR)], 0)
        while True:
            if any(event.flags & select.KQ_EV_EOF for event in queue.control(None, 4)):
                os._exit(0)
    poller = select.poll()
    poller.register(sys.stdout.fileno(), 0)
    while True:
        events = poller.poll()
        if any(flags & (select.POLLERR | select.POLLHUP) for _, flags in events):
            os._exit(0)
        if events:
            return  # Not a pipe or socket; rely on failed writes.

def claim(key):
    """Replace an older watcher of the same client whose connection died without the
    remote end noticing (sleep, network change). Linux abstract sockets leave nothing
    on disk. Returns a listener; a connection to it asks this process to exit."""
    name = b'\0repobot-watcher-' + os.fsencode(key)
    for _ in range(50):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(name)
            listener.listen(4)
            return listener
        except OSError as error:
            if error.errno != errno.EADDRINUSE:
                listener.close()
                return None
        try:
            listener.connect(name)
        except OSError:
            pass
        listener.close()
        time.sleep(0.1)
    return None
def replaced(listener):
    try:
        connection, _ = listener.accept()
    except OSError:
        return False
    try:
        _, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    except OSError:
        uid = -1
    connection.close()
    return uid == os.getuid()

def git(repo, *arguments):
    return subprocess.run(['git', '-C', repo] + list(arguments), capture_output=True,
                          env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'))
def work_directories(repo):
    """Directories holding tracked or untracked-but-not-ignored files, shallowest first.
    Ignored dependency and model trees would otherwise consume nearly every watch."""
    p = git(repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard')
    found = {''}
    if p.returncode == 0:
        for name in p.stdout.split(b'\0'):
            directory = os.path.dirname(os.fsdecode(name))
            while directory and directory not in found:
                found.add(directory)
                directory = os.path.dirname(directory)
    ordered = sorted(found, key=lambda d: (d.count(os.sep) if d else -1, d))
    return [os.path.join(repo, d) if d else repo for d in ordered
            if not any(part in SKIP for part in d.split(os.sep))]

def git_directories(repo):
    known = globals().get('known_git_directories', {}).get(repo)
    if known:
        return list(dict.fromkeys(os.path.realpath(p) for p in known))
    result = []
    for flag in ('--absolute-git-dir', '--git-common-dir'):
        p = subprocess.run(['git', '-C', repo, 'rev-parse', flag], capture_output=True)
        if p.returncode == 0:
            directory = os.fsdecode(p.stdout.rstrip(b'\n'))
            result.append(os.path.realpath(os.path.join(repo, directory)))
    return list(dict.fromkeys(result))

def matching_repositories(owners, path):
    matches = set()
    while path:
        matches.update(owners.get(path, ()))
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return matches

def compact_roots(paths):
    result = []
    for path in sorted(set(os.path.realpath(os.path.expanduser(p)) for p in paths), key=lambda p: (len(p), p)):
        if not any(path == parent or path.startswith(parent.rstrip('/') + '/') for parent in result):
            result.append(path)
    return result

def linux():
    listener = claim(globals()['client_id']) if globals().get('client_id') else None
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), 'inotify_init1')
    mask = 0x2 | 0x4 | 0x8 | 0xC0 | 0x100 | 0x200 | 0x400 | 0x800
    watches = {}  # wd -> (path, owning repositories, recursive)
    budgets = {}
    anchors = set()
    failures = collections.Counter()
    limited = set()
    # inotify is not recursive: every directory costs one watch from a budget shared
    # by all of this user's programs. Leave half of it to editors and other tools.
    try:
        with open('/proc/sys/fs/inotify/max_user_watches') as f:
            limit = max(1, int(f.read()) // 2)
    except OSError:
        limit = 8192
    def watch(path, repo, recursive=False):
        if len(watches) >= limit:
            failures['Repobot global watch budget'] += 1
            return False
        wd = libc.inotify_add_watch(fd, os.fsencode(path), mask | 0x01000000)
        if wd >= 0:
            if wd not in watches:
                watches[wd] = (path, set(), recursive)
            watches[wd][1].add(repo)
        if wd < 0:
            code = ctypes.get_errno()
            if code in (errno.ENOENT, errno.ENOTDIR):
                return True  # Vanished between listing and registration.
            failures[f'errno {code} ({os.strerror(code)})'] += 1
        return wd >= 0
    def register(directories, repo, cap):
        seen = budgets.setdefault((repo, cap), set())
        for directory in directories:
            if directory in seen:
                continue
            if len(seen) >= cap or not watch(directory, repo, True):
                limited.add(repo)
                break
            seen.add(directory)
    def walk(path):
        for directory, dirs, _ in os.walk(path):
            dirs[:] = [d for d in dirs if d not in SKIP]
            yield directory
    for root in roots:
        path = os.path.expanduser(root)
        anchors.add(path)
        watch(path, '')
    for repo in repos:
        # Git state needs only the gitdir itself (HEAD, index, packed-refs, FETCH_HEAD,
        # operation markers) and the ref hierarchy: never objects/ or logs/. Linked
        # worktrees have both a private gitdir and a shared common gitdir.
        for gitdir in git_directories(repo):
            anchors.add(gitdir)
            if not watch(gitdir, repo):
                limited.add(repo)
            for name in ('refs', 'reftable'):
                if os.path.isdir(os.path.join(gitdir, name)):
                    register(walk(os.path.join(gitdir, name)), repo, 256)
    # Register every repository's Git metadata before working trees consume
    # the shared per-user watch budget. Other programs may already occupy it.
    for repo in repos:
        anchors.add(repo)
        register(work_directories(repo), repo, 2000)
    detail = '; '.join(f'{reason}: {count}' for reason, count in sorted(failures.items()))
    coverage = f'{len(watches)} directory watches; {len(limited)} repositories limited; ' + (detail or 'per-repository budget reached')
    if not watches:
        os.close(fd)
        raise RuntimeError('No inotify watches could be registered: ' + coverage)
    if limited or failures:
        emit('LIMIT', coverage)
    emit('READY')
    sources = [fd] + ([listener] if listener else [])
    while True:
        ready, _, _ = select.select(sources, [], [])
        if listener in ready and replaced(listener):
            os._exit(0)
        if fd not in ready:
            continue
        try:
            buf = os.read(fd, 262144)
        except BlockingIOError:
            continue
        pos = 0
        changed = set()
        reset = False
        while pos + 16 <= len(buf):
            wd, flags, cookie, length = struct.unpack_from('iIII', buf, pos)
            name = os.fsdecode(buf[pos+16:pos+16+length].split(b'\0')[0])
            pos += 16 + length
            if flags & 0x4000:  # queue overflow
                emit('RESCAN')
            if wd in watches:
                path, owners, recursive = watches[wd]
                changed.update(owners)
                if recursive and flags & 0x40000000 and flags & (0x100 | 0x80) and name not in SKIP:
                    created = os.path.join(path, name)
                    for owner in owners:
                        if git(owner, 'check-ignore', '-q', created).returncode != 0:
                            register(walk(created), owner, 2000)
                if flags & 0x8000:
                    removed = watches.pop(wd)[0]
                    for seen in budgets.values():
                        seen.discard(removed)
                    # Only a vanished root, repository or gitdir changes coverage.
                    reset = reset or removed in anchors
        if reset:
            emit('RESET')
        for repo in changed:
            emit('CHANGED', repo) if repo else emit('RESCAN')

def macos():
    cs = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    ptr = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFArrayCreate.argtypes = [ptr, ctypes.POINTER(ptr), ctypes.c_long, ptr]
    cf.CFArrayCreate.restype = ptr
    cf.CFRunLoopGetCurrent.restype = ptr
    work_roots = {r: os.path.realpath(r) for r in repos}
    owners = {p: {r} for r, p in work_roots.items()}
    for repo in repos:
        for path in git_directories(repo):
            owners.setdefault(path, set()).add(repo)
    callback_type = ctypes.CFUNCTYPE(None, ptr, ptr, ctypes.c_size_t, ptr, ptr, ptr)
    @callback_type
    def callback(stream, context, count, paths, flags, ids):
        values = ctypes.cast(paths, ctypes.POINTER(ctypes.c_char_p))
        event_flags = ctypes.cast(flags, ctypes.POINTER(ctypes.c_uint32))
        changed = set()
        rescan = reset = False
        for i in range(count):
            if event_flags[i] & (0x1 | 0x2 | 0x4): rescan = True
            if event_flags[i] & (0x20 | 0x40 | 0x80): reset = True
            path = os.fsdecode(values[i])
            matches = matching_repositories(owners, path)
            for repo in matches:
                root = work_roots[repo]
                relative = path[len(root) + 1:] if path.startswith(root + '/') else ''
                if not any(part in SKIP - {'.git'} for part in relative.split(os.sep)):
                    changed.add(repo)
            if not matches and not any(part in SKIP - {'.git'} for part in path.split(os.sep)):
                rescan = True
        if reset: emit('RESET')
        elif rescan: emit('RESCAN')
        for repo in sorted(changed): emit('CHANGED', repo)
    paths = compact_roots(roots + list(owners))
    strings = [cf.CFStringCreateWithCString(None, os.fsencode(p), 0x08000100) for p in paths]
    array = cf.CFArrayCreate(None, (ptr * len(strings))(*strings), len(strings), None)
    cs.FSEventStreamCreate.argtypes = [ptr, callback_type, ptr, ptr, ctypes.c_uint64, ctypes.c_double, ctypes.c_uint32]
    cs.FSEventStreamCreate.restype = ptr
    stream = cs.FSEventStreamCreate(None, callback, None, array, 0xffffffffffffffff, 1.0, 0x10 | 0x4)
    if not stream:
        raise RuntimeError('FSEventStreamCreate failed')
    cs.FSEventStreamScheduleWithRunLoop.argtypes = [ptr, ptr, ptr]
    mode = ptr.in_dll(cf, 'kCFRunLoopDefaultMode')
    cs.FSEventStreamScheduleWithRunLoop(stream, cf.CFRunLoopGetCurrent(), mode)
    cs.FSEventStreamStart.argtypes = [ptr]
    if not cs.FSEventStreamStart(stream):
        raise RuntimeError('FSEventStreamStart failed')
    emit('READY')
    cf.CFRunLoopRun()

if __name__ == '__main__':
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(target=hangup_guard, daemon=True).start()
    if sys.platform == 'linux':
        linux()
    elif sys.platform == 'darwin':
        macos()
    else:
        raise RuntimeError('Unsupported event platform')
