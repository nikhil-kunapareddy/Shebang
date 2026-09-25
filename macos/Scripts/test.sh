#!/bin/bash
# Runs the Swift Testing suites. With only the Command Line Tools installed, the Testing
# framework lives outside the default search path, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
    FW="$DEV_DIR/Library/Developer/Frameworks"
    LIB="$DEV_DIR/Library/Developer/usr/lib"
    FLAGS=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW"
           -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB")
fi

swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
