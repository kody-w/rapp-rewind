import CSQLite
import Foundation

private enum SQLValue {
    case text(String), integer(Int64), real(Double), null
}

private struct SQLRow {
    let statement: OpaquePointer
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
    }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open index"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw RewindError.database(message)
        }
        sqlite3_busy_timeout(handle, 30_000)
    }

    deinit { if let handle { sqlite3_close(handle) } }

    var lastID: Int64 { sqlite3_last_insert_rowid(handle) }

    func script(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        if result != SQLITE_OK {
            let detail = message.map { String(cString: $0) } ?? error
            sqlite3_free(message)
            throw RewindError.database(detail)
        }
    }

    private var error: String { String(cString: sqlite3_errmsg(handle)) }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> [T] {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else {
            throw RewindError.database(error)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else {
            throw RewindError.database("internal parameter count mismatch")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient)
                }
            case .integer(let int): result = sqlite3_bind_int64(statement, index, int)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw RewindError.database(error) }
        }
        var output: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: output.append(try map(SQLRow(statement: statement)))
            case SQLITE_DONE: return output
            default: throw RewindError.database(error)
            }
        }
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let _: [Int] = try query(sql, values) { _ in 0 }
    }

    func transaction<T>(_ action: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let value = try action()
            try script("COMMIT")
            return value
        } catch {
            let original = error
            do { try script("ROLLBACK") }
            catch { throw RewindError.database("\(original.localizedDescription); rollback also failed: \(error.localizedDescription)") }
            throw original
        }
    }
}

public actor RewindIndex {
    public static var sqliteVersion: String { String(cString: sqlite3_libversion()) }

    public static func verifyFTS5() throws {
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RewindError.database("cannot open in-memory diagnostic database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE VIRTUAL TABLE fixture USING fts5(text)", nil, nil, nil) == SQLITE_OK else {
            throw RewindError.database("system SQLite does not support FTS5")
        }
    }

    // This is the compatibility CLI's schema, including content-storing FTS and counters.
    public static let schema = """
    CREATE TABLE IF NOT EXISTS frames (
      id INTEGER PRIMARY KEY,
      ts REAL NOT NULL,
      until_ts REAL NOT NULL,
      app TEXT,
      bundle TEXT,
      title TEXT,
      path TEXT,
      bytes INTEGER DEFAULT 0,
      fingerprint TEXT,
      lines INTEGER DEFAULT 0,
      confidence REAL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS frames_ts ON frames(ts);
    CREATE INDEX IF NOT EXISTS frames_app ON frames(app);
    CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(
      text, app, title, tokenize='unicode61'
    );
    CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
    """

    public nonisolated let paths: RewindPaths
    private let database: SQLiteDatabase

    public init(paths: RewindPaths) throws {
        self.paths = paths
        try RewindPaths.createPrivateDirectory(paths.root)
        if !FileManager.default.fileExists(atPath: paths.database.path) {
            guard FileManager.default.createFile(
                atPath: paths.database.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { throw RewindError.database("cannot create index file") }
        }
        let database = try SQLiteDatabase(url: paths.database)
        let existing = try database.query(
            "SELECT name, sql FROM sqlite_master WHERE type='table' AND name IN ('frames','frames_fts')"
        ) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        if !existing.isEmpty {
            guard existing.count == 2 else { throw RewindError.incompatibleSchema("Missing frames or frames_fts table.") }
            let fts = existing.first { $0.0 == "frames_fts" }?.1.lowercased().filter { !$0.isWhitespace } ?? ""
            if fts.contains("content=''") || fts.contains("content=\"\"") {
                throw RewindError.legacyContentlessIndex
            }
            let columns = try database.query("PRAGMA table_info(frames)") { $0.text(1) ?? "" }
            let expected: Set<String> = [
                "id", "ts", "until_ts", "app", "bundle", "title", "path", "bytes", "fingerprint", "lines", "confidence"
            ]
            guard expected.isSubset(of: Set(columns)), fts.contains("usingfts5(") else {
                throw RewindError.incompatibleSchema("Expected the existing Rewind frames and FTS5 columns.")
            }
            let ftsColumns = try database.query("PRAGMA table_info(frames_fts)") { $0.text(1) ?? "" }
            guard ftsColumns == ["text", "app", "title"] else {
                throw RewindError.incompatibleSchema("Unexpected full-text columns.")
            }
        }
        try database.script(Self.schema)
        try RewindPaths.createPrivateDirectory(paths.frames)
        self.database = database
    }

    private func bump(_ key: String) throws {
        try database.run("""
            INSERT INTO meta (k,v) VALUES (?, '1')
            ON CONFLICT(k) DO UPDATE SET v = CAST(CAST(v AS INTEGER) + 1 AS TEXT)
            """, [.text(key)])
    }

    public func extendIfUnchanged(
        previousID: Int64, fingerprint: String?, at date: Date,
        sameMean: Double = 0.5, sameMaximum: Double = 12
    ) throws -> Bool {
        try Task.checkCancellation()
        return try database.transaction {
            try Task.checkCancellation()
            let previous = try database.query("SELECT id, fingerprint, until_ts FROM frames ORDER BY ts DESC LIMIT 1") {
                ($0.int(0), $0.text(1), $0.double(2))
            }.first
            guard let previous, previous.0 == previousID,
                  date.timeIntervalSince1970 >= previous.2,
                  Fingerprint.isSame(previous.1, fingerprint, mean: sameMean, maximum: sameMaximum) else { return false }
            try database.run("UPDATE frames SET until_ts=? WHERE id=?", [.real(date.timeIntervalSince1970), .integer(previousID)])
            try bump("shots_same")
            return true
        }
    }

    public func append(_ frame: CapturedFrame, text: RecognizedText, at date: Date) throws -> Int64 {
        try Task.checkCancellation()
        guard !frame.jpeg.isEmpty else { throw RewindError.imageEncoding }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let relative = "\(day)/\(Int64(date.timeIntervalSince1970 * 1000))-\(UUID().uuidString).jpg"
        let imageURL = try paths.safeFrameURL(relative)
        try RewindPaths.createPrivateDirectory(imageURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: imageURL.path) else {
            throw RewindError.captureUnavailable("generated image filename already exists")
        }
        try frame.jpeg.write(to: imageURL, options: .atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
            return try database.transaction {
                try Task.checkCancellation()
                try database.run("""
                    INSERT INTO frames (ts, until_ts, app, bundle, title, path, bytes, fingerprint, lines, confidence)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [
                        .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970),
                        .text(frame.context.app), .text(frame.context.bundle), .text(frame.context.title),
                        .text(relative), .integer(Int64(frame.jpeg.count)),
                        frame.fingerprint.map(SQLValue.text) ?? .null,
                        .integer(Int64(text.lines)), .real(text.confidence)
                    ])
                let id = database.lastID
                try database.run(
                    "INSERT INTO frames_fts (rowid,text,app,title) VALUES (?,?,?,?)",
                    [.integer(id), .text(text.text), .text(frame.context.app), .text(frame.context.title)]
                )
                try bump("shots_new")
                return id
            }
        } catch {
            let original = error
            do { try FileManager.default.removeItem(at: imageURL) }
            catch { throw RewindError.database("\(original.localizedDescription); could not remove unindexed image: \(error.localizedDescription)") }
            throw original
        }
    }

    private static let momentColumns = """
        f.id, f.ts, f.until_ts, f.app, f.bundle, f.title, f.path,
        COALESCE(f.bytes,0), COALESCE(frames_fts.text,''), f.lines, f.confidence
        """

    private func moment(_ row: SQLRow) -> Moment {
        Moment(
            id: row.int(0), timestamp: Date(timeIntervalSince1970: row.double(1)),
            until: Date(timeIntervalSince1970: row.double(2)), app: row.text(3) ?? "",
            bundle: row.text(4) ?? "", title: row.text(5) ?? "", relativePath: row.text(6),
            bytes: row.int(7), text: row.text(8) ?? "", snippet: row.text(11) ?? "",
            lines: Int(row.int(9)), confidence: row.double(10)
        )
    }

    public func search(_ query: String, app: String? = nil, since: Date? = nil, limit: Int = 20) throws -> [Moment] {
        guard (1...1000).contains(limit) else { throw RewindError.invalidSetting("search limit must be 1–1000") }
        var filters = ["frames_fts MATCH ?"]
        var values: [SQLValue] = [.text(query)]
        if let app, !app.isEmpty {
            filters.append("f.app LIKE ?")
            values.append(.text("%\(app)%"))
        }
        if let since {
            filters.append("f.ts >= ?")
            values.append(.real(since.timeIntervalSince1970))
        }
        values.append(.integer(Int64(limit)))
        return try database.query("""
            SELECT \(Self.momentColumns), snippet(frames_fts, 0, '[', ']', ' … ', 12)
            FROM frames_fts JOIN frames f ON f.id=frames_fts.rowid
            WHERE \(filters.joined(separator: " AND ")) ORDER BY f.ts DESC LIMIT ?
            """, values, map: moment)
    }

    public func timeline(since: Date? = nil, limit: Int = 400) throws -> [Moment] {
        guard (1...1000).contains(limit) else { throw RewindError.invalidSetting("timeline limit must be 1–1000") }
        return try database.query("""
            SELECT \(Self.momentColumns), ''
            FROM frames f LEFT JOIN frames_fts ON frames_fts.rowid=f.id
            WHERE f.ts >= ? ORDER BY f.ts DESC LIMIT ?
            """, [.real(since?.timeIntervalSince1970 ?? 0), .integer(Int64(limit))], map: moment)
    }

    public func moment(id: Int64) throws -> Moment? {
        try database.query("""
            SELECT \(Self.momentColumns), ''
            FROM frames f LEFT JOIN frames_fts ON frames_fts.rowid=f.id WHERE f.id=?
            """, [.integer(id)], map: moment).first
    }

    public func imageURL(id: Int64) throws -> URL {
        guard let relative = try database.query(
            "SELECT path FROM frames WHERE id=?", [.integer(id)], map: { $0.text(0) }
        ).first, let relative else { throw RewindError.missingImage }
        let url = try paths.safeFrameURL(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RewindError.missingImage }
        return url
    }

    public func statistics() throws -> IndexStatistics {
        let counters = try database.query("SELECT k,v FROM meta WHERE k IN ('shots_new','shots_same')") {
            ($0.text(0) ?? "", Int64($0.text(1) ?? "") ?? 0)
        }
        let values = Dictionary(uniqueKeysWithValues: counters)
        guard let stats = try database.query("""
            SELECT COUNT(*), COALESCE(SUM(bytes),0), MIN(ts), MAX(until_ts), COALESCE(SUM(until_ts-ts),0)
            FROM frames
            """, map: {
                IndexStatistics(
                    frames: $0.int(0), bytes: $0.int(1),
                    newShots: values["shots_new"] ?? 0, sameShots: values["shots_same"] ?? 0,
                    first: $0.isNull(2) ? nil : Date(timeIntervalSince1970: $0.double(2)),
                    last: $0.isNull(3) ? nil : Date(timeIntervalSince1970: $0.double(3)), heldSeconds: $0.double(4)
                )
            }).first else { throw RewindError.database("missing aggregate row") }
        return stats
    }

    public func previewPrune(before cutoff: Date) throws -> PrunePreview {
        guard let result = try database.query("""
            SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM frames WHERE ts < ? AND path IS NOT NULL
            """, [.real(cutoff.timeIntervalSince1970)], map: {
                PrunePreview(cutoff: cutoff, images: Int($0.int(0)), bytes: $0.int(1))
            }).first else { throw RewindError.database("missing prune aggregate") }
        return result
    }

    @discardableResult
    public func pruneImages(before cutoff: Date) throws -> PrunePreview {
        try Task.checkCancellation()
        let rows = try database.query(
            "SELECT id,path,COALESCE(bytes,0) FROM frames WHERE ts < ? AND path IS NOT NULL",
            [.real(cutoff.timeIntervalSince1970)]
        ) { ($0.int(0), $0.text(1) ?? "", $0.int(2)) }
        let files = try rows.map { try paths.safeFrameURL($0.1) }
        var count = 0
        var bytes: Int64 = 0
        for (row, file) in zip(rows, files) {
            try Task.checkCancellation()
            // Commit each image independently: a later file error must not roll back
            // metadata for earlier, successfully removed images.
            try database.transaction {
                try Task.checkCancellation()
                try database.run("UPDATE frames SET path=NULL, bytes=0 WHERE id=?", [.integer(row.0)])
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            count += 1
            bytes += row.2
        }
        return PrunePreview(cutoff: cutoff, images: count, bytes: bytes)
    }
}
