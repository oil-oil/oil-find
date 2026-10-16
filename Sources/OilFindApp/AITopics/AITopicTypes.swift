import Foundation
import SQLite3

public enum AITopicProvider: String, CaseIterable {
    case claude, codex, workbuddy
    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .workbuddy: return "WorkBuddy"
        }
    }
}

public struct AITopic: Equatable {
    public let id: String
    public let provider: AITopicProvider
    public var title: String
    public var project: String
    public var modified: Double
    public var desktopID: String
    public var transcript: String
    public var archived: Bool
    public var excerpt: String

    public init(id: String, provider: AITopicProvider, title: String, project: String = "", modified: Double = 0,
                desktopID: String = "", transcript: String = "", archived: Bool = false, excerpt: String = "") {
        self.id = id; self.provider = provider; self.title = title; self.project = project; self.modified = modified
        self.desktopID = desktopID; self.transcript = transcript; self.archived = archived; self.excerpt = excerpt
    }
    public var key: String { provider.rawValue + ":" + id }
    public var resumeCommand: String {
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if provider == .workbuddy { return workbuddyURL.map { "open " + quote($0.absoluteString) } ?? "" }
        guard provider == .claude || provider == .codex else { return "" }
        let command = provider == .claude ? "claude" : "codex"
        if provider == .claude, UUID(uuidString: id) == nil,
           desktopID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil {
            return "open " + quote("claude://claude.ai/epitaxy/" + desktopID)
        }
        return (project.isEmpty ? "" : "cd " + quote(project) + " && ") + command + (provider == .claude ? " --resume " : " resume ") + quote(id)
    }
    public var codexURL: URL? {
        guard provider == .codex, UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/" + id)
    }
    public var workbuddyURL: URL? {
        guard provider == .workbuddy,
              id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { return nil }
        var url = URLComponents(); url.scheme = "workbuddy"; url.host = "chat"; url.path = "/" + id
        return url.url
    }
}

public struct AITopicSearchResult {
    public let topics: [AITopic]
    public let hasMore: Bool
    public let elapsedMs: Double
}

enum AITopicError: Error, LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return message }; return nil }
}

// Each connection is confined to its caller's queue. Source databases are always opened read-only.
final class AITopicSQL {
    let db: OpaquePointer
    init(_ url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open topic index"
            if let handle { sqlite3_close(handle) }
            throw AITopicError.database(message)
        }
        db = handle; sqlite3_busy_timeout(db, readOnly ? 100 : 1000)
    }
    deinit { sqlite3_close(db) }
    func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> AITopicError { .database(String(cString: sqlite3_errmsg(db))) }
    func prepare(_ sql: String) throws -> AITopicStatement { try AITopicStatement(self, sql) }
    func tables() throws -> Set<String> {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type='table'")
        var result = Set<String>(); while try statement.next() { result.insert(statement.text(0)) }; return result
    }
    func columns(_ table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\")")
        var result = Set<String>(); while try statement.next() { result.insert(statement.text(1)) }; return result
    }
}

final class AITopicStatement {
    private let database: AITopicSQL
    let handle: OpaquePointer
    init(_ database: AITopicSQL, _ sql: String) throws {
        self.database = database
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw database.error() }
        handle = statement
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ values: [String]) {
        for (i, value) in values.enumerated() {
            _ = value.withCString { sqlite3_bind_text(handle, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
    }
    func next() throws -> Bool {
        let status = sqlite3_step(handle)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw database.error() }
        return status == SQLITE_ROW
    }
    func text(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
}
