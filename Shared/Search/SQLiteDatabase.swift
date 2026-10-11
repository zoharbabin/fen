import Foundation
import SQLite3

struct SQLiteError: Error, LocalizedError {
    let code: Int32
    let message: String

    var errorDescription: String? {
        "Fen's search index failed (\(message))."
    }
}

/// A thin wrapper over the system SQLite (issue #35). One connection, used from one actor.
/// The index is a cache, so any error here is recoverable by deleting and rebuilding it.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let error = lastError()
            sqlite3_close(handle)
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        return SQLiteStatement(statement, database: self)
    }

    /// Runs `body` in one transaction. Rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func lastError() -> SQLiteError {
        SQLiteError(
            code: sqlite3_errcode(handle),
            message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
        )
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private unowned let database: SQLiteDatabase
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    // MARK: - Binding (1-based, like SQLite)

    func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    func bind(_ index: Int32, _ value: Int) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func bind(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    func bind(_ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        value.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.transient)
        }
    }

    // MARK: - Running

    /// Steps once. `true` while a row is available.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError()
        }
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: - Reading (0-based)

    func string(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
