#!/bin/bash
# Run the Swift test suite.
#
# With full Xcode, plain `swift test` finds the Testing framework by itself.
# With Command Line Tools only, the framework and its macro plugin live under
# the developer dir but SwiftPM doesn't add them — pass the paths explicitly.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
PLUGINS="$DEV_DIR/usr/lib/swift/host/plugins/testing"

if [[ "$DEV_DIR" == *CommandLineTools* && -d "$FRAMEWORKS/Testing.framework" && -d "$PLUGINS" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$DEV_DIR/Library/Developer/usr/lib" \
        "$@"
fi

exec swift test "$@"
