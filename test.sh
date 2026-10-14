#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift test --package-path "$PROJECT_DIR" \
  --cache-path "$PROJECT_DIR/.build/cache" \
  --config-path "$PROJECT_DIR/.build/config" \
  --security-path "$PROJECT_DIR/.build/security" "$@"
