import Foundation
import SQLite3

enum SQLiteDatabaseError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
}

extension SQLiteDatabaseError: CustomStringConvertible, LocalizedError {
    var description: String {
        switch self {
        case .openFailed(let message):
            return "open failed: \(message)"
        case .prepareFailed(let message):
            return "prepare failed: \(message)"
        case .stepFailed(let message):
            return "step failed: \(message)"
        case .bindFailed(let message):
            return "bind failed: \(message)"
        }
    }

    var errorDescription: String? {
        description
    }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer?

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open(path, &database)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database."
            throw SQLiteDatabaseError.openFailed(message)
        }
        handle = database
        try configureConnection()
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? errorMessageString
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseError.stepFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteDatabaseError.prepareFailed(errorMessageString)
        }
        return SQLiteStatement(statement: statement, database: self)
    }

    var errorMessageString: String {
        guard let handle else { return "Database is closed." }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func configureConnection() throws {
        try execute("PRAGMA busy_timeout = 5000;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private unowned let database: SQLiteDatabase

    init(statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ text: String?, at index: Int32) throws {
        let result: Int32
        if let text {
            result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(database.errorMessageString)
        }
    }

    func bind(_ value: Double, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(database.errorMessageString)
        }
    }

    func bind(_ value: Int, at index: Int32) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw SQLiteDatabaseError.bindFailed(database.errorMessageString)
        }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteDatabaseError.stepFailed(database.errorMessageString)
        }
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func string(at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int(statement, index))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
