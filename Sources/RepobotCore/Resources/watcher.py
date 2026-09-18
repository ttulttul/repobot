#!/usr/bin/env python3
"""Stdin-only Linux inotify / macOS FSEvents watcher. Python standard library only."""
import ctypes, os, select, struct, subprocess, sys, threading, time

SKIP = {'.git', 'node_modules', '.venv', 'vendor', 'target', 'build', 'dist', 'Library', '.Trash'}
roots = sys.argv[1:sys.argv.index('--')] if '--' in sys.argv else []
repos = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
write_lock = threading.Lock()
def emit(*parts):
    with write_lock:
        sys.stdout.buffer.write(b''.join(os.fsencode(p) + b'\0' for p in parts))
        sys.stdout.buffer.flush()
def heartbeat():
    while True:
        time.sleep(30)
        emit('PING')

def linux():
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), 'inotify_init1')
    mask = 0x2 | 0x4 | 0x8 | 0xC0 | 0x100 | 0x200 | 0x400 | 0x800
    watches = {}
    budgets = {}
    try:
        with open('/proc/sys/fs/inotify/max_user_watches') as f:
            limit = max(1, int(f.read()) - 128)
    except OSError:
        limit = 8192
    def watch(path, repo):
        if len(watches) >= limit:
            return False
        wd = libc.inotify_add_watch(fd, os.fsencode(path), mask | 0x01000000)
        if wd >= 0:
            if wd not in watches:
                watches[wd] = (path, set())
            watches[wd][1].add(repo)
        return wd >= 0
    def tree(path, repo, cap):
        seen = budgets.setdefault((repo, cap), set())
        for directory, dirs, _ in os.walk(path):
            dirs[:] = [d for d in dirs if d not in SKIP]
            if directory in seen:
                continue
            if len(seen) >= cap or not watch(directory, repo):
                emit('LIMIT', repo)
                break
            seen.add(directory)
    for root in roots:
        watch(os.path.expanduser(root), '')
    for repo in repos:
        # Linked worktrees have both a private gitdir and a shared common gitdir.
        for flag in ('--absolute-git-dir', '--git-common-dir'):
            p = subprocess.run(['git', '-C', repo, 'rev-parse', flag], capture_output=True)
            if p.returncode == 0:
                gitdir = os.fsdecode(p.stdout.rstrip(b'\n'))
                if not os.path.isabs(gitdir):
                    gitdir = os.path.join(repo, gitdir)
                tree(gitdir, repo, 256)
        tree(repo, repo, 2000)
    if not watches:
        raise RuntimeError('No inotify watches could be registered')
    emit('READY')
    while True:
        ready, _, _ = select.select([fd], [], [], 1)
        if not ready:
            continue
        buf = os.read(fd, 262144)
        pos = 0
        changed = set()
        while pos + 16 <= len(buf):
            wd, flags, cookie, length = struct.unpack_from('iIII', buf, pos)
            name = os.fsdecode(buf[pos+16:pos+16+length].split(b'\0')[0])
            pos += 16 + length
            if flags & 0x4000:  # queue overflow
                emit('RESCAN')
            if wd in watches:
                path, owners = watches[wd]
                changed.update(owners)
                if flags & 0x40000000 and flags & (0x100 | 0x80) and name not in SKIP:
                    for owner in owners:
                        tree(os.path.join(path, name), owner, 2000)
                if flags & 0x8000:
                    watches.pop(wd, None)
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
    owners = {r: {r} for r in repos}
    for repo in repos:
        for flag in ('--absolute-git-dir', '--git-common-dir'):
            result = subprocess.run(['git', '-C', repo, 'rev-parse', flag], capture_output=True)
            if result.returncode == 0:
                path = os.path.realpath(os.path.join(repo, os.fsdecode(result.stdout.rstrip(b'\n'))))
                owners.setdefault(path, set()).add(repo)
    callback_type = ctypes.CFUNCTYPE(None, ptr, ptr, ctypes.c_size_t, ptr, ptr, ptr)
    @callback_type
    def callback(stream, context, count, paths, flags, ids):
        values = ctypes.cast(paths, ctypes.POINTER(ctypes.c_char_p))
        for i in range(count):
            path = os.fsdecode(values[i])
            matches = set().union(*(v for p, v in owners.items() if path == p or path.startswith(p + '/')))
            for repo in matches:
                emit('CHANGED', repo)
            if not matches:
                emit('RESCAN')
    paths = list(dict.fromkeys(os.path.expanduser(p) for p in roots + list(owners)))
    strings = [cf.CFStringCreateWithCString(None, os.fsencode(p), 0x08000100) for p in paths]
    array = cf.CFArrayCreate(None, (ptr * len(strings))(*strings), len(strings), None)
    cs.FSEventStreamCreate.argtypes = [ptr, callback_type, ptr, ptr, ctypes.c_uint64, ctypes.c_double, ctypes.c_uint32]
    cs.FSEventStreamCreate.restype = ptr
    stream = cs.FSEventStreamCreate(None, callback, None, array, 0xffffffffffffffff, 1.0, 0x10)
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

threading.Thread(target=heartbeat, daemon=True).start()
if sys.platform == 'linux':
    linux()
elif sys.platform == 'darwin':
    macos()
else:
    raise RuntimeError('Unsupported event platform')
