#!/bin/zsh
# Runs the test suite.
#
# With only the Command Line Tools installed (no Xcode) and a macOS 26 deployment target,
# SwiftPM's default build engine intermittently compiles tests with an explicit plugin list
# that omits Swift Testing's macro plugin ("plugin for module 'TestingMacros' not found").
# Adding the toolchain's testing plugin directory as a search path makes the build reliable.
set -euo pipefail
cd "$(dirname "$0")/.."
plugins="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
# --no-parallel: the analyzer timing test needs CPU time; running alongside the (unoptimised)
# full-pipeline detector tests starves its timer and makes it flaky.
exec swift test --no-parallel -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
