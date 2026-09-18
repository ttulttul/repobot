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
# Scan every regular working-tree file, including ignored files. Directory mtimes
# and symlink targets are not evidence of file edits. Git metadata may live at a
# custom path inside the work tree, or in a shared worktree directory.
file_age() (
    age_tmp=$(mktemp -d "${TMPDIR:-/tmp}/repobot-age.XXXXXXXX") || {
        emit FILEAGE '' 'Could not create file scan workspace'; return
    }
    trap 'rm -rf "$age_tmp"' EXIT HUP INT TERM
    if stat -f %m "$PWD" >/dev/null 2>&1; then age_style=bsd; else age_style=gnu; fi
    if [ "$age_style" = bsd ]; then
        find "$PWD" \( -name .git -o -name .DS_Store -o -name '._*' -o -path "$g" -o -path "$common" \) -prune -o -type f -exec stat -f %m {} + >"$age_tmp/times" 2>"$age_tmp/errors"
    else
        find "$PWD" \( -name .git -o -name .DS_Store -o -name '._*' -o -path "$g" -o -path "$common" \) -prune -o -type f -exec stat -c %Y -- {} + >"$age_tmp/times" 2>"$age_tmp/errors"
    fi
    age_status=$?
    if [ "$age_status" -ne 0 ] || [ -s "$age_tmp/errors" ]; then
        emit FILEAGE '' 'Some files could not be inspected; newest file age is unavailable'
    else
        emit FILEAGE "$(awk '/^-?[0-9]+$/ {if (!seen || $0>newest) newest=$0; seen=1} END {if(seen) printf "%.0f",newest}' "$age_tmp/times")" ''
    fi
)
emit CLOCKSTART "$(date +%s)"
history_fingerprint() {
    command -v openssl >/dev/null 2>&1 || return
    {
        printf 'repobot-history-v2\000%s\000%s\000%s\000' "$g" "$common" "$peers"
        printf '%s\n' "$status" | awk '/^# branch.oid / || /^# branch.head /'
        git for-each-ref --format='%(refname) %(objectname)' 2>/dev/null || printf 'invalid:%s' "$$"
        git config --null --list 2>/dev/null || printf 'invalid:%s' "$$"
        for input in "$g/HEAD" "${common:-$g}/shallow" "${common:-$g}/info/grafts" "${common:-$g}/logs/refs/stash" "${common:-$g}/objects/info/alternates"; do
            printf '\000%s\000' "$input"; cat "$input" 2>/dev/null
        done
        for sha in $peers; do
            case "$sha" in (''|*[!a-fA-F0-9]*) continue;; esac
            git cat-file -e "$sha^{commit}" 2>/dev/null; printf '%s:%s\000' "$sha" "$?"
        done
    } | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}
while [ "$#" -ge 2 ]; do
    repo=$1; peers=$2; shift 2
    previous_fingerprint=
    case "$peers" in cache:*) previous_fingerprint=${peers%% *}; previous_fingerprint=${previous_fingerprint#cache:}; peers=${peers#* };; esac
    case "$repo" in '~') repo=$HOME;; '~/'*) repo=$HOME/${repo#\~/};; esac
    emit REPO "$repo"
    if ! cd -P "$repo" 2>/dev/null; then emit ERR 'Repository is missing' END "$repo"; continue; fi
    g=$(git rev-parse --absolute-git-dir 2>/dev/null)
    if [ -z "$g" ]; then emit ERR 'Not a working repository' END "$repo"; continue; fi
    emit GITDIR "$g"
    common=$(git rev-parse --git-common-dir 2>/dev/null)
    if [ -n "$common" ]; then common=$(cd "$common" 2>/dev/null && pwd -P); [ "$common" != "$g" ] && emit GITDIR "$common"; fi
    start=$(date +%s)
    status=$(bounded_git status --porcelain=v2 --branch --untracked-files=normal 2>/dev/null)
    if [ $? -ne 0 ]; then emit ERR 'git status failed or exceeded the 10-second limit' SLOW 11 END "$repo"; continue; fi
    status_elapsed=$(($(date +%s)-start))
    printf '%s\n' "$status" | awk '
    function out(s) {printf "%s%c",s,0}
    /^# branch.oid / {oid=$3}
    /^# branch.head / {head=$3}
    /^# branch.upstream / {up=$3}
    /^# branch.ab / {a=substr($3,2); b=substr($4,2)}
    /^1 |^2 / {if(substr($2,1,1)!=".")s++; if(substr($2,2,1)!=".")m++}
    /^u / {c++}
    /^\? / {u++}
    /^[12u?] / {if(n++<20){
        path=$0; fields=($1=="1" ? 8 : $1=="2" ? 9 : $1=="u" ? 10 : 1)
        for(i=0;i<fields;i++)sub(/^[^ ]* /,"",path)
        out("PATH"); out(path)
    }}
    END {out("HEAD");out(oid);out(head);out(head=="(detached)"?1:0);
         out("COUNTS");out(a+0);out(b+0);out(s+0);out(m+0);out(u+0);out(c+0)}'
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
    op=none
    [ -f "$g/BISECT_LOG" ] && op=bisect
    [ -f "$g/REVERT_HEAD" ] && op=revert
    [ -f "$g/CHERRY_PICK_HEAD" ] && op=cherry-pick
    [ -f "$g/MERGE_HEAD" ] && op=merge
    if [ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ]; then op=rebase; fi
    emit OP "$op"
    lock=0; [ -n "$(find "$g/index.lock" -mmin +10 2>/dev/null)" ] && lock=1
    emit LOCK "$lock"
    file_age
    emit AGECLOCK "$(date +%s)"
    fingerprint=$(history_fingerprint)
    case "$fingerprint" in ''|*[!0-9a-f]*) fingerprint=;; esac
    [ -z "$fingerprint" ] || emit FINGERPRINT "$fingerprint"
    if [ -n "$fingerprint" ] && [ "$fingerprint" = "$previous_fingerprint" ]; then
        emit REUSED SLOW "$status_elapsed" END "$repo"
        continue
    fi
    # A complete bounded set above a common fetched tip lets two machines compare
    # unpublished commits without transferring Git objects or fetching either repo.
    if [ -n "$upsha" ]; then
        local_commits=$(git rev-list --max-count=201 HEAD --not "$upsha" 2>/dev/null)
        if [ $? -eq 0 ]; then
            count=$(printf '%s\n' "$local_commits" | awk 'NF {n++} END {print n+0}')
            if [ "$count" -le 200 ]; then emit LOCALCOMMITS "$local_commits"; fi
        fi
    fi
    emit STASH "$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
    emit ORIGIN "$(git remote get-url origin 2>/dev/null)" ROOT "$(git rev-list --max-parents=0 HEAD 2>/dev/null | sort | head -1)"
    emit SHALLOW "$(git rev-parse --is-shallow-repository 2>/dev/null)"
    emit LAST "$(git log -1 --format=%ct 2>/dev/null)" "$(git log -1 --format=%s 2>/dev/null)"
    git for-each-ref --count=200 --format='%(refname:short) %(objectname) %(committerdate:unix)' refs/heads | while read -r name sha epoch; do emit BRANCH "$name" "$sha" BRANCHDATE "$name" "$epoch"; done
    git for-each-ref --count=200 --format='%(refname:short) %(upstream:short)' refs/heads | while read -r name tracking; do
        a=0; b=0
        if [ -n "$tracking" ]; then
            counts=$(git rev-list --left-right --count "$name...$tracking" 2>/dev/null)
            if [ $? -eq 0 ]; then
                a=$(printf '%s' "$counts" | awk '{print $1}')
                b=$(printf '%s' "$counts" | awk '{print $2}')
            fi
        fi
        emit BRANCHWORK "$name" "$tracking" "${a:-0}" "${b:-0}"
    done
    if [ -z "$branch" ]; then emit DETACHED "$(git rev-list --count HEAD --not --branches 2>/dev/null)"; fi
    # Only hex object IDs are accepted. Unknown objects are not evidence of divergence.
    for sha in $peers; do
        case "$sha" in (''|*[!a-fA-F0-9]*) continue;; esac
        if git cat-file -e "$sha^{commit}" 2>/dev/null; then
            if ! git merge-base HEAD "$sha" >/dev/null 2>&1; then emit PEER "$sha" unknown 0 0; continue; fi
            counts=$(git rev-list --left-right --count "HEAD...$sha" 2>/dev/null)
            left=$(printf '%s' "$counts" | awk '{print $1}')
            right=$(printf '%s' "$counts" | awk '{print $2}')
            if [ -n "$left" ] && [ -n "$right" ]; then
                rel=diverged
                if [ "$left" = 0 ] && [ "$right" = 0 ]; then rel=same
                elif [ "$left" = 0 ]; then rel=behind
                elif [ "$right" = 0 ]; then rel=ahead; fi
                emit PEER "$sha" "$rel" "$left" "$right"
            fi
        else emit PEER "$sha" unknown 0 0; fi
    done
    if [ -n "$fingerprint" ] && [ "$(history_fingerprint)" != "$fingerprint" ]; then emit FINGERPRINT ''; fi
    emit SLOW "$status_elapsed" END "$repo"
done
emit CLOCKEND "$(date +%s)"
