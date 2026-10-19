#!/bin/zsh
# Builds build/Tunelet.app from the Swift package.
#
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
#
# Signing: uses the identity in $TUNELET_SIGN_IDENTITY if set, otherwise ad-hoc. Ad-hoc signatures
# change on every build, so macOS may ask for microphone access again after each rebuild.
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

identity="${TUNELET_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier com.craigmaslowski.Tunelet "$app"
echo "Built $app (signed: ${TUNELET_SIGN_IDENTITY:-ad-hoc})"
