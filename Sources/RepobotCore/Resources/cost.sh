#!/bin/sh
# Resource cost of one Linux watcher process group ($1), as key=value lines: cumulative
# CPU ticks (the client derives a rate between samples), resident memory, and inotify
# watches against the per-user limit. FSEvents on macOS has no per-directory cost, so
# nothing is reported there.
group=$1
if [ -r /proc/self/stat ]; then
    hz=$(getconf CLK_TCK 2>/dev/null); page=$(getconf PAGESIZE 2>/dev/null)
    members=$(awk -v group="$group" -v hz="${hz:-100}" -v page="${page:-4096}" '
        FNR == 1 { pid = FILENAME; sub(/^\/proc\//, "", pid); sub(/\/stat$/, "", pid)
                   sub(/^.*\) /, "")  # comm may contain spaces; fields now start at state
                   if ($3 == group) { ticks += $12 + $13; pages += $22; pids = pids " " pid; n++ } }
        END { printf "processes=%d\nticks=%d\nhz=%d\nrss=%.0f\npids=%s\n", n, ticks, hz, pages * page, pids }
    ' /proc/[0-9]*/stat 2>/dev/null)
    printf '%s\n' "$members" | grep -v '^pids='
    read -r uptime _ < /proc/uptime; echo "uptime=$uptime"
    handles=0
    for pid in $(printf '%s\n' "$members" | sed -n 's/^pids=//p'); do
        count=$(cat /proc/"$pid"/fdinfo/* 2>/dev/null | grep -c '^inotify')
        handles=$((handles + count))
    done
    echo "handles=$handles"
    echo "limit=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null)"
fi
