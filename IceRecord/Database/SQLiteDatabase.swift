import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` 是 C 宏，Swift 无法直接看到，这里手工构造。
/// 含义：让 SQLite 自己拷贝一份字符串/二进制，Swift 的临时缓冲区释放后依然安全。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 值类型

enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue {
    static func int(_ value: Int) -> SQLValue { .integer(Int64(value)) }
    static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
}

struct SQLiteError: LocalizedError, Equatable {
    let code: Int32
    let message: String
    var sql: String?

    var errorDescription: String? {
        if let sql {
            return "SQLite 错误 \(code)：\(message)（SQL: \(sql)）"
        }
        return "SQLite 错误 \(code)：\(message)"
    }
}

// MARK: - 语句

/// 对 `sqlite3_stmt` 的轻量封装。生命周期结束时自动 finalize。
final class SQLiteStatement {
    fileprivate let handle: OpaquePointer
    private let sql: String

    fileprivate init(handle: OpaquePointer, sql: String) {
        self.handle = handle
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(handle, index)
            case .integer(let number):
                result = sqlite3_bind_int64(handle, index, number)
            case .real(let number):
                result = sqlite3_bind_double(handle, index, number)
            case .text(let string):
                result = sqlite3_bind_text(handle, index, string, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
            guard result == SQLITE_OK else {
                throw SQLiteError(code: result, message: "绑定第 \(offset + 1) 个参数失败", sql: sql)
            }
        }
    }

    /// 推进一行；返回 false 表示执行完毕。
    @discardableResult
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: result, message: "执行失败", sql: sql)
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    // MARK: 列读取

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func bool(_ index: Int32) -> Bool {
        sqlite3_column_int64(handle, index) != 0
    }

    func text(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: pointer)
    }

    func date(_ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(handle, index))
    }
}

// MARK: - 数据库

/// 极简 SQLite 封装：只提供本项目需要的 execute / query / transaction。
final class SQLiteDatabase {
    private let handle: OpaquePointer
    let path: String

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = path.withCString { pointer in
            sqlite3_open_v2(pointer, &handle, flags, nil)
        }

        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库文件"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: result, message: message)
        }

        self.handle = handle
        self.path = path
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// 执行一条或多条不带参数的语句
    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteError(code: result, message: message, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: result, message: lastErrorMessage, sql: sql)
        }
        return SQLiteStatement(handle: statement, sql: sql)
    }

    /// 执行写操作，返回受影响的行数
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
        return Int(sqlite3_changes(handle))
    }

    /// 查询并把每一行映射成 `T`
    func query<T>(
        _ sql: String,
        _ values: [SQLValue] = [],
        map: (SQLiteStatement) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(statement))
        }
        return rows
    }

    /// 查询单个标量值
    func scalar<T>(_ sql: String, _ values: [SQLValue] = [], map: (SQLiteStatement) throws -> T) throws -> T? {
        try query(sql, values, map: map).first
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}
