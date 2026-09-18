#!/bin/sh
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ASKPASS= SSH_ASKPASS= SSH_ASKPASS_REQUIRE=never LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
# Arguments: one root, then repositories whose nested repositories must not be reported.
# BFS across all four levels; pruning .git itself avoids walking object databases.
first=$1; shift
for root in "$first"; do
    case "$root" in '~') root=$HOME;; '~/'*) root=$HOME/${root#\~/};; esac
    [ -d "$root" ] || continue
    root=$(cd "$root" && pwd -P)
    if [ -e "$root/.git" ]; then printf '%s\000' "$root"; fi
    # find -exec avoids newline-delimited filenames and shell interpolation.
    for depth in 2 3 4 5; do
        find "$root" -maxdepth "$depth" \( -name node_modules -o -name .venv -o -name vendor -o -name target -o -name build -o -name Library -o -name .Trash \) -prune -o -name .git -prune -exec sh -c '
            depth=$1; root=$2; containers=$3; shift 3
            skip=$containers
            for marker do
                # The containers precede the markers in the positional parameters.
                if [ "$skip" -gt 0 ]; then skip=$((skip-1)); continue; fi
                remaining=$containers; nested=0
                for container do
                    [ "$remaining" -gt 0 ] || break
                    remaining=$((remaining-1))
                    case "${marker%/.git}" in "$container"/*) nested=1;; esac
                done
                [ "$nested" -eq 0 ] || continue
                rel=${marker#"$root"/}; count=$(printf "%s" "$rel" | tr -cd / | wc -c | tr -d " ")
                [ "$count" -eq "$((depth-1))" ] || continue
                repo=${marker%/.git}
                parent=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null)
                [ -z "$parent" ] && printf "%s\000" "$repo"
            done
        ' sh "$depth" "$root" "$#" "$@" {} + 2>/dev/null
    done
done
