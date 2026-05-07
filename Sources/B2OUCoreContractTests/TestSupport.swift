import Foundation
import B2OUCore

#if canImport(SQLite3)
import SQLite3
#endif

enum TestSupportError: Error, CustomStringConvertible {
    case sqliteUnavailable
    case sqliteOpenFailed(String)
    case sqliteExecFailed(String)

    var description: String {
        switch self {
        case .sqliteUnavailable:
            return "SQLite3 is unavailable in this environment"
        case .sqliteOpenFailed(let path):
            return "Could not open SQLite database at \(path)"
        case .sqliteExecFailed(let message):
            return message
        }
    }
}

struct FixtureNote {
    let title: String
    let text: String
    let uuid: String
    let modifiedUnix: Double
    var trashed: Int = 0
    var archived: Int = 0
    var encrypted: Int = 0
    var attachments: [(filename: String, uuid: String)] = []
}

func makeTemporaryDirectory(prefix: String = "b2ou-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func createBearDatabase(at url: URL, notes: [FixtureNote]) throws {
#if canImport(SQLite3)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else {
        throw TestSupportError.sqliteOpenFailed(url.path)
    }
    defer { sqlite3_close(db) }

    try execSQL(
        """
        CREATE TABLE ZSFNOTE(
          ZTITLE TEXT,
          ZTEXT TEXT,
          ZCREATIONDATE REAL,
          ZMODIFICATIONDATE REAL,
          ZUNIQUEIDENTIFIER TEXT,
          Z_PK INTEGER,
          ZTRASHED INTEGER,
          ZARCHIVED INTEGER,
          ZENCRYPTED INTEGER
        );
        CREATE TABLE ZSFNOTEFILE(
          ZNOTE INTEGER,
          ZFILENAME TEXT,
          ZUNIQUEIDENTIFIER TEXT
        );
        """,
        db: db
    )

    for (index, note) in notes.enumerated() {
        let pk = index + 1
        let modified = note.modifiedUnix - coreDataEpoch
        let created = modified - 60
        try execSQL(
            """
            INSERT INTO ZSFNOTE(
              ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE,
              ZUNIQUEIDENTIFIER, Z_PK, ZTRASHED, ZARCHIVED, ZENCRYPTED
            ) VALUES (
              '\(sqlQuote(note.title))',
              '\(sqlQuote(note.text))',
              \(created),
              \(modified),
              '\(sqlQuote(note.uuid))',
              \(pk),
              \(note.trashed),
              \(note.archived),
              \(note.encrypted)
            );
            """,
            db: db
        )

        for attachment in note.attachments {
            try execSQL(
                """
                INSERT INTO ZSFNOTEFILE(ZNOTE, ZFILENAME, ZUNIQUEIDENTIFIER)
                VALUES (\(pk), '\(sqlQuote(attachment.filename))', '\(sqlQuote(attachment.uuid))');
                """,
                db: db
            )
        }
    }
#else
    throw TestSupportError.sqliteUnavailable
#endif
}

#if canImport(SQLite3)
private func execSQL(_ sql: String, db: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
        sqlite3_free(errorMessage)
        throw TestSupportError.sqliteExecFailed(message)
    }
}
#endif

private func sqlQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}
