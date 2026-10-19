#!/bin/zsh
# Release-builds Tunelet and installs it to ~/Applications, replacing any previous copy.
#
#   scripts/install.sh           install
#   scripts/install.sh --open    install, then launch it
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh release

if pgrep -x Tunelet >/dev/null; then
  echo "Quitting the running Tunelet…"
  osascript -e 'tell application id "com.craigmaslowski.Tunelet" to quit' || true
  for _ in {1..50}; do pgrep -x Tunelet >/dev/null || break; sleep 0.1; done
fi

destination="$HOME/Applications/Tunelet.app"
mkdir -p "$HOME/Applications"
rm -rf "$destination"
ditto build/Tunelet.app "$destination"
codesign --verify --strict "$destination"
echo "Installed $destination"

if [[ "${1:-}" == "--open" ]]; then
  open "$destination"
fi
