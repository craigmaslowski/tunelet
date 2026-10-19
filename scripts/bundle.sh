#!/bin/zsh
# Builds build/Tunelet.app from the Swift package.
#
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
#
# Signing identity, first match wins:
#   1. $TUNELET_SIGN_IDENTITY
#   2. the first line of .signing-identity in the repo root (gitignored)
#   3. ad-hoc, with a warning: ad-hoc signatures change on every build, so macOS asks for
#      microphone access again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config" --product Tunelet
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Tunelet.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Tunelet" "$app/Contents/MacOS/Tunelet"
cp Bundle/Info.plist "$app/Contents/Info.plist"

identity="${TUNELET_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -f .signing-identity ]]; then
  identity="$(head -n 1 .signing-identity)"
fi
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --identifier com.craigmaslowski.Tunelet "$app"
  echo "Built $app (signed: $identity)"
else
  codesign --force --sign - --identifier com.craigmaslowski.Tunelet "$app"
  echo "Built $app (signed: ad-hoc)"
  echo "warning: no signing identity set; macOS may ask for microphone access again after each rebuild." >&2
fi
