#!/bin/sh
# Resource cost of one watcher process group ($1). Prints key=value lines. Linux reports
# cumulative CPU ticks (the client derives a rate between samples); macOS reports ps's
# recent CPU percentage. "handles" is whatever the watch mechanism consumes: inotify
# watches out of the per-user limit on Linux, open files out of the descriptor limit
# elsewhere.
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
    echo "kind=inotify"; echo "handles=$handles"
    echo "limit=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null)"
else
    members=$(ps -A -o pgid=,pid=,pcpu=,rss= | awk -v group="$group" '
        $1 == group { cpu += $3; rss += $4; pids = pids (n++ ? "," : "") $2 }
        END { printf "processes=%d\ncpu=%.1f\nrss=%.0f\npids=%s\n", n, cpu, rss * 1024, pids }')
    printf '%s\n' "$members" | grep -v '^pids='
    pids=$(printf '%s\n' "$members" | sed -n 's/^pids=//p')
    echo "kind=files"
    [ -n "$pids" ] && echo "handles=$(lsof -n -P -p "$pids" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]/' | wc -l | tr -d ' ')"
    echo "limit=$(ulimit -n)"
fi
