#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="Uptimelet"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/Desktop}"
ARCHIVE="${ARCHIVE_PATH:-$OUTPUT_ROOT/Uptimelet.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-$OUTPUT_ROOT/UptimeletExport}"
DERIVED_DATA="${DERIVED_DATA_PATH:-$PROJECT_DIR/.build/xcode}"

echo "==> Archiving $SCHEME for Intel and Apple silicon..."
xcodebuild \
  -project "$PROJECT_DIR/Uptimelet.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  ARCHS='x86_64 arm64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  archive

echo "==> Exporting .app..."
mkdir -p "$EXPORT_DIR"
APP="$EXPORT_DIR/Uptimelet.app"
ditto "$ARCHIVE/Products/Applications/Uptimelet.app" "$APP"
# Local builds need no Apple developer account. Set SIGNING_IDENTITY to a
# Developer ID Application identity to sign a distributable app instead.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --timestamp=none --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/Uptimelet" -verify_arch x86_64 arm64

echo
echo "Done. Universal app exported to: $APP"
echo "Install:  cp -R \"$APP\" /Applications/"
echo "Launch:   open /Applications/Uptimelet.app"
