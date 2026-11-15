#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/telisten-session-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
python3 - "$test_directory/session-tests.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Telisten/Telegram/TelegramService.swift").read_text()
start = source.index("    func replaceCurrentSession(")
end = source.index("    func loadChats()", start)
fixture = Path("Tests/SessionReplacementTests.swift").read_text()
Path(sys.argv[1]).write_text(fixture.replace("    // SESSION_REPLACEMENT_METHOD", source[start:end]))
PY
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$test_directory/modules" \
  "$test_directory/session-tests.swift" -o "$test_directory/session-tests"
"$test_directory/session-tests"
