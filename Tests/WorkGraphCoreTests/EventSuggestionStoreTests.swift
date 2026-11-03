import XCTest
@testable import WorkGraphCore

final class EventSuggestionStoreTests: XCTestCase {
    func testDuplicateTitleAndDayIsIgnoredAndStatusHidesFromPending() throws {
        let db = try WGDatabase.inMemory()
        let store = EventSuggestionStore(db)
        let day = Date().addingTimeInterval(2 * 86400)
        let first = try db.writer.write { try EventSuggestionStore.insert($0, title: "중간고사", start: day, end: nil, allDay: true, evidenceId: nil, evidence: "공지", now: 0) }
        let again = try db.writer.write { try EventSuggestionStore.insert($0, title: "중간고사", start: day.addingTimeInterval(3600), end: nil, allDay: false, evidenceId: nil, evidence: "", now: 0) }
        XCTAssertTrue(first)
        XCTAssertFalse(again)
        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        try store.setStatus(pending[0].id, EventSuggestionStore.dismissed)
        XCTAssertTrue(try store.pending().isEmpty)
        // 무시한 것도 같은 제목+날짜로 다시 만들지 않는다
        let third = try db.writer.write { try EventSuggestionStore.insert($0, title: "중간고사", start: day, end: nil, allDay: true, evidenceId: nil, evidence: "", now: 0) }
        XCTAssertFalse(third)
    }
}
