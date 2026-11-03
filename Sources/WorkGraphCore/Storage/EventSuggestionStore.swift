import Foundation
import GRDB

/// 기록에서 찾은 일정 제안. 사용자가 [등록] 또는 [무시]를 누를 때까지 pending 으로 둔다.
/// 같은 제목과 같은 날짜는 한 번만 만든다 (이미 등록·무시한 것도 다시 제안하지 않는다)
public struct EventSuggestion: Equatable, Sendable, FetchableRecord, Identifiable {
    public var id: Int64
    public var title: String
    public var start: Double
    public var end: Double?
    public var allDay: Bool
    public var evidenceId: Int64?
    public var evidence: String
    public var status: String
    public var createdAt: Double

    public init(row: Row) {
        id = row["id"]; title = row["title"]; start = row["start_ts"]; end = row["end_ts"]; allDay = (row["all_day"] as Int) != 0
        evidenceId = row["evidence_id"]; evidence = row["evidence"]; status = row["status"]; createdAt = row["created_at"]
    }
}

public struct EventSuggestionStore: Sendable {
    public static let pending = "pending", registered = "registered", dismissed = "dismissed"
    let db: WGDatabase
    public init(_ db: WGDatabase) { self.db = db }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17-event-suggestions") { conn in
            try conn.execute(sql: """
                CREATE TABLE IF NOT EXISTS event_suggestions (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  title TEXT NOT NULL,
                  day TEXT NOT NULL,
                  start_ts REAL NOT NULL,
                  end_ts REAL,
                  all_day INTEGER NOT NULL DEFAULT 0,
                  evidence_id INTEGER,
                  evidence TEXT NOT NULL DEFAULT '',
                  status TEXT NOT NULL DEFAULT 'pending',
                  created_at REAL NOT NULL,
                  UNIQUE(title, day)
                );
                CREATE INDEX IF NOT EXISTS idx_event_suggestions_status ON event_suggestions(status, start_ts);
                """)
        }
    }

    /// 열린 트랜잭션 안에서 추가. 같은 제목+날짜가 있으면 false
    @discardableResult
    public static func insert(_ conn: Database, title: String, start: Date, end: Date?, allDay: Bool, evidenceId: Int64?, evidence: String,
                              now: Double, timeZone: TimeZone = .current) throws -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let f = DateFormatter(); f.calendar = cal; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        try conn.execute(sql: """
            INSERT OR IGNORE INTO event_suggestions(title, day, start_ts, end_ts, all_day, evidence_id, evidence, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
            """, arguments: [title, f.string(from: start), start.timeIntervalSince1970, end?.timeIntervalSince1970, allDay ? 1 : 0, evidenceId, evidence, now])
        return conn.changesCount > 0
    }

    /// 아직 안 지난 제안만, 가까운 날짜부터
    public func pending(now: Date = Date(), limit: Int = 50) throws -> [EventSuggestion] {
        try db.writer.read { conn in
            try EventSuggestion.fetchAll(conn, sql: """
                SELECT * FROM event_suggestions WHERE status = 'pending' AND COALESCE(end_ts, start_ts) >= ? ORDER BY start_ts LIMIT ?
                """, arguments: [now.timeIntervalSince1970, limit])
        }
    }

    public func setStatus(_ id: Int64, _ status: String) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE event_suggestions SET status = ? WHERE id = ?", arguments: [status, id]) }
    }
}
