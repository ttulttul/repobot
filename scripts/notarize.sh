#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"
./scripts/build-app.sh
archive="$PWD/dist/Repobot.zip"
ditto -c -k --keepParent dist/Repobot.app "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Repobot.app
xcrun stapler validate dist/Repobot.app
# Refresh the distributable archive to include its stapled ticket.
ditto -c -k --keepParent dist/Repobot.app "$archive"
printf '%s\n' "$archive"
