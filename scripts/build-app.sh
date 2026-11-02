#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Seamline.app into ./build.
#
#   ./scripts/build-app.sh          build/Seamline.app
#   ./scripts/build-app.sh --zip    also write build/Seamline-<version>.zip for a release
#
# The version comes from $VERSION, else the latest git tag, else 0.1.0.
# Signing with a stable identity matters: macOS ties Accessibility and Input Monitoring
# grants to the signature, so an ad-hoc build loses them on every rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/Seamline.app"

ZIP=0
for arg in "$@"; do
  case $arg in
    --zip) ZIP=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --arch arm64 --arch x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/apple/Products/Release/Seamline" "$APP/Contents/MacOS/Seamline"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The icon is drawn by scripts/make-icon.swift and cached in build/ until that script changes.
ICNS="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICNS" || "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]]; then
  rm -rf "$ROOT/build/AppIcon.iconset" && mkdir -p "$ROOT/build/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/build/icon-1024.png" --out "$ROOT/build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/build/icon-1024.png" --out "$ROOT/build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

IDENTITY="${SEAMLINE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES=("${(@f)$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2}')}")
  IDENTITIES=(${IDENTITIES:#})
  if (( ${#IDENTITIES} > 0 )); then
    IDENTITY=$IDENTITIES[1]
    if (( ${#IDENTITIES} > 1 )); then
      echo "Several signing identities found; using the first. Pick one with SEAMLINE_SIGN_IDENTITY:"
      printf '  %s\n' "${IDENTITIES[@]}"
    fi
  fi
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No signing identity found; signing ad-hoc. Permissions will need re-granting after each rebuild."
  IDENTITY="-"
fi

if ! codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signing with \"$IDENTITY\" failed (is the login keychain locked?). Falling back to ad-hoc."
  IDENTITY="-"
  codesign --force --options runtime --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Seamline"))"
echo "Signed by: $([[ $IDENTITY == "-" ]] && echo ad-hoc || echo "$IDENTITY")"

if (( ZIP )); then
  rm -f "build/Seamline-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "build/Seamline-$VERSION.zip"
  echo "Packed build/Seamline-$VERSION.zip"
fi
