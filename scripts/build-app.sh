#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Seamline.app into ./build.
# Signing with a stable identity matters: macOS ties Accessibility and Input Monitoring
# grants to the signature, so an ad-hoc build loses them on every rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/Seamline.app"

swift build -c release --arch arm64 --arch x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/apple/Products/Release/Seamline" "$APP/Contents/MacOS/Seamline"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

IDENTITY="${SEAMLINE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No signing identity found; signing ad-hoc. Permissions will need re-granting after each rebuild."
  IDENTITY="-"
fi

if ! codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signing with \"$IDENTITY\" failed (is the login keychain locked?). Falling back to ad-hoc."
  codesign --force --options runtime --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/Seamline"
