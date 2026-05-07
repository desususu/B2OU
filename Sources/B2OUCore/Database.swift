// Database.swift — Bear SQLite database access layer.
//
// All functions open the database in read-only mode to avoid corrupting
// Bear's live database. For export the database is snapshotted via the
// SQLite backup API.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Data Transfer Objects

public struct BearNote: Sendable {
    public let title: String
    public let text: String
    public let creationDate: Double   // Core Data timestamp
    public let modifiedDate: Double   // Core Data timestamp
    public let uuid: String
    public let pk: Int64

    public init(title: String, text: String, creationDate: Double,
                modifiedDate: Double, uuid: String, pk: Int64) {
        self.title = title
        self.text = text
        self.creationDate = creationDate
        self.modifiedDate = modifiedDate
        self.uuid = uuid
        self.pk = pk
    }
}

public struct NoteFile: Sendable {
    public let filename: String
    public let uuid: String
}

// MARK: - Timestamp Helpers

public func coreDataToUnix(_ ts: Double) -> Double {
    ts + coreDataEpoch
}

// MARK: - SQLite Wrapper

public final class SQLiteConnection {
    private var db: OpaquePointer?

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw B2OUError.databaseOpenFailed(msg)
        }
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public var pointer: OpaquePointer? { db }

    // MARK: - Query Helpers

    public func forEachRow(
        _ sql: String,
        params: [Any] = [],
        _ body: ([String: Any]) -> Void
    ) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindParams(stmt: stmt!, params: params)

        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_NULL:
                    row[name] = nil as Any?
                default:
                    row[name] = nil as Any?
                }
            }
            body(row)
        }
    }

    public func query(_ sql: String, params: [Any] = []) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        forEachRow(sql, params: params) { rows.append($0) }
        return rows
    }

    public func queryOne(_ sql: String, params: [Any] = []) -> [String: Any]? {
        query(sql, params: params).first
    }

    /// SQLITE_TRANSIENT tells SQLite to make its own copy of the string immediately,
    /// avoiding dangling-pointer bugs from temporary NSString.utf8String buffers.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindParams(stmt: OpaquePointer, params: [Any]) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let v as String:
                v.withCString { cStr in
                    _ = sqlite3_bind_text(stmt, idx, cStr, -1, SQLiteConnection.SQLITE_TRANSIENT)
                }
            case let v as Int64:
                sqlite3_bind_int64(stmt, idx, v)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    // MARK: - Backup API

    public func backupTo(_ destPath: String) throws {
        let destURL = URL(fileURLWithPath: destPath)
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var destDb: OpaquePointer?
        let openRc = sqlite3_open_v2(
            destPath,
            &destDb,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openRc == SQLITE_OK, let destDb else {
            let msg = destDb.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let destDb { sqlite3_close(destDb) }
            throw B2OUError.databaseOpenFailed("Cannot open backup destination: \(msg)")
        }
        defer { sqlite3_close(destDb) }
        sqlite3_busy_timeout(destDb, 5_000)

        guard let sourceDb = db else {
            throw B2OUError.databaseOpenFailed("Source database is closed")
        }
        guard let backup = sqlite3_backup_init(destDb, "main", sourceDb, "main") else {
            let msg = String(cString: sqlite3_errmsg(destDb))
            throw B2OUError.databaseOpenFailed("Cannot init backup: \(msg)")
        }

        var stepRc = SQLITE_OK
        var retries = 0
        repeat {
            stepRc = sqlite3_backup_step(backup, 256)
            if stepRc == SQLITE_BUSY || stepRc == SQLITE_LOCKED {
                retries += 1
                if retries > 100 { break }
                Thread.sleep(forTimeInterval: 0.05)
            } else {
                retries = 0
            }
        } while stepRc == SQLITE_OK || stepRc == SQLITE_BUSY || stepRc == SQLITE_LOCKED

        let finishRc = sqlite3_backup_finish(backup)
        guard stepRc == SQLITE_DONE, finishRc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(destDb))
            throw B2OUError.databaseOpenFailed(
                "Backup failed (step=\(stepRc), finish=\(finishRc)): \(msg)"
            )
        }
    }
}

// MARK: - Connection Helpers

public func openReadonly(dbPath: URL) throws -> SQLiteConnection {
    try SQLiteConnection(path: dbPath.path, readOnly: true)
}

public func copyAndOpen(dbPath: URL) throws -> (SQLiteConnection, URL?) {
    let tmpDir = FileManager.default.temporaryDirectory
    let tmpPath = tmpDir.appendingPathComponent("b2ou_export_\(UUID().uuidString).sqlite")

    do {
        let src = try SQLiteConnection(path: dbPath.path, readOnly: true)
        try src.backupTo(tmpPath.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tmpPath.path
        )
        let conn = try SQLiteConnection(path: tmpPath.path, readOnly: true)
        return (conn, tmpPath)
    } catch {
        try? FileManager.default.removeItem(at: tmpPath)
        throw error
    }
}

// MARK: - Schema Helpers

private let allowedTables: Set<String> = ["ZSFNOTE", "ZSFNOTEFILE", "ZSFNOTETAG"]

private func hasTable(_ conn: SQLiteConnection, table: String) -> Bool {
    guard allowedTables.contains(table) else { return false }
    let rows = conn.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
        params: [table]
    )
    return !rows.isEmpty
}

private func hasColumn(_ conn: SQLiteConnection, table: String, column: String) -> Bool {
    guard allowedTables.contains(table) else { return false }
    // Use double-quote identifier quoting for defense-in-depth against injection
    let safeTable = table.replacingOccurrences(of: "\"", with: "\"\"")
    let rows = conn.query("PRAGMA table_info(\"\(safeTable)\")")
    return rows.contains { ($0["name"] as? String) == column }
}

public func validateBearSchema(conn: SQLiteConnection) -> Bool {
    guard hasTable(conn, table: "ZSFNOTE") else { return false }
    let requiredNoteColumns = [
        "ZTITLE",
        "ZTEXT",
        "ZCREATIONDATE",
        "ZMODIFICATIONDATE",
        "ZUNIQUEIDENTIFIER",
        "Z_PK",
        "ZTRASHED",
        "ZARCHIVED",
    ]
    return requiredNoteColumns.allSatisfy { hasColumn(conn, table: "ZSFNOTE", column: $0) }
}

private func activeNoteWhereClause(conn: SQLiteConnection, alias: String? = nil) -> String {
    let prefix = alias.map { "\($0)." } ?? ""
    var whereClause = "\(prefix)ZTRASHED = 0 AND \(prefix)ZARCHIVED = 0"
    if hasColumn(conn, table: "ZSFNOTE", column: "ZENCRYPTED") {
        whereClause += " AND \(prefix)ZENCRYPTED = 0"
    }
    return whereClause
}

// MARK: - Note Queries

public func iterNotes(conn: SQLiteConnection) -> [BearNote] {
    var notes: [BearNote] = []
    forEachNote(conn: conn) { notes.append($0) }
    return notes
}

public func forEachNote(conn: SQLiteConnection, _ body: (BearNote) -> Void) {
    let whereClause = activeNoteWhereClause(conn: conn)

    conn.forEachRow(
        "SELECT ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE, " +
        "ZUNIQUEIDENTIFIER, Z_PK FROM ZSFNOTE WHERE \(whereClause)"
    ) { row in
        guard let text = row["ZTEXT"] as? String else { return }
        body(BearNote(
            title: (row["ZTITLE"] as? String) ?? "",
            text: text.trimmingTrailingWhitespace(),
            creationDate: (row["ZCREATIONDATE"] as? Double) ?? 0,
            modifiedDate: (row["ZMODIFICATIONDATE"] as? Double) ?? 0,
            uuid: (row["ZUNIQUEIDENTIFIER"] as? String) ?? "",
            pk: (row["Z_PK"] as? Int64) ?? 0
        ))
    }
}

public func getNoteByUUID(conn: SQLiteConnection, uuid: String) -> BearNote? {
    let whereClause = activeNoteWhereClause(conn: conn)
    guard let row = conn.queryOne(
        "SELECT ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE, " +
        "ZUNIQUEIDENTIFIER, Z_PK FROM ZSFNOTE " +
        "WHERE \(whereClause) AND ZUNIQUEIDENTIFIER = ?",
        params: [uuid]
    ) else { return nil }
    return rowToNote(row)
}

public func getNoteByTitle(conn: SQLiteConnection, title: String) -> BearNote? {
    guard !title.isEmpty else { return nil }
    let whereClause = activeNoteWhereClause(conn: conn)
    guard let row = conn.queryOne(
        "SELECT ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE, " +
        "ZUNIQUEIDENTIFIER, Z_PK FROM ZSFNOTE " +
        "WHERE \(whereClause) AND ZTITLE = ? " +
        "ORDER BY ZMODIFICATIONDATE DESC LIMIT 1",
        params: [title]
    ) else { return nil }
    return rowToNote(row)
}

private func rowToNote(_ row: [String: Any]) -> BearNote {
    BearNote(
        title: (row["ZTITLE"] as? String) ?? "",
        text: ((row["ZTEXT"] as? String) ?? "").trimmingTrailingWhitespace(),
        creationDate: (row["ZCREATIONDATE"] as? Double) ?? 0,
        modifiedDate: (row["ZMODIFICATIONDATE"] as? Double) ?? 0,
        uuid: (row["ZUNIQUEIDENTIFIER"] as? String) ?? "",
        pk: (row["Z_PK"] as? Int64) ?? 0
    )
}

public func getNoteModification(conn: SQLiteConnection, uuid: String) -> Double? {
    let whereClause = activeNoteWhereClause(conn: conn)
    guard let row = conn.queryOne(
        "SELECT ZMODIFICATIONDATE FROM ZSFNOTE " +
        "WHERE \(whereClause) AND ZUNIQUEIDENTIFIER = ?",
        params: [uuid]
    ) else { return nil }
    return row["ZMODIFICATIONDATE"] as? Double
}

public func getNoteFiles(conn: SQLiteConnection, notePK: Int64) -> [NoteFile] {
    conn.query(
        "SELECT ZFILENAME, ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE WHERE ZNOTE = ?",
        params: [notePK]
    ).compactMap { row in
        guard let filename = row["ZFILENAME"] as? String,
              let uuid = row["ZUNIQUEIDENTIFIER"] as? String else { return nil }
        return NoteFile(filename: filename, uuid: uuid)
    }
}

public func buildNoteFileMap(conn: SQLiteConnection) -> [Int64: [String: String]] {
    var result: [Int64: [String: String]] = [:]
    for row in conn.query("SELECT ZNOTE, ZFILENAME, ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE") {
        guard let pk = row["ZNOTE"] as? Int64,
              let filename = row["ZFILENAME"] as? String,
              let uuid = row["ZUNIQUEIDENTIFIER"] as? String else { continue }
        result[pk, default: [:]][filename] = uuid
    }
    return result
}

public func getNoteFilesByUUID(conn: SQLiteConnection, noteUUID: String) -> [NoteFile] {
    let whereClause = activeNoteWhereClause(conn: conn, alias: "N")
    return conn.query(
        "SELECT F.ZFILENAME, F.ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE F " +
        "JOIN ZSFNOTE N ON F.ZNOTE = N.Z_PK " +
        "WHERE N.ZUNIQUEIDENTIFIER = ? AND \(whereClause)",
        params: [noteUUID]
    ).compactMap { row in
        guard let filename = row["ZFILENAME"] as? String,
              let uuid = row["ZUNIQUEIDENTIFIER"] as? String else { return nil }
        return NoteFile(filename: filename, uuid: uuid)
    }
}

// MARK: - Change Detection

public func bearDBSignature(dbPath: URL) -> (maxMod: Double, noteCount: Int) {
    guard let conn = try? SQLiteConnection(path: dbPath.path, readOnly: true) else {
        return (0.0, -1)
    }

    let whereClause = activeNoteWhereClause(conn: conn)

    guard let row = conn.queryOne(
        "SELECT MAX(ZMODIFICATIONDATE), COUNT(*) FROM ZSFNOTE WHERE \(whereClause)"
    ) else {
        return (0.0, -1)
    }
    let maxMod = (row["MAX(ZMODIFICATIONDATE)"] as? Double) ?? 0
    let count = (row["COUNT(*)"] as? Int64) ?? 0
    return (coreDataToUnix(maxMod), Int(count))
}

public func bearDBFileSignature(dbPath: URL) -> (lastModified: Double, byteCount: Int64) {
    let fm = FileManager.default
    var newest: Double = 0
    var totalBytes: Int64 = 0
    var found = false

    for suffix in ["", "-wal", "-shm"] {
        let path = dbPath.path + suffix
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
        found = true
        if let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
            newest = max(newest, mtime)
        }
        if let size = attrs[.size] as? NSNumber {
            totalBytes += size.int64Value
        }
    }

    return found ? (newest, totalBytes) : (0.0, -1)
}

public func dbIsQuiet(dbPath: URL, quietSeconds: TimeInterval) -> Bool {
    let now = Date().timeIntervalSince1970
    let fm = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        let path = dbPath.path + suffix
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            continue
        }
        if now - mtime < quietSeconds { return false }
    }
    return true
}

// MARK: - String Extension

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while s.last?.isWhitespace == true { s.removeLast() }
        return s
    }
}
