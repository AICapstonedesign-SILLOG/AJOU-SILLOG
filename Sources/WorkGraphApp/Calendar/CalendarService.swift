import AppKit
import EventKit
import SwiftUI
import WorkGraphCore

/// 애플 캘린더 연동 (EventKit). 오늘 일정을 읽고, 기록에서 찾은 일정 제안을 "실록" 캘린더에 등록한다.
/// 구글 캘린더는 Mac 의 인터넷 계정에 추가하면 이 캘린더 목록에 같이 보인다.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    static let calendarName = "실록"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")

    struct TodayEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let time: String      // "14:00" 또는 "종일"
    }

    private let store = EKEventStore()
    private var db: WGDatabase?
    @Published private(set) var granted = false
    @Published private(set) var today: [TodayEvent] = []
    @Published private(set) var suggestions: [EventSuggestion] = []

    private init() {
        granted = Self.isGranted
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    static var isGranted: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Info.plist 에 설명문이 없으면(swift run) 요청하는 순간 시스템이 앱을 끝낸다. .app 번들에서만 요청한다
    static var canPrompt: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.infoDictionary?["NSCalendarsFullAccessUsageDescription"] != nil
    }

    func attach(_ db: WGDatabase?) { if let db { self.db = db }; refresh() }

    /// 권한이 있으면 오늘 일정을 다시 읽고, 제안은 DB 에서 다시 읽는다
    func refresh() {
        granted = Self.isGranted
        suggestions = (try? db.map { try EventSuggestionStore($0).pending() }) ?? []
        guard granted else { today = []; return }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        today = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate ?? start) < ($1.isAllDay ? 0 : 1, $1.startDate ?? start) }
            .map { TodayEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "제목 없음", time: $0.isAllDay ? "종일" : clock.string(from: $0.startDate)) }
    }

    /// 이미 허용이면 바로 true. 처음이면 시스템이 묻고, 막혀 있으면 시스템 설정을 연다 (openSettingsOnFail)
    @discardableResult
    func requestAccess(openSettingsOnFail: Bool = true) async -> Bool {
        if Self.isGranted { refresh(); return true }
        guard Self.canPrompt else { return false }
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        } else if openSettingsOnFail, let url = Self.settingsURL {
            NSWorkspace.shared.open(url)
        }
        refresh()
        return granted
    }

    /// "실록" 캘린더: 있으면 그것, 없으면 만든다 (iCloud 가 있으면 iCloud, 없으면 이 Mac)
    private func sillogCalendar() throws -> EKCalendar {
        if let found = store.calendars(for: .event).first(where: { $0.title == Self.calendarName && $0.allowsContentModifications }) { return found }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarName
        let sources = store.sources
        guard let source = sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
                ?? sources.first(where: { $0.sourceType == .local }) ?? store.defaultCalendarForNewEvents?.source else {
            throw NSError(domain: "Sillog", code: 1, userInfo: [NSLocalizedDescriptionKey: "일정을 담을 캘린더 계정이 없어요"])
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// [등록]: 권한을 받고 "실록" 캘린더에 넣은 뒤 제안을 registered 로
    func register(_ suggestion: EventSuggestion) async {
        guard await requestAccess() else { return }
        do {
            let event = EKEvent(eventStore: store)
            event.title = suggestion.title
            event.calendar = try sillogCalendar()
            event.startDate = Date(timeIntervalSince1970: suggestion.start)
            event.isAllDay = suggestion.allDay
            event.endDate = suggestion.allDay ? event.startDate : Date(timeIntervalSince1970: suggestion.end ?? suggestion.start + 3600)
            if !suggestion.evidence.isEmpty { event.notes = "실록 기록에서 찾은 일정: \(suggestion.evidence)" }
            try store.save(event, span: .thisEvent, commit: true)
            try db.map { try EventSuggestionStore($0).setStatus(suggestion.id, EventSuggestionStore.registered) }
        } catch {
            AppLog.write("캘린더 등록 실패: \(error.localizedDescription)")
        }
        refresh()
    }

    func dismiss(_ suggestion: EventSuggestion) {
        try? db.map { try EventSuggestionStore($0).setStatus(suggestion.id, EventSuggestionStore.dismissed) }
        refresh()
    }

    /// 제안 줄의 날짜: "11월 5일 목 14:00", 종일이면 시간 없이
    static func dateText(_ s: EventSuggestion) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = s.allDay ? "M월 d일 E" : "M월 d일 E HH:mm"
        return f.string(from: Date(timeIntervalSince1970: s.start))
    }
}
