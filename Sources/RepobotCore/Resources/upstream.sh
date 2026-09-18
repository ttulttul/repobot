#!/bin/sh
# NUL-delimited fields: filenames, tabs and newlines cannot inject protocol records.
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ASKPASS= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=never LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
mode=$1; shift
emit() { printf '%s\000' "$@"; }
git() { command git -c credential.helper= -c core.askPass= -c credential.interactive=false -c core.fsmonitor=false "$@"; }
bounded_git() {
    command git -c credential.helper= -c core.askPass= -c credential.interactive=false -c core.fsmonitor=false -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 "$@" &
    child=$!
    (
        sleep 10 & sleeper=$!
        trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
        wait "$sleeper"
        kill -TERM "$child" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    timer=$!
    wait "$child"; result=$?
    kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
    return "$result"
}
original_ssh_command=${GIT_SSH_COMMAND:-}
# Only successful read-only observations live in this private invocation-scoped cache.
# No credentials or configuration contents are written to disk.
query_cache=
if [ "$mode" != fetch ]; then
    umask 077
    query_cache=$(mktemp -d /tmp/repobot-upstream.XXXXXXXX 2>/dev/null) || query_cache=
fi
trap '[ -z "$query_cache" ] || rm -rf "$query_cache"' EXIT
trap 'exit 1' HUP INT TERM
while [ "$#" -ge 2 ]; do
    repo=$1; share=$2; shift 2
    case "$repo" in '~') repo=$HOME;; '~/'*) repo=$HOME/${repo#\~/};; esac
    emit REPO "$repo"
    if ! cd "$repo" 2>/dev/null; then emit ERR 'Repository is missing' END "$repo"; continue; fi
    if ! git rev-parse --git-dir >/dev/null 2>&1; then emit ERR 'Not a working repository' END "$repo"; continue; fi
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
    upsha=$(git rev-parse --verify '@{upstream}' 2>/dev/null)
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
    remote=$(git config --get "branch.$branch.remote" 2>/dev/null)
    merge=$(git config --get "branch.$branch.merge" 2>/dev/null)
    gone=0
    [ -n "$merge" ] && [ -z "$upsha" ] && gone=1
    [ -z "$up" ] && [ -n "$merge" ] && up="$remote/${merge#refs/heads/}"
    emit UPSTREAM "$up" "$upsha" "$gone"
    tracking_url=
    if [ -n "$remote" ] && [ "$remote" != . ]; then tracking_url=$(git remote get-url "$remote" 2>/dev/null); fi
    emit TRACKING "$tracking_url" "$merge"
    detached=0; [ -z "$branch" ] && detached=1
    emit HEAD "$(git rev-parse --verify HEAD 2>/dev/null)" "$branch" "$detached"
    if [ "$mode" != off ] && [ -n "$remote" ] && [ -n "$merge" ]; then
        # Git's terminal prompt flag does not cover OpenSSH's own password prompt.
        ssh_command=${original_ssh_command:-$(git config --get core.sshCommand 2>/dev/null)}
        export GIT_SSH_COMMAND="${ssh_command:-ssh} -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1"
        if [ "$mode" = fetch ]; then
            if bounded_git fetch --quiet -- "$remote" 2>/dev/null; then emit FRESH fetched ''; else emit FRESH error 'Fetch failed'; fi
        else
            key=
            if [ "$share" = share ] && [ -n "$query_cache" ] && [ -z "$ssh_command" ] && [ -z "${GIT_SSH:-}${GIT_SSL_CERT:-}${GIT_SSL_KEY:-}${GIT_PROXY_COMMAND:-}" ] && command -v openssl >/dev/null 2>&1; then
                # Relative endpoints and custom HTTP/path/SSH settings may depend on cwd.
                # Conservatively keep those checks independent, even if textually equal.
                case "$tracking_url" in /*|*://*|*:*) eligible=1;; *) eligible=0;; esac
                if [ "$eligible" = 1 ] && ! git config --get-regexp '^(http\.|core\.gitproxy$)' >/dev/null 2>&1; then
                    key=$({ printf '%s\000' "$tracking_url"; git config --null --list || printf 'unshared:%s\000' "$repo"; } | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
                    case "$key" in ''|*[!0-9a-f]*) key=;; esac
                fi
            fi
            if [ -n "$key" ]; then
                if [ ! -f "$query_cache/$key" ]; then
                    if bounded_git ls-remote --heads -- "$remote" > "$query_cache/pending" 2>/dev/null; then
                        mv "$query_cache/pending" "$query_cache/$key"
                    fi
                fi
                if [ -f "$query_cache/$key" ]; then
                    tip=$(awk -v ref="$merge" '$2==ref {print $1; exit}' "$query_cache/$key")
                    if [ -n "$tip" ]; then emit FRESH ok "$tip"; else emit FRESH deleted ''; fi
                else emit FRESH error 'Upstream is unreachable or authentication failed'; fi
            else
                fresh=$(bounded_git ls-remote --exit-code --heads -- "$remote" "$merge" 2>/dev/null); rc=$?
                if [ "$rc" = 0 ]; then emit FRESH ok "$(printf '%s\n' "$fresh" | awk 'NR==1 {print $1}')"
                elif [ "$rc" = 2 ]; then emit FRESH deleted ''
                else emit FRESH error 'Upstream is unreachable or authentication failed'; fi
            fi
        fi
    fi
    emit END "$repo"
done
