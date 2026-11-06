#!/bin/zsh
# Every check a change should pass, run on this Mac. There is no hosted CI.
#
#   ./scripts/ci.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "› Toolchain"
xcodebuild -version | sed -n 1p
swift --version 2>&1 | sed -n 1p

echo "› Unit tests"
swift test

echo "› Universal build"
./scripts/build-app.sh --zip

echo "› Smoke test"
codesign --verify --strict build/Seamline.app
lipo -archs build/Seamline.app/Contents/MacOS/Seamline | grep -q x86_64
lipo -archs build/Seamline.app/Contents/MacOS/Seamline | grep -q arm64

echo "✓ All checks passed"
