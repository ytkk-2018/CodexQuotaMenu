#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p "Codex Quota.app/Contents/MacOS"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/codex-quota-clang-cache"
export SWIFT_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/codex-quota-swift-cache"
swiftc -O -framework AppKit Sources/main.swift -o "Codex Quota.app/Contents/MacOS/CodexQuota"
cp Info.plist "Codex Quota.app/Contents/Info.plist"
echo "Built: ${PWD}/Codex Quota.app"
