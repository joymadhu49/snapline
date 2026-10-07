#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/Tests
swiftc -parse-as-library \
    Sources/Core/CaptureEngine.swift \
    Sources/Overlay/SelectionOverlay.swift \
    Sources/Overlay/HUD.swift \
    Tests/FreezeSelection.swift \
    -o build/Tests/FreezeSelectionTest
exec build/Tests/FreezeSelectionTest
