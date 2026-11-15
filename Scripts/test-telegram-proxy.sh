#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/telisten-proxy-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$test_directory/modules" \
  Telisten/Core/TelegramProxyConfiguration.swift Tests/TelegramProxyTests.swift \
  -o "$test_directory/proxy-tests"
"$test_directory/proxy-tests"
