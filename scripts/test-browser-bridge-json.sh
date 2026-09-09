#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/macidm-swift-cache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/macidm-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/macidm-swiftpm-cache}" \
swift test --disable-sandbox --filter BrowserBridgeJSONTests

SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/macidm-swift-cache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/macidm-clang-cache}" \
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/macidm-swiftpm-cache}" \
swift test --disable-sandbox --filter MessageProtocolTests

echo "Browser bridge JSON fixtures and authenticated UDS transport passed."
