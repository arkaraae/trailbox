import Foundation
import SQLite3

/// Local-only SQLite black box. Every row is immutable; INSERT OR IGNORE makes replay/relay idempotent.
final class EventStore {
    enum StoreError: Error { case openDatabase, prepareStatement, executeStatement }

    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String? = nil) throws {
        let dbPath: String
        if let path { dbPath = path }
        else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            dbPath = directory.appendingPathComponent("trailbox.sqlite").path
        }
        guard sqlite3_open(dbPath, &database) == SQLITE_OK else { throw StoreError.openDatabase }
        let sql = """
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY NOT NULL,
          trip_id TEXT NOT NULL,
          recorded_at REAL NOT NULL,
          json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_trip_time ON events(trip_id, recorded_at);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.executeStatement }
    }

    deinit { sqlite3_close(database) }

    @discardableResult
    func append(_ event: TrailEvent) throws -> Bool {
        let statementSQL = "INSERT OR IGNORE INTO events(id, trip_id, recorded_at, json) VALUES(?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, statementSQL, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareStatement
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, event.id, -1, transient)
        sqlite3_bind_text(statement, 2, event.tripID, -1, transient)
        sqlite3_bind_double(statement, 3, event.recordedAt.timeIntervalSince1970)
        let data = try encoder.encode(event)
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(data.count), transient)
        }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.executeStatement
        }
        return sqlite3_changes(database) > 0
    }

    func events(for tripID: String) throws -> [TrailEvent] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
              "SELECT json FROM events WHERE trip_id = ? ORDER BY recorded_at, id", -1,
              &statement, nil) == SQLITE_OK else { throw StoreError.prepareStatement }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, tripID, -1, transient)
        var result: [TrailEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_blob(statement, 0) else { continue }
            let size = Int(sqlite3_column_bytes(statement, 0))
            result.append(try decoder.decode(TrailEvent.self, from: Data(bytes: pointer, count: size)))
        }
        return result
    }

    @discardableResult
    func merge(_ incoming: [TrailEvent]) throws -> Int {
        var inserted = 0
        for event in incoming { if try append(event) { inserted += 1 } }
        return inserted
    }
}
