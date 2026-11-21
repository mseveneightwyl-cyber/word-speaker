#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/Selection.swift Tests/main.swift -o .build/selection-tests
.build/selection-tests
if [[ "${1:-}" == "--ui" ]]; then
    dist/划词即听·声音版.app/Contents/MacOS/WordSpeaker --ui-smoke-test
fi
