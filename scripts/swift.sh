#!/bin/bash
set -euo pipefail
# Standard installations use their selected toolchain. The opt-in fallback is useful
# when Xcode's launcher cannot load but its compiler and a stable CLT SDK still work.
fallback=${REPOBOT_TOOLCHAIN_FALLBACK:-auto}
if [[ $fallback == auto ]]; then
  fallback=0
  if ! xcodebuild -sdk macosx -find swift >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk && -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift ]]; then
    fallback=1
  fi
fi
if [[ $fallback == 1 ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  toolchain=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  sdk=${REPOBOT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
  action=${1:-build}; shift || true
  framework=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
  libraries=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
  exec "$toolchain" "$action" --build-system native --sdk "$sdk" \
    -Xswiftc -F -Xswiftc "$framework" -Xswiftc -I -Xswiftc "$libraries" \
    -Xlinker -rpath -Xlinker "$framework" -Xlinker -rpath -Xlinker "$libraries" \
    -Xlinker -F -Xlinker "$framework" -Xlinker -L -Xlinker "$libraries" "$@"
else
  exec swift "$@"
fi
