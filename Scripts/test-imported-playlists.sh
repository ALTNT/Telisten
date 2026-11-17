#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/telisten-import-build.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -module-cache-path "$test_directory/module-cache" -swift-version 6 -parse-as-library \
  Telisten/Core/Models.swift Telisten/Core/ImportedPlaylist.swift \
  Telisten/Storage/ImportedPlaylistStore.swift Tests/ImportedPlaylistTests.swift \
  -o "$test_directory/import-tests"
"$test_directory/import-tests" "$@"
if [ "${1:-}" = "--live" ]; then exit 0; fi
python3 - "$test_directory/playback-tests.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Telisten/App/AppModel.swift").read_text()
start = source.index("    @discardableResult\n    func saveImportedPlaylist(")
end = source.index("    func loadMoreTracks()", start)
fixture = Path("Tests/ImportedPlaybackTests.swift").read_text()
fixture = fixture.replace("    // IMPORTED_PLAYBACK_METHODS", source[start:end])
telegram = Path("Telisten/Telegram/TelegramService.swift").read_text()
start = telegram.index("    func resolveImportedMusic(")
end = telegram.index("    func searchBotChat(", start)
Path(sys.argv[1]).write_text(fixture.replace("    // IMPORTED_RESOLVER_METHOD", telegram[start:end]))
PY
xcrun swiftc -module-cache-path "$test_directory/module-cache" -swift-version 6 -parse-as-library \
  Telisten/Core/Models.swift Telisten/Core/ImportedPlaylist.swift \
  Telisten/Storage/ImportedPlaylistStore.swift "$test_directory/playback-tests.swift" \
  -o "$test_directory/playback-tests"
"$test_directory/playback-tests"
