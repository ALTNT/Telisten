#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/telisten-video-build.XXXXXX")
trap 'rm -f "$test_directory/video-tests"; rmdir "$test_directory"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  Telisten/Core/VideoModels.swift Telisten/Player/StreamingAudioResource.swift \
  Tests/VideoTests.swift -o "$test_directory/video-tests"
python3 - "$test_directory/video-tests" <<'PYTEST'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=60)
PYTEST
