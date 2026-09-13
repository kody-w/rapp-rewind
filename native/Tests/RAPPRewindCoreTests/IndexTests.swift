import Foundation
import RAPPRewindCore
import XCTest

final class IndexTests: XCTestCase {
    func testFTS5AvailableInSystemSQLite() throws {
        try RewindIndex.verifyFTS5()
        XCTAssertFalse(RewindIndex.sqliteVersion.isEmpty)
    }

    func testSearchOperatorsSnippetUnicodeFiltersAndOrdering() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        let first = try await index.append(
            FixtureDirectory.frame(), text: RecognizedText(text: "Quarterly ledger café invoice", lines: 1, confidence: 0.9),
            at: Date(timeIntervalSince1970: 100)
        )
        let second = try await index.append(
            FixtureDirectory.frame(byte: 80, context: ScreenContext(app: "Fixture Notes", bundle: "fixture.notes", title: "Budget")),
            text: RecognizedText(text: "Quarterly budget and invoices", lines: 1, confidence: 0.8),
            at: Date(timeIntervalSince1970: 200)
        )
        let hits = try await index.search("quarterly")
        XCTAssertEqual(hits.map(\.id), [second, first])
        XCTAssertTrue(hits[0].snippet.contains("[Quarterly]"))
        let phrase = try await index.search("\"quarterly ledger\"")
        XCTAssertEqual(phrase.map(\.id), [first])
        let prefix = try await index.search("invoic* AND quarterly")
        XCTAssertEqual(prefix.count, 2)
        let not = try await index.search("quarterly NOT budget")
        XCTAssertEqual(not.map(\.id), [first])
        let accent = try await index.search("cafe")
        XCTAssertEqual(accent.map(\.id), [first])
        let app = try await index.search("quarterly", app: "mail")
        XCTAssertEqual(app.map(\.id), [first])
        let since = try await index.search("quarterly", since: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(since.map(\.id), [second])
        let bounded = try await index.search("quarterly", limit: 1)
        XCTAssertEqual(bounded.count, 1)
        let nonexistent = try await index.search("zzzznotarealtokenzzzz")
        XCTAssertTrue(nonexistent.isEmpty)
        let title = try await index.search("title:Budget")
        XCTAssertEqual(title.map(\.id), [second])
    }

    func testInvalidSearchIsAnErrorNotNoMatches() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        do {
            _ = try await index.search("\"unterminated")
            XCTFail("invalid FTS query was accepted")
        } catch RewindError.database {}
        do {
            _ = try await index.search("anything", limit: -1)
            XCTFail("unbounded query was accepted")
        } catch RewindError.invalidSetting {}
    }

    func testDedupExtendsRangeAndCountsShotsWithoutNewText() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        let frame = try FixtureDirectory.frame()
        let id = try await index.append(frame, text: RecognizedText(text: "Kept text", lines: 1, confidence: 0.75), at: Date(timeIntervalSince1970: 100))
        let extended = try await index.extendIfUnchanged(previousID: id, fingerprint: frame.fingerprint, at: Date(timeIntervalSince1970: 104))
        XCTAssertTrue(extended)
        let moment = try await index.moment(id: id)
        XCTAssertEqual(moment?.timestamp.timeIntervalSince1970, 100)
        XCTAssertEqual(moment?.until.timeIntervalSince1970, 104)
        XCTAssertEqual(moment?.text, "Kept text")
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, 1)
        XCTAssertEqual(stats.shots, 2)
        XCTAssertEqual(stats.sameShots, 1)
        XCTAssertEqual(stats.deduplicationRate, 0.5)
        XCTAssertNil(stats.projectedBytesPerDay(interval: 4))
        let backwards = try await index.extendIfUnchanged(previousID: id, fingerprint: frame.fingerprint, at: Date(timeIntervalSince1970: 99))
        XCTAssertFalse(backwards)
        let wrongID = try await index.extendIfUnchanged(previousID: id + 1, fingerprint: frame.fingerprint, at: Date(timeIntervalSince1970: 108))
        XCTAssertFalse(wrongID)
    }

    func testRetentionDropsOnlyOldPixelsKeepsTextCountersAndBoundary() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        let frame = try FixtureDirectory.frame()
        let old = try await index.append(frame, text: RecognizedText(text: "old searchable invoice", lines: 1, confidence: 1), at: Date(timeIntervalSince1970: 99))
        _ = try await index.extendIfUnchanged(previousID: old, fingerprint: frame.fingerprint, at: Date(timeIntervalSince1970: 150))
        let oldURL = try await index.imageURL(id: old)
        let fresh = try await index.append(frame, text: RecognizedText(text: "fresh searchable invoice", lines: 1, confidence: 1), at: Date(timeIntervalSince1970: 100))
        let newURL = try await index.imageURL(id: fresh)
        let beforeStats = try await index.statistics()
        let cutoff = Date(timeIntervalSince1970: 100)
        let preview = try await index.previewPrune(before: cutoff)
        XCTAssertEqual(preview.images, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        let result = try await index.pruneImages(before: cutoff)
        XCTAssertEqual(result, preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        let kept = try await index.search("searchable")
        XCTAssertEqual(kept.count, 2)
        let pruned = try await index.moment(id: old)
        XCTAssertNil(pruned?.relativePath)
        XCTAssertEqual(pruned?.bytes, 0)
        XCTAssertEqual(pruned?.until.timeIntervalSince1970, 150)
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, beforeStats.frames)
        XCTAssertEqual(stats.shots, beforeStats.shots)
        XCTAssertEqual(stats.bytes, Int64(frame.jpeg.count))
        let repeated = try await index.pruneImages(before: cutoff)
        XCTAssertEqual(repeated.images, 0)
        do {
            _ = try await index.imageURL(id: old)
            XCTFail("pruned image still opens")
        } catch RewindError.missingImage {}
    }

    func testUnsafeAndSymlinkPathsCannotBeOpenedOrPruned() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        let frame = try FixtureDirectory.frame()
        let id = try await index.append(frame, text: RecognizedText(text: "Fixture", lines: 1, confidence: 1), at: Date(timeIntervalSince1970: 1))
        let outside = directory.paths.root.appendingPathComponent("outside.jpg")
        try frame.jpeg.write(to: outside)
        try directory.sql("UPDATE frames SET path='../outside.jpg' WHERE id=\(id)")
        do {
            _ = try await index.pruneImages(before: Date(timeIntervalSince1970: 2))
            XCTFail("traversal was accepted")
        } catch RewindError.unsafePath {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let link = directory.paths.frames.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try directory.sql("UPDATE frames SET path='link.jpg' WHERE id=\(id)")
        do {
            _ = try await index.imageURL(id: id)
            XCTFail("symlink escaped the frames directory")
        } catch RewindError.unsafePath {}
        XCTAssertThrowsError(try directory.paths.safeFrameURL("/outside.jpg"))
        XCTAssertThrowsError(try directory.paths.safeFrameURL("script.app"))
    }

    func testMissingImageIsReconciledByPruneWithoutDeletingText() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        let id = try await index.append(
            FixtureDirectory.frame(), text: RecognizedText(text: "Still searchable", lines: 1, confidence: 1),
            at: Date(timeIntervalSince1970: 1)
        )
        let url = try await index.imageURL(id: id)
        try FileManager.default.removeItem(at: url)
        _ = try await index.pruneImages(before: Date(timeIntervalSince1970: 2))
        let hits = try await index.search("searchable")
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits[0].relativePath)
    }

    func testPruneCannotFollowInTreeSymlinkAndDeleteAnotherImage() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        let text = RecognizedText(text: "Shared fixture", lines: 1, confidence: 1)
        let old = try await index.append(FixtureDirectory.frame(), text: text, at: Date(timeIntervalSince1970: 1))
        let fresh = try await index.append(FixtureDirectory.frame(byte: 80), text: text, at: Date(timeIntervalSince1970: 100))
        let target = try await index.imageURL(id: fresh)
        let link = directory.paths.frames.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try directory.sql("UPDATE frames SET path='alias.jpg' WHERE id=\(old)")
        do {
            _ = try await index.pruneImages(before: Date(timeIntervalSince1970: 50))
            XCTFail("an old alias deleted a newer frame's pixels")
        } catch RewindError.unsafePath {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let saved = try await index.moment(id: fresh)
        XCTAssertNotNil(saved?.relativePath)
    }

    func testWriteFailureRollsBackRowsCountersAndUnindexedImage() async throws {
        let directory = try fixture()
        let index = try RewindIndex(paths: directory.paths)
        try directory.sql("CREATE TRIGGER fixture_failure BEFORE INSERT ON frames BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;")
        do {
            _ = try await index.append(
                FixtureDirectory.frame(), text: RecognizedText(text: "Must not persist", lines: 1, confidence: 1), at: Date()
            )
            XCTFail("write failure was hidden")
        } catch RewindError.database {}
        let stats = try await index.statistics()
        XCTAssertEqual(stats.frames, 0)
        XCTAssertEqual(stats.shots, 0)
        let enumerator = FileManager.default.enumerator(at: directory.paths.frames, includingPropertiesForKeys: nil)
        let jpgs = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }
        XCTAssertEqual(jpgs.count, 0)
    }
}
