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

    /// Args: conn reads an app database; since keeps only screens first shown after that Unix time.
    /// Returns: one masked record per distinct screen with at least 40 characters of text, oldest first,
    ///   each with the first row that showed it.
    /// Raises: DatabaseError when conn is not an app database.
    public static func evaluationRecords(_ conn: Database, since: Double = 0) throws -> [(observationId: Int64, ts: Double, appBundle: String, record: Record)] {
        // First-schema columns only so older app databases read too; text-less periodic rows repeat a screen; v4's real records used the same 40-character floor.
        let rows = try Row.fetchCursor(conn, sql: """
            SELECT o.id, o.ts, o.app_bundle, o.app_name, o.window_title, o.url, o.doc_path, o.text_id, t.source, t.text
            FROM observations o JOIN text_snapshots t ON t.id = o.text_id
            WHERE length(t.text) >= 40 ORDER BY o.ts, o.id
            """)
        var out: [(observationId: Int64, ts: Double, appBundle: String, record: Record)] = [], seen = Set<Record>()
        while let row = try rows.next() {
            let o = Observation(id: row["id"], ts: row["ts"], trigger: "", appBundle: row["app_bundle"], appName: row["app_name"],
                                windowTitle: row["window_title"], url: row["url"], docPath: row["doc_path"], textId: row["text_id"])
            let record = Record(o, source: row["source"], text: row["text"])
            // Earlier rows still fill seen, so a screen v4 may have trained on stays out when it is shown again after since.
            if seen.insert(record).inserted, o.ts > since { out.append((o.id ?? 0, o.ts, o.appBundle, record)) }
        }
        return out
    }

    /// Set from the app setting. On, chat search serves only screen rows a batch has scored.
    nonisolated(unsafe) public static var enabled = false

    // The Korean placeholders of the v4 training masker (sillog_privacy/mask.py), so v4 sees the input it learned from.
    // Rules missing here are foreign IDs, which mask.py calls [식별번호].
    static let tags = [
        "private-key": "[개인키]", "api-key": "[API키]", "api-key-redacted": "[API키]", "jwt": "[토큰]", "bearer": "[비밀값]",
        "url-secret": "[비밀값]", "console-id": "[비밀값]", "url-credentials": "[비밀값]", "key-value": "[비밀값]", "kr-key-value": "[비밀값]",
        "otp": "[비밀값]", "otp-before": "[비밀값]", "tokenish": "[비밀값]",
        "email": "[이메일]", "email-partial": "[이메일]", "handle": "[계정]", "labeled-handle": "[계정]", "mac-hostname": "[사용자]",
        "iban": "[계좌번호]", "kr-account": "[계좌번호]", "kr-account-label": "[계좌번호]", "card": "[카드번호]", "card-partial": "[카드번호]",
        "intl-phone": "[전화번호]", "kr-phone": "[전화번호]", "kr-phone-variant": "[전화번호]", "kr-phone-partial": "[전화번호]", "nanp-phone": "[전화번호]",
        "kr-rrn": "[주민번호]", "kr-rrn-bare": "[주민번호]", "kr-driver": "[면허번호]", "kr-driver-bare": "[면허번호]", "kr-passport": "[여권번호]",
        "birth-date": "[생년월일]", "ipv4": "[IP주소]", "ipv6": "[IP주소]", "labeled-id": "[식별번호]", "kr-member-id": "[식별번호]",
        "kr-road-address": "[주소]", "kr-district-address": "[주소]", "kr-road-unit": "[주소]", "kr-jibun": "[주소]", "kr-apartment": "[주소]",
        "kr-unit": "[주소]", "kr-road-number": "[주소]", "kr-zip": "[주소]", "address": "[주소]",
    ]

    private static let homeFolder = try! NSRegularExpression(pattern: #"(?:/Users/|/home/)([^/\s\[\]]+)"#)

    /// Args: text is any record field.
    /// Returns: the text composed to NFC, with identifiers, the home folder name and the account name replaced by v4's placeholders.
    /// Masks even when the "개인정보 가리기" setting is off, because v4 only ever saw masked text.
    static func masked(_ text: String) -> String {
        // Composed like PIIMasker.mask, so decomposed file names meet the Korean rules.
        let text = text.precomposedStringWithCanonicalMapping
        let result = NSMutableString(string: text)
        for item in replacements(in: text).reversed() { result.replaceCharacters(in: item.range, with: item.tag) }
        return result as String
    }

    /// Args: text is any record field.
    /// Returns: the non-overlapping ranges `masked` replaces, in text order, each with its placeholder.
    static func replacements(in text: String) -> [(range: NSRange, tag: String)] {
        var found = PIIMasker.matches(in: text).map { (range: $0.range, tag: tags[$0.rule] ?? "[식별번호]") }
        func claim(_ range: NSRange) {
            guard range.length > 0, !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            found.append((range, "[사용자]"))
        }
        let source = text as NSString
        for match in homeFolder.matches(in: text, range: NSRange(location: 0, length: source.length)) { claim(match.range(at: 1)) }
        for name in [NSFullUserName(), NSUserName()] where name.count >= 2 {
            var from = 0
            while case let range = source.range(of: name, range: NSRange(location: from, length: source.length - from)), range.location != NSNotFound {
                claim(range)
                from = NSMaxRange(range)
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Args: record is one Laya training or evaluation record as JSON: window_title, url, doc_path and text, plus optional
    ///   evidence_spans of {field, start, end, text} whose offsets count Unicode scalars, as Python does.
    /// Returns: the record masked exactly as `Record` masks it for Laya, NFC included, with every evidence span moved onto the masked text.
    ///   A span edge inside a masked value moves to the edge of its placeholder, so the span keeps the whole placeholder.
    public static func maskedTrainingRecord(_ record: [String: Any]) -> [String: Any] {
        var out = record, edits: [String: (raw: String, composed: String, found: [(range: NSRange, tag: String)])] = [:]
        for field in ["window_title", "url", "doc_path", "text"] {
            guard let raw = record[field] as? String else { continue }
            let composed = raw.precomposedStringWithCanonicalMapping, found = replacements(in: composed), result = NSMutableString(string: composed)
            for item in found.reversed() { result.replaceCharacters(in: item.range, with: item.tag) }
            edits[field] = (raw, composed, found)
            out[field] = result as String
        }
        guard let spans = record["evidence_spans"] as? [[String: Any]] else { return out }
        out["evidence_spans"] = spans.map { span -> [String: Any] in
            let field = span["field"] as? String ?? "text"
            guard let edit = edits[field], let masked = out[field] as? String,
                  let start = span["start"] as? Int, let end = span["end"] as? Int else { return span }
            let from = moved(utf16(composedOffset(start, edit.raw), in: edit.composed), end: false, edit.found)
            let to = max(from, moved(utf16(composedOffset(end, edit.raw), in: edit.composed), end: true, edit.found))
            var span = span
            span["start"] = scalars(from, in: masked)
            span["end"] = scalars(to, in: masked)
            span["text"] = (masked as NSString).substring(with: NSRange(location: from, length: to - from))
            return span
        }
        return out
    }

    // NFC merges jamo into syllables, so a scalar offset into the raw field becomes the length of its composed prefix.
    private static func composedOffset(_ scalars: Int, _ raw: String) -> Int {
        String(String.UnicodeScalarView(raw.unicodeScalars.prefix(max(scalars, 0)))).precomposedStringWithCanonicalMapping.unicodeScalars.count
    }

    // Python offsets count Unicode scalars and NSString offsets count UTF-16 units; they differ on emoji.
    private static func utf16(_ scalars: Int, in text: String) -> Int {
        let view = text.unicodeScalars
        return view.index(view.startIndex, offsetBy: min(max(scalars, 0), view.count)).utf16Offset(in: text)
    }

    private static func scalars(_ utf16: Int, in text: String) -> Int {
        text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: String.Index(utf16Offset: utf16, in: text))
    }

    /// Where UTF-16 offset `offset` of the original text lands after `found` is applied.
    private static func moved(_ offset: Int, end: Bool, _ found: [(range: NSRange, tag: String)]) -> Int {
        var shift = 0
        for item in found {
            if offset <= item.range.location { break }
            let length = (item.tag as NSString).length
            if offset < NSMaxRange(item.range) { return item.range.location + shift + (end ? length : 0) }
            shift += length - item.range.length
        }
        return offset + shift
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
