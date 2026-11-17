#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/telisten-foreground-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
# Exercise the production actor methods without real accounts or a TDLib database.
python3 - "$test_directory/foreground-tests.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Telisten/Telegram/TelegramService.swift").read_text()
start = source.index("    func recoverConnectionAfterStandby()")
end = source.index("    // Read TDLib's actual state", start)
fixture = Path("Tests/ForegroundConnectionTests.swift").read_text()
fixture = fixture.replace("    // FOREGROUND_CONNECTION_METHODS", source[start:end])
app = Path("Telisten/App/AppModel.swift").read_text()
start = app.index("    func applicationDidEnterBackground()")
end = app.index("    private func resumePendingDownload(", start)
fixture = fixture.replace("    // FOREGROUND_APP_METHODS", app[start:end])
Path(sys.argv[1]).write_text(fixture)
PY
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$test_directory/modules" \
  Telisten/Core/VideoModels.swift "$test_directory/foreground-tests.swift" -o "$test_directory/foreground-tests"
python3 - "$test_directory/foreground-tests" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=60)
PY
