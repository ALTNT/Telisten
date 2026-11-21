#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/telisten-import-build.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -module-cache-path "$test_directory/module-cache" -swift-version 6 -parse-as-library \
  Telisten/Core/Models.swift Telisten/Core/ImportedPlaylist.swift Telisten/Core/ImportedPlaylistSync.swift \
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
start = source.index("    private func saveImportedPlaylistState(")
end = source.index("    private func recordImportedBotSelection()", start)
fixture = fixture.replace("    // IMPORTED_SAVE_METHOD", source[start:end])
telegram = Path("Telisten/Telegram/TelegramService.swift").read_text()
start = telegram.index("    func setImportedMusicForeground(")
end = telegram.index("    func searchBotChat(", start)
Path(sys.argv[1]).write_text(fixture.replace("    // IMPORTED_RESOLVER_METHOD", telegram[start:end]))
PY
xcrun swiftc -module-cache-path "$test_directory/module-cache" -swift-version 6 -parse-as-library \
  Telisten/Core/Models.swift Telisten/Core/ImportedPlaylist.swift Telisten/Core/ImportedPlaylistSync.swift \
  Telisten/Core/Formatting.swift Telisten/Storage/ImportedPlaylistStore.swift "$test_directory/playback-tests.swift" \
  -o "$test_directory/playback-tests"
"$test_directory/playback-tests"
xcrun swiftc -module-cache-path "$test_directory/module-cache" -swift-version 6 -parse-as-library \
  Telisten/Core/Models.swift Telisten/Core/ImportedPlaylist.swift Telisten/Core/ImportedPlaylistSync.swift \
  Telisten/Storage/ImportedPlaylistStore.swift Tests/ImportedPlaylistSyncTests.swift \
  -o "$test_directory/sync-tests"
"$test_directory/sync-tests"
python3 - "$test_directory/sync-transport-tests.swift" <<'PY'
from pathlib import Path
import sys
fixture = Path("Tests/ImportedSyncTransportTests.swift").read_text()
telegram = Path("Telisten/Telegram/TelegramService.swift").read_text()
start = telegram.index("    private func importedSyncChannelDescription(")
end = telegram.index("    private func checkImportedSyncAccount(", start)
fixture = fixture.replace("    // IMPORTED_CHANNEL_VALIDATION", telegram[start:end])
start = telegram.index("    func pullFavoriteSync(")
end = telegram.index("    private func pullSyncDocuments", start)
favorites = telegram[start:end]
start = telegram.index("    private func readSyncDocument(")
end = telegram.index("    func pushImportedPlaylistSync(", start)
fixture = fixture.replace("    // FAVORITE_DOCUMENT_TRANSPORT", favorites + telegram[start:end])
app = Path("Telisten/App/AppModel.swift").read_text()
start = app.index("    func syncImportedPlaylists()")
end = app.index("    private func restoreImportedPlaylistSync()", start)
fixture = fixture.replace("    // IMPORTED_SYNC_COORDINATOR", app[start:end])
start = app.index("    private func checkImportedPlaylistSync(")
end = app.index("    private func applyImportedPlaylistSyncState(", start)
fixture = fixture.replace("    // IMPORTED_SYNC_ACCOUNT_CHECK", app[start:end])
start = app.index("    private func recordFavoriteChanges(")
end = app.index("    // Keep the visible library and its outbox", start)
fixture = fixture.replace("    // FAVORITE_SYNC_METHODS", app[start:end])
Path(sys.argv[1]).write_text(fixture)
PY
xcrun swiftc -module-cache-path "$test_directory/module-cache" -swift-version 6 -parse-as-library \
  Telisten/Core/Models.swift Telisten/Core/ImportedPlaylist.swift Telisten/Core/ImportedPlaylistSync.swift \
  Telisten/Storage/ImportedPlaylistStore.swift "$test_directory/sync-transport-tests.swift" \
  -o "$test_directory/sync-transport-tests"
"$test_directory/sync-transport-tests"
