#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${CONFIGURATION:-release}
./scripts/swift.sh build -c "$configuration" --product RepobotApp
./scripts/swift.sh build -c "$configuration" --product repobot
bin=$(./scripts/swift.sh build -c "$configuration" --show-bin-path)
mkdir -p "$PWD/dist"
staging=$(mktemp -d "$PWD/dist/.repobot-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Repobot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/RepobotApp" "$app/Contents/MacOS/RepobotApp"
cp "$bin/repobot" "$app/Contents/MacOS/repobot"
cp Sources/RepobotApp/Info.plist "$app/Contents/Info.plist"
iconutil -c icns assets/icons/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
./scripts/compile-app-icon.sh "$app"
cp assets/icons/MenuBarGlyph.svg "$app/Contents/Resources/MenuBarGlyph.svg"
# Put script resources in the app's Resources directory; Scripts.load also supports
# SwiftPM's generated bundle accessor for CLI and Xcode builds.
rm -rf "$app/Contents/MacOS/Repobot_RepobotCore.bundle"
rm -rf "$app/Contents/Resources/RepobotCore"
mkdir -p "$app/Contents/Resources/RepobotCore"
# SwiftPM's native and Swift Build backends use different macOS bundle layouts.
resource_directory="$bin/Repobot_RepobotCore.bundle/Resources"
if [[ ! -f "$resource_directory/probe.sh" ]]; then
  resource_directory="$bin/Repobot_RepobotCore.bundle/Contents/Resources/Resources"
fi
for resource in probe.sh upstream.sh discover.sh capabilities.sh watcher.py cost.sh; do
  cp "$resource_directory/$resource" "$app/Contents/Resources/RepobotCore/$resource"
done
codesign --force --deep --sign "${SIGN_IDENTITY:--}" --options runtime --entitlements Repobot.entitlements "$app"
codesign --verify --deep --strict "$app"
# Replace the bundle only after verification. Never overwrite the executable inode
# of a running app: macOS would terminate it with an invalid-code-signature fault.
destination="$PWD/dist/Repobot.app"
if [[ -e "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app" "$destination"; then
  [[ ! -e "$staging/previous.app" ]] || mv "$staging/previous.app" "$destination"
  exit 1
fi
printf '%s\n' "$destination"
