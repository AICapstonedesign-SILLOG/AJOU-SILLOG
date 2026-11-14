import Foundation
import GRDB

/// Asks the local Laya v4 server whether screen records hold private sensitive information.
/// The server is `scripts/laya/serve.py`; it windows each record and scores it the way v4 was evaluated.
public struct LayaClient: Sendable {
    /// One screen record in the shape v4 was trained on.
    public struct Record: Codable, Hashable, Sendable {
        public var app: String
        public var appKind: String
        public var captureSource: String
        public var windowTitle: String?
        public var url: String?
        public var docPath: String?
        public var text: String

        enum CodingKeys: String, CodingKey {
            case app, url, text
            case appKind = "app_kind", captureSource = "capture_source", windowTitle = "window_title", docPath = "doc_path"
        }

        /// Args: observation is the screen row, source is its text snapshot's capture source, text its screen text.
        /// Returns: the record with identifiers already masked, as v4 expects.
        public init(_ observation: Observation, source: String?, text: String?) {
            app = observation.appName
            appKind = Self.kind(observation.appBundle)
            captureSource = source ?? "ax"
            windowTitle = observation.windowTitle.map(LayaClient.masked)
            url = observation.url.map(LayaClient.masked)
            docPath = observation.docPath.map(LayaClient.masked)
            self.text = LayaClient.masked(text ?? "")
        }

        // The app kinds the training records used.
        static func kind(_ bundle: String) -> String {
            if ResumePlanner.browsers.contains(bundle) { return "browser" }
            if bundle == "com.apple.finder" { return "file_browser" }
            if ["com.openai.chat", "com.anthropic.claudefordesktop", "com.google.GeminiMacOS"].contains(bundle) { return "assistant" }
            if ["com.kakao.KakaoTalkMac", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
                "net.whatsapp.WhatsApp", "com.microsoft.teams2", "us.zoom.xos", "com.linecorp.line"].contains(bundle) { return "chat" }
            return "application"
        }
    }

    /// From model_v4/deploy.json: the highest recall with at most 2% of ordinary records blocked.
    public static let threshold = 0.8
    public static let defaultURL = "http://127.0.0.1:8766/v1/privacy"
    /// What a blocked row's title becomes in the prompt.
    public static let placeholder = "[민감 정보]"

    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = URL(string: SillogEnv.value("LAYA_URL") ?? LayaClient.defaultURL)!, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Args: records are masked screen records.
    /// Returns: one score per record, the highest P(sensitive) = 1 - P(none) over its windows.
    /// Raises: LayaError when the server is not running or answers in another shape.
    public func scores(_ records: [Record]) async throws -> [Double] {
        // A backlog window can hold hundreds of long screens at about 1 s each on the CPU; one request for all of them
        // would time out and retry the same window forever, so each request stays well inside its timeout.
        var out: [Double] = []
        for start in stride(from: 0, to: records.count, by: 16) {
            out += try await post(Array(records[start..<min(start + 16, records.count)]))
        }
        return out
    }

    private func post(_ records: [Record]) async throws -> [Double] {
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["records": records])
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw LayaError.unreachable("\(error)") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LayaError.badResponse("HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        struct Answer: Decodable { struct Result: Decodable { let score: Double }; let results: [Result] }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.results.count == records.count else {
            throw LayaError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return answer.results.map(\.score)
    }

    /// Args: observations are screen rows, db holds their text snapshots.
    /// Returns: the ids Laya scores at or above `threshold`. A periodic row has no text of its own,
    /// so it is scored with the last text of the same window, or a long sensitive screen would pass after its first row.
    /// Raises: LayaError when the server cannot score them.
    public func sensitiveIDs(_ observations: [Observation], db: SillogDatabase) async throws -> Set<Int64> {
        let texts = try await db.writer.read { conn -> [Int64: (source: String, text: String)] in
            var textOf: [Int64: Int64] = [:], last: [String: Int64?] = [:]
            for o in observations {
                guard let id = o.id else { continue }
                if let textId = o.textId { textOf[id] = textId; continue }
                let key = [o.appBundle, o.windowTitle ?? "", o.url ?? "", o.docPath ?? ""].joined(separator: "\u{1}")
                if last[key] == nil {
                    last[key] = try Int64.fetchOne(conn, sql: """
                        SELECT text_id FROM observations WHERE app_bundle = ? AND window_title IS ? AND url IS ? AND doc_path IS ?
                          AND text_id IS NOT NULL AND ts <= ? ORDER BY ts DESC LIMIT 1
                        """, arguments: [o.appBundle, o.windowTitle, o.url, o.docPath, o.ts])
                }
                if let textId = last[key] ?? nil { textOf[id] = textId }
            }
            let list = Set(textOf.values).map(String.init).joined(separator: ",")
            let snapshots = try Row.fetchAll(conn, sql: "SELECT id, source, text FROM text_snapshots WHERE id IN (\(list))")
                .reduce(into: [Int64: (source: String, text: String)]()) { $0[$1["id"]] = ($1["source"], $1["text"]) }
            return textOf.compactMapValues { snapshots[$0] }
        }
        // Periodic rows repeat the same screen, so each distinct record is scored once.
        var records: [Record] = [], slot: [Record: Int] = [:], recordOf: [Int64: Int] = [:]
        for o in observations {
            guard let id = o.id else { continue }
            let record = Record(o, source: texts[id]?.source, text: texts[id]?.text)
            if slot[record] == nil { slot[record] = records.count; records.append(record) }
            recordOf[id] = slot[record]
        }
        let scores = try await self.scores(records)
        return Set(recordOf.filter { scores[$0.value] >= Self.threshold }.keys)
    }

    /// Set from the app setting. On, chat search serves only screen rows a batch has scored.
    nonisolated(unsafe) public static var enabled = false

    // The Korean placeholders of the v4 training masker (sillog_privacy/mask.py), so v4 sees the input it learned from.
    private static let tags = ["private-key": "[개인키]", "api-key": "[API키]", "bearer": "[토큰]", "key-value": "[비밀값]", "email": "[이메일]",
                               "iban": "[계좌번호]", "kr-account": "[계좌번호]", "card": "[카드번호]", "intl-phone": "[전화번호]",
                               "kr-phone": "[전화번호]", "nanp-phone": "[전화번호]", "kr-rrn": "[주민번호]", "address": "[주소]"]

    /// Args: text is any record field.
    /// Returns: the text with identifiers, the home folder name and the account name replaced by v4's placeholders.
    /// Masks even when the "개인정보 가리기" setting is off, because v4 only ever saw masked text.
    static func masked(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for item in PIIMasker.matches(in: text).sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: item.range, with: tags[item.rule] ?? "[식별번호]")
        }
        var out = (result as String).replacingOccurrences(of: #"(/Users/|/home/)[^/\s\[\]]+"#, with: "$1[사용자]", options: .regularExpression)
        for name in [NSFullUserName(), NSUserName()] where name.count >= 2 { out = out.replacingOccurrences(of: name, with: "[사용자]") }
        return out
    }
}

public enum LayaError: LocalizedError {
    case unreachable(String), badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: return tr("민감 정보 분류기(Laya)에 연결하지 못했어요. scripts/laya/serve.py를 실행해 주세요.")
        case .badResponse: return tr("민감 정보 분류기(Laya)의 응답을 읽지 못했어요.")
        }
    }
}
