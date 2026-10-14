#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART_DIR="$PROJECT_DIR/.build/branding"
mkdir -p "$ART_DIR/ModuleCache"
xcrun swiftc -module-cache-path "$ART_DIR/ModuleCache" \
  "$PROJECT_DIR/Sources/Uptimelet/BeaconIcon.swift" \
  "$PROJECT_DIR/scripts/render-icons.swift" -o "$ART_DIR/render-icons"
"$ART_DIR/render-icons" "$ART_DIR/AppIcon.iconset" "$PROJECT_DIR/Resources/Branding"
cp "$ART_DIR/AppIcon.icns" "$PROJECT_DIR/Resources/AppIcon.icns"
echo "Rendered AppIcon.icns and branding previews."
