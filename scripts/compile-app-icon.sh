#!/bin/bash
# Compile the layered icon when Xcode supports it; CLT-only builds retain ICNS.
set -euo pipefail
cd "$(dirname "$0")/.."
app=${1:?Usage: compile-app-icon.sh /absolute/path/to/Repobot.app}
mode=${REPOBOT_LAYERED_ICON:-auto}
case "$mode" in auto|0|1) ;; *) printf 'REPOBOT_LAYERED_ICON must be auto, 0, or 1\n' >&2; exit 2;; esac
[[ "$mode" != 0 ]] || exit 0
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
developer=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
compiler=${ACTOOL:-$developer/usr/bin/actool}
mkdir -p "$scratch/compiled"
if [[ -x "$compiler" ]] && "$compiler" assets/icons/AppIcon.icon \
    --compile "$scratch/compiled" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist "$scratch/icon-info.plist" \
    >"$scratch/compiler.log" 2>&1 && [[ -f "$scratch/compiled/Assets.car" ]]; then
  cp -R "$scratch/compiled/." "$app/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Merge '$scratch/icon-info.plist'" "$app/Contents/Info.plist"
  printf 'Included layered AppIcon and generated compatibility icon.\n'
else
  printf 'Layered icon compilation unavailable; retaining the legacy AppIcon.icns.\n' >&2
  [[ ! -f "$scratch/compiler.log" ]] || cat "$scratch/compiler.log" >&2
  if [[ "$mode" == 1 ]]; then
    printf 'REPOBOT_LAYERED_ICON=1 requires a working Xcode 26+ asset compiler.\n' >&2
    exit 1
  fi
fi
