import Foundation
import RAPPRewindCore
import XCTest

final class CompatibilityTests: XCTestCase {
    func testExistingCLISchemaHistoryAndCountersArePreserved() async throws {
        let directory = try fixture()
        try directory.createCLISchema()
        try directory.sql("""
            INSERT INTO frames(id,ts,until_ts,app,bundle,title,path,bytes,fingerprint,lines,confidence)
            VALUES(4821,100,106,'Fixture Mail','fixture.mail','Historical ledger',NULL,0,'3232',1,0.99);
            INSERT INTO frames_fts(rowid,text,app,title)
            VALUES(4821,'Original searchable ledger text','Fixture Mail','Historical ledger');
            INSERT INTO meta(k,v) VALUES('shots_new','10'),('shots_same','30'),('unrelated','preserve me');
            """)
        let schema = try directory.scalar("SELECT sql FROM sqlite_master WHERE name='frames'")
        let index = try RewindIndex(paths: directory.paths)
        let hits = try await index.search("ledger")
        XCTAssertEqual(hits.first?.id, 4821)
        XCTAssertEqual(hits.first?.text, "Original searchable ledger text")
        XCTAssertTrue(hits.first?.snippet.contains("[ledger]") == true)
        let stats = try await index.statistics()
        XCTAssertEqual(stats.newShots, 10)
        XCTAssertEqual(stats.sameShots, 30)
        XCTAssertEqual(stats.deduplicationRate, 0.75)
        XCTAssertEqual(stats.projectedBytesPerDay(interval: 4), 0)
        let id = try await index.append(
            FixtureDirectory.frame(), text: RecognizedText(text: "Native extra ledger", lines: 1, confidence: 1),
            at: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(id, 4822)
        XCTAssertEqual(try directory.scalar("SELECT sql FROM sqlite_master WHERE name='frames'"), schema)
        XCTAssertEqual(try directory.scalar("SELECT v FROM meta WHERE k='unrelated'"), "preserve me")
        XCTAssertEqual(try directory.scalar("SELECT v FROM meta WHERE k='shots_new'"), "11")
        XCTAssertEqual(try directory.scalar("SELECT text FROM frames_fts WHERE rowid=4821"), "Original searchable ledger text")
    }

    func testContentlessRegressionFailsWithoutDestructiveMigration() throws {
        let directory = try fixture()
        try directory.sql(RewindIndex.schema.replacingOccurrences(of: "tokenize='unicode61'", with: "content='', tokenize='unicode61'"))
        try directory.sql("""
            INSERT INTO frames(id,ts,until_ts,path) VALUES(7,1,2,'old.jpg');
            INSERT INTO frames_fts(rowid,text,app,title) VALUES(7,'unrecoverable content','Fixture','Fixture');
            """)
        let schema = try directory.scalar("SELECT sql FROM sqlite_master WHERE name='frames_fts'")
        XCTAssertThrowsError(try RewindIndex(paths: directory.paths)) {
            XCTAssertEqual($0 as? RewindError, .legacyContentlessIndex)
        }
        XCTAssertEqual(try directory.scalar("SELECT sql FROM sqlite_master WHERE name='frames_fts'"), schema)
        XCTAssertEqual(try directory.scalar("SELECT count(*) FROM frames_fts"), "1")
        XCTAssertEqual(try directory.scalar("SELECT path FROM frames WHERE id=7"), "old.jpg")
    }

    func testUnknownSchemaAndCorruptDatabaseAreLoud() throws {
        let unknown = try fixture()
        try unknown.sql("CREATE TABLE frames (id INTEGER PRIMARY KEY, unrelated TEXT)")
        XCTAssertThrowsError(try RewindIndex(paths: unknown.paths))
        XCTAssertNil(try unknown.scalar("SELECT name FROM sqlite_master WHERE name='frames_fts'"))
        let corrupt = try fixture()
        try Data("This is not a SQLite database".utf8).write(to: corrupt.paths.database)
        XCTAssertThrowsError(try RewindIndex(paths: corrupt.paths))
        XCTAssertEqual(try String(contentsOf: corrupt.paths.database, encoding: .utf8), "This is not a SQLite database")
    }

    func testDefaultsAndEnvironmentDoNotEnableRecordingOrPruning() throws {
        let defaults = try CaptureSettings.defaults(environment: [:])
        XCTAssertEqual(defaults.interval, 4)
        XCTAssertEqual(defaults.maximumDimension, 1280)
        XCTAssertEqual(defaults.jpegQuality, 60)
        XCTAssertEqual(defaults.fingerprintGrid, 32)
        XCTAssertEqual(defaults.sameMean, 0.5)
        XCTAssertEqual(defaults.sameMaximum, 12)
        XCTAssertEqual(defaults.maximumConsecutiveErrors, 5)
        XCTAssertNil(defaults.automaticImageRetentionDays)
        XCTAssertFalse(defaults.keepRunningWhenWindowClosed)
        XCTAssertEqual(defaults.privacy, PrivacyPolicy())
        let overridden = try CaptureSettings.defaults(environment: ["REWIND_INTERVAL": "8", "REWIND_WIDTH": "1600"])
        XCTAssertEqual(overridden.interval, 8)
        XCTAssertEqual(overridden.maximumDimension, 1600)
        XCTAssertThrowsError(try CaptureSettings.defaults(environment: ["REWIND_INTERVAL": "nan"]))
        XCTAssertThrowsError(try CaptureSettings.defaults(environment: ["REWIND_FP_GRID": "0"]))
        XCTAssertThrowsError(try CaptureSettings.defaults(environment: ["REWIND_MAX_ERRORS": "0"]))
    }

    func testSettingsOnlyPersistAfterExplicitSaveAndDoNotOverwriteBadFiles() throws {
        let directory = try fixture()
        let defaults = try directory.paths.loadSettings(environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.paths.settings.path))
        var settings = defaults
        settings.privacy.excludedBundleIDs = ["fixture.private"]
        settings.automaticImageRetentionDays = 30
        settings.keepRunningWhenWindowClosed = true
        try directory.paths.saveSettings(settings)
        XCTAssertEqual(try directory.paths.loadSettings(environment: [:]), settings)
        try Data("broken fixture settings".utf8).write(to: directory.paths.settings)
        XCTAssertThrowsError(try directory.paths.loadSettings(environment: [:]))
        XCTAssertEqual(try String(contentsOf: directory.paths.settings, encoding: .utf8), "broken fixture settings")
    }

    func testLegacyHomeAndExplicitOverrideResolution() {
        let home = URL(fileURLWithPath: "/fixture-home")
        XCTAssertEqual(RewindPaths.resolve(environment: [:], home: home).root.path, "/fixture-home/.rapprewind")
        XCTAssertEqual(RewindPaths.resolve(environment: ["REWIND_HOME": "/explicit-fixture"], home: home).root.path, "/explicit-fixture")
    }

    func testSinceParserMatchesCLIRelativeAndInvalidFallback() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(SinceParser.date(" 2d ", now: now), now.addingTimeInterval(-172800))
        XCTAssertEqual(SinceParser.date(".5h", now: now), now.addingTimeInterval(-1800))
        XCTAssertEqual(SinceParser.date("3w", now: now), now.addingTimeInterval(-1814400))
        XCTAssertEqual(SinceParser.date("nonsense", now: now), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(SinceParser.date("2025-06-01T12:30:00Z").timeIntervalSince1970, 1748781000)
        XCTAssertGreaterThan(SinceParser.date("2025-06-01").timeIntervalSince1970, 0)
    }

    func testNativeCommandsAreBoundedAndCannotGrantConsentOrDelete() throws {
        let command = try NativeCommand.parse(["search", "\"quarterly ledger\"", "--app", "Mail", "--since", "2d", "--limit", "12"])
        XCTAssertEqual(command.action, .search)
        XCTAssertEqual(command.query, "\"quarterly ledger\"")
        XCTAssertEqual(command.limit, 12)
        XCTAssertEqual(try NativeCommand.parse(["prune", "--days", "0"]).days, 0)
        for arguments in [
            ["start"], ["stop"], ["prune", "--yes"], ["prune", "--days", "-1"],
            ["capture", "--confirm"], ["doctor", ";rm"], ["search"],
            ["search", "fixture", "--limit", "1001"], ["search", "fixture", "--app", "Mail", "--app", "Notes"]
        ] {
            XCTAssertThrowsError(try NativeCommand.parse(arguments), "\(arguments)")
        }
    }

    func testNativeURLsOnlyRevealBoundedActions() throws {
        XCTAssertEqual(try NativeRoute.parse(URL(string: "rapp-rewind://capture")!), .capture)
        XCTAssertEqual(try NativeRoute.parse(URL(string: "rapp-rewind://search?query=quarterly%20ledger")!), .search("quarterly ledger"))
        XCTAssertEqual(try NativeRoute.parse(URL(string: "rapp-rewind://prune?days=30")!), .prune(30))
        XCTAssertEqual(try NativeRoute.parse(URL(string: "rapp-rewind://open?id=4821")!), .open(4821))
        for value in [
            "rapp-rewind://start", "rapp-rewind://capture?confirm=yes", "rapp-rewind://prune?days=30&yes=true",
            "rapp-rewind://open?id=-1", "rapp-rewind://search?query=a&query=b",
            "rapp-rewind://doctor/../../bin/sh", "https://capture", "rapp-rewind://user@capture"
        ] {
            XCTAssertThrowsError(try NativeRoute.parse(URL(string: value)!), value)
        }
    }

    func testCaptureLeaseNeverKillsLegacyProcessAndPreventsTwoNativeOwners() throws {
        let directory = try fixture()
        let first = CaptureLease(paths: directory.paths)
        let second = CaptureLease(paths: directory.paths)
        try first.acquire()
        XCTAssertThrowsError(try second.acquire()) { XCTAssertEqual($0 as? RewindError, .alreadyCapturing) }
        first.release()
        try second.acquire()
        second.release()
        let pidFile = directory.paths.root.appendingPathComponent("capture.pid")
        try String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try first.acquire()) { XCTAssertEqual($0 as? RewindError, .alreadyCapturing) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
    }
}
