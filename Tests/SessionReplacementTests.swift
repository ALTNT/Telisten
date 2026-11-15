import Foundation

// The test script inserts the production method below. The surrounding fakes
// avoid Telegram requests and real Keychain writes while exercising file moves.
private enum PlaybackDiagnostics {
    static func log(_ event: String, error: Error? = nil) {}
}

private final class SessionTestKeychain: @unchecked Sendable {
    var allowsCopy = true
    func copyTDLibDatabaseKey(from: String, to: String) -> Bool { allowsCopy }
    func setTDLibAccount(_ id: String, authorized: Bool) -> Bool { true }
}

private actor SessionReplacementHarness {
    enum ServiceError: Error { case sessionPersistenceFailed, sessionReplacementFailed }
    var accountID = "new"
    var replacingSession = false
    var authorizationState: Int?
    let keychain = SessionTestKeychain()
    let root: URL
    var authorizationDefaultsKey: String { "telisten.session-test." + root.lastPathComponent }

    init(root: URL, allowsCopy: Bool) {
        self.root = root
        keychain.allowsCopy = allowsCopy
    }

    func storageURL(for id: String) -> URL { root.appendingPathComponent(id) }
    func closeClient() async {}

    // SESSION_REPLACEMENT_METHOD
}

@main
private enum SessionReplacementTests {
    static func main() async throws {
        // A new process has no remembered database-failure state. Existing
        // sessions must still be backed up after the same user reauthorizes.
        for (hasOld, hasNew, allowsCopy, succeeds) in [
            (true, true, true, true),
            (false, true, true, true),
            (true, true, false, false),
            (true, false, true, false)
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("telisten-session-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                UserDefaults.standard.removeObject(forKey: "telisten.session-test." + root.lastPathComponent)
            }
            for (name, contents, exists) in [("old", "original database", hasOld), ("new", "authorized database", hasNew)] where exists {
                let directory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: directory.appendingPathComponent("td.binlog"))
            }
            let harness = SessionReplacementHarness(root: root, allowsCopy: allowsCopy)
            var succeeded = false
            do {
                try await harness.replaceCurrentSession(withAccountID: "old")
                succeeded = true
            } catch let error as SessionReplacementHarness.ServiceError {
                switch error {
                case .sessionPersistenceFailed: precondition(!allowsCopy && hasNew)
                case .sessionReplacementFailed: precondition(!hasNew)
                }
            }
            precondition(succeeded == succeeds)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let backups = names.filter { $0.hasPrefix("old-backup-") }
            if succeeds {
                let current = try String(contentsOf: root.appendingPathComponent("old/td.binlog"), encoding: .utf8)
                precondition(current == "authorized database")
                precondition(backups.count == (hasOld ? 1 : 0))
                if hasOld {
                    let backup = try String(contentsOf: root.appendingPathComponent(backups[0] + "/td.binlog"), encoding: .utf8)
                    precondition(backup == "original database")
                }
            } else {
                let original = try String(contentsOf: root.appendingPathComponent("old/td.binlog"), encoding: .utf8)
                precondition(original == "original database")
                precondition(backups.isEmpty)
                if hasNew {
                    let pending = try String(contentsOf: root.appendingPathComponent("new/td.binlog"), encoding: .utf8)
                    precondition(pending == "authorized database")
                }
            }
        }
        print("Session replacement: fresh-process backup, new destination, key-copy rollback, and missing-source errors passed")
    }
}
