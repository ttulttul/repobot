#!/bin/sh
emit() { printf '%s\000' "$@"; }
emit OS "$(uname -s)" ARCH "$(uname -m)" GIT "$(git --version 2>/dev/null)" HOME "$HOME"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import ctypes,sys' 2>/dev/null; then emit PYTHON 1; fi
command -v inotifywait >/dev/null 2>&1 && emit INOTIFY 1
command -v fswatch >/dev/null 2>&1 && emit FSWATCH 1
[ -r /proc/sys/fs/inotify/max_user_watches ] && emit MAX "$(cat /proc/sys/fs/inotify/max_user_watches)"
for d in git src code projects dev repos work; do [ -d "$HOME/$d" ] && emit ROOT "$HOME/$d"; done
exit 0
