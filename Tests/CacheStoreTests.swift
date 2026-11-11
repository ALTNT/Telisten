import Foundation

@main
enum CacheStoreTests {
    actor RangeRequests {
        var offsets: [Int64] = []

        func record(_ offset: Int64) {
            offsets.append(offset)
        }
    }

    static func track(_ id: Int64, size: Int64 = 1024) -> Track {
        Track(documentID: id, accessHash: 1, fileReference: Data(), dcID: 2,
              messageID: id, chatID: "c:1", title: "Offline \(id)", artist: "Test",
              fileName: "offline.mp3", mimeType: "audio/mpeg", duration: 10,
              size: size, date: .now)
    }

    static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appending(path: "telisten-cache-tests-\(UUID())")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let root = sandbox.appending(path: "Application Support/Telisten/Audio")
        let legacy = sandbox.appending(path: "Caches/Telisten")
        try fm.createDirectory(at: legacy.appending(path: "Artwork"), withIntermediateDirectories: true)
        try Data([1]).write(to: legacy.appending(path: "Artwork/keep.image"))

        let song = track(1)
        let audio = Data(repeating: 0x42, count: Int(song.size))
        let oldFile = legacy.appending(path: "2-1.mp3")
        try audio.write(to: oldFile)
        let entry = CacheStore.Entry(trackID: song.id, fileName: "2-1.mp3", byteCount: song.size, lastAccess: .now)
        // Duplicate old records must not crash launch.
        try JSONEncoder().encode([entry, entry]).write(to: legacy.appending(path: "cache-index.json"))
        try audio.write(to: legacy.appending(path: "2-2.mp3"))
        let cache = CacheStore(rootURL: root, legacyURL: legacy)
        precondition(cache.initialCachedTrackIDs == [song.id, track(2).id])
        let url = await cache.localURL(for: song)
        let migratedBytes = try Data(contentsOf: url!)
        precondition(migratedBytes == audio)
        precondition(fm.fileExists(atPath: legacy.appending(path: "Artwork/keep.image").path))
        precondition(!fm.fileExists(atPath: oldFile.path))
        let rootValues = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        precondition(rootValues.isExcludedFromBackup == true)

        let downloaded = track(3)
        let temporary = await cache.partialLocation(for: downloaded).dataURL
        try audio.write(to: temporary)
        _ = try await cache.commit(temporary, track: downloaded)
        let relaunched = CacheStore(rootURL: root)
        precondition(relaunched.initialDownloadedTracks[downloaded.id] == downloaded)
        let downloadedURL = await relaunched.localURL(for: downloaded)
        let downloadedBytes = try Data(contentsOf: downloadedURL!)
        precondition(downloadedBytes == audio)
        _ = try await relaunched.commit(temporary, track: downloaded)
        precondition(fm.fileExists(atPath: downloadedURL!.path), "A duplicate commit must not delete the original")

        // An unreadable central index and missing library metadata must not hide
        // committed audio; per-file records restore the whole track offline.
        try Data("broken index".utf8).write(to: root.appending(path: "cache-index.json"))
        try fm.removeItem(at: legacy)
        let recovered = CacheStore(rootURL: root)
        precondition(recovered.initialDownloadedTracks[downloaded.id] == downloaded)
        precondition(recovered.initialCachedTrackIDs.contains(downloaded.id))

        // TDLib file IDs can change while the remote file remains the same.
        // Reusing the old filename must not recover a second entry on relaunch.
        let reusedRoot = sandbox.appending(path: "reused-audio")
        let reusedCache = CacheStore(rootURL: reusedRoot)
        var original = track(20)
        original.remoteUniqueID = "same-remote-audio"
        let originalTemporary = await reusedCache.partialLocation(for: original).dataURL
        try audio.write(to: originalTemporary)
        let originalURL = try await reusedCache.commit(originalTemporary, track: original)
        var refreshed = original
        refreshed.documentID = 21
        let reusedURL = await reusedCache.localURL(for: refreshed)
        precondition(reusedURL == originalURL)
        let reusedAfterLaunch = CacheStore(rootURL: reusedRoot)
        precondition(reusedAfterLaunch.initialCachedTrackIDs == [refreshed.id],
                     "An audio file reused under a new ID must only be recovered once")
        let reusedItems = await reusedAfterLaunch.cachedAudioItems()
        let reusedBytes = await reusedAfterLaunch.totalBytes()
        precondition(reusedItems.count == 1 && reusedBytes == original.size,
                     "Reused audio must not duplicate cache rows or byte counts")

        // Repair duplicate indexes and sidecar records left by older versions.
        let staleEntry = CacheStore.Entry(trackID: original.id, fileName: originalURL.lastPathComponent,
                                          byteCount: original.size, lastAccess: .distantPast, track: original)
        let currentEntry = CacheStore.Entry(trackID: refreshed.id, fileName: originalURL.lastPathComponent,
                                            byteCount: refreshed.size, lastAccess: .now, track: refreshed)
        try JSONEncoder().encode([staleEntry, currentEntry]).write(to: reusedRoot.appending(path: "cache-index.json"))
        let staleRecord = reusedRoot.appending(path: "2-20.audio.json")
        try JSONEncoder().encode(staleEntry).write(to: staleRecord)
        let repaired = CacheStore(rootURL: reusedRoot)
        precondition(repaired.initialCachedTrackIDs == [refreshed.id])
        precondition(repaired.initialDownloadedTracks[refreshed.id] == refreshed)
        precondition(repaired.initialByteCount == original.size)
        precondition(!fm.fileExists(atPath: staleRecord.path))
        try Data("broken index".utf8).write(to: reusedRoot.appending(path: "cache-index.json"))
        let repairedAgain = CacheStore(rootURL: reusedRoot)
        precondition(repairedAgain.initialCachedTrackIDs == [refreshed.id],
                     "Recovery records must not bring back duplicate entries")
        let originalAgain = await repairedAgain.localURL(for: original)
        precondition(originalAgain == originalURL, "Both TDLib IDs must reuse the same local audio")
        let originalAfterLaunch = CacheStore(rootURL: reusedRoot)
        precondition(originalAfterLaunch.initialCachedTrackIDs == [original.id])
        try await originalAfterLaunch.remove(original)
        precondition(!fm.fileExists(atPath: originalURL.path))
        precondition(CacheStore(rootURL: reusedRoot).initialCachedTrackIDs.isEmpty)

        // Cold-cache playback and a download started immediately must share
        // in-flight range requests and produce one complete audio file.
        let coldCache = CacheStore(rootURL: sandbox.appending(path: "cold-playback"))
        let coldTrack = track(30, size: 3 * 1024 * 1024)
        let coldLocation = await coldCache.partialLocation(for: coldTrack)
        let requests = RangeRequests()
        let coldTransfer = ProgressiveAudioTransfer(
            trackID: coldTrack.id, fileSize: coldTrack.size, location: coldLocation
        ) { offset, count, _ in
            await requests.record(offset)
            await Task.yield()
            return Data(repeating: 0x66, count: Int(count))
        }
        async let coldDownload: Void = coldTransfer.downloadAll { _ in }
        async let coldPlayback = coldTransfer.bytes(at: 0, length: 256 * 1024)
        let (_, coldBytes) = try await (coldDownload, coldPlayback)
        precondition(coldBytes == Data(repeating: 0x66, count: 256 * 1024))
        let fetchedOffsets = await requests.offsets
        let expectedOffsets: [Int64] = [0, 1024 * 1024, 2 * 1024 * 1024]
        precondition(fetchedOffsets.sorted() == expectedOffsets,
                     "Concurrent streaming and downloading must fetch each range only once")
        let coldURL = try await coldCache.commit(coldLocation.dataURL, track: coldTrack)
        await coldTransfer.didCommit(to: coldURL)
        let coldCachedURL = await coldCache.localURL(for: coldTrack)
        precondition(coldCachedURL == coldURL)

        // Persist partial bytes across launch without fetching them a second time.
        let partialTrack = track(4, size: 1024 * 1024)
        let location = await recovered.partialLocation(for: partialTrack)
        let transfer = ProgressiveAudioTransfer(trackID: partialTrack.id, fileSize: partialTrack.size, location: location) { _, count, _ in
            Data(repeating: 0x55, count: Int(count))
        }
        let firstChunk = try await transfer.bytes(at: 0, length: 512 * 1024)
        let resumed = ProgressiveAudioTransfer(trackID: partialTrack.id, fileSize: partialTrack.size, location: location) { _, _, _ in
            fatalError("Cached partial bytes must not be requested from Telegram again")
        }
        let resumedChunk = try await resumed.bytes(at: 0, length: 512 * 1024)
        precondition(resumedChunk == firstChunk)
        precondition(!CacheStore(rootURL: root).initialCachedTrackIDs.contains(partialTrack.id))

        let migratedPartialRoot = sandbox.appending(path: "migrated-partials")
        let partialMigration = CacheStore(rootURL: migratedPartialRoot, legacyURL: root)
        let migratedLocation = await partialMigration.partialLocation(for: partialTrack)
        let migratedTransfer = ProgressiveAudioTransfer(trackID: partialTrack.id, fileSize: partialTrack.size, location: migratedLocation) { _, _, _ in
            fatalError("Migrated partial bytes must be reused offline")
        }
        let migratedChunk = try await migratedTransfer.bytes(at: 0, length: 512 * 1024)
        precondition(migratedChunk == firstChunk)
        // Return the completed files moved by the migration for the remaining tests.
        _ = CacheStore(rootURL: root, legacyURL: migratedPartialRoot)

        // Explicit deletion must remove recovery records as well.
        try await recovered.remove(downloaded)
        precondition(!CacheStore(rootURL: root).initialCachedTrackIDs.contains(downloaded.id))

        // Do not advertise truncated downloads as completed.
        let shortFile = await recovered.partialLocation(for: downloaded).dataURL
        try Data([1]).write(to: shortFile)
        do {
            _ = try await recovered.commit(shortFile, track: downloaded)
            fatalError("An incomplete file was committed")
        } catch is CocoaError { }

        // iOS container paths can change on app updates. Persist only filenames.
        let relocated = sandbox.appending(path: "new-container/Audio")
        try fm.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: root, to: relocated)
        let afterUpdate = CacheStore(rootURL: relocated)
        let movedURL = await afterUpdate.localURL(for: song)
        let movedBytes = try Data(contentsOf: movedURL!)
        precondition(movedBytes == audio)

        let boundedRoot = sandbox.appending(path: "bounded")
        let bounded = CacheStore(limit: CacheLimits.minimum, rootURL: boundedRoot)
        for id: Int64 in [10, 11] {
            let large = track(id, size: 60_000_000)
            let staging = await bounded.partialLocation(for: large).dataURL
            fm.createFile(atPath: staging.path, contents: nil)
            let handle = try FileHandle(forWritingTo: staging)
            try handle.truncate(atOffset: UInt64(large.size))
            try handle.close()
            _ = try await bounded.commit(staging, track: large)
        }
        precondition(CacheStore(rootURL: boundedRoot).initialCachedTrackIDs == [track(11).id],
                     "Eviction must remove recovery records so evicted downloads do not reappear")
        print("PASS: durable downloads, migration, orphan recovery, relaunch, lost index, metadata recovery, reused audio deduplication, duplicate index repair, concurrent cold-cache playback/download, partial resume, deletion, truncated files, container relocation")
    }
}
