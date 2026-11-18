import GRDB
import XCTest
@testable import SillogCore

final class LayaClientTests: XCTestCase {
    private func client() -> LayaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return LayaClient(endpoint: URL(string: LayaClient.defaultURL)!, session: URLSession(configuration: config))
    }

    /// v4 learned from text masked with Korean placeholders, so it gets them even when the setting is off.
    func testMasksWithTheTrainingPlaceholdersEvenWhenMaskingIsOff() {
        PIIMasker.enabled = false
        defer { PIIMasker.enabled = true }
        XCTAssertEqual(LayaClient.masked("전화 010-1234-5678, kim@example.com, /Users/somebody/메모.txt"),
                       "전화 [전화번호], [이메일], /Users/[사용자]/메모.txt")
        XCTAssertEqual(LayaClient.masked("주민번호 900101-1234567"), "주민번호 [주민번호]")
        XCTAssertEqual(LayaClient.masked("생년월일: 1999.03.14, 여권번호 M12345678, 면허번호 11-12-345678-90"),
                       "생년월일: [생년월일], 여권번호 [여권번호], 면허번호 [면허번호]")
        XCTAssertEqual(LayaClient.masked("배송지는 서울특별시 강남구 테헤란로 152 입니다, cc @jiho_lee, ssh ubuntu@52.78.12.34"),
                       "배송지는 [주소] 입니다, cc [계정], ssh ubuntu@[IP주소]")
        XCTAssertEqual(LayaClient.masked("인증번호 [482913], 카드 5412-34**-****-1234, 입금계좌 110123456789"),
                       "인증번호 [[비밀값]], 카드 [카드번호], 입금계좌 [계좌번호]")
        // mask.py uses [토큰] only for JWTs, which the jwt rule takes before bearer.
        XCTAssertEqual(LayaClient.masked("Authorization: Bearer abcDEF123ghiJKL456mnoPQR789"), "Authorization: Bearer [비밀값]")
        let path = LayaClient.masked("/Users/x/Documents/주민등록번호 9001011234567 사본.pdf".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(Array(path.unicodeScalars), Array("/Users/[사용자]/Documents/주민등록번호 [주민번호] 사본.pdf".unicodeScalars))
    }

    /// macOS hands back decomposed file names; training records are composed like the app's, and their spans follow.
    func testMaskedTrainingRecordComposesDecomposedHangul() throws {
        let raw = "진료 010-1234-5678 우울증".decomposedStringWithCanonicalMapping
        let end = raw.unicodeScalars.count, start = end - "우울증".decomposedStringWithCanonicalMapping.unicodeScalars.count
        let out = LayaClient.maskedTrainingRecord(["text": raw, "evidence_spans": [["field": "text", "start": start, "end": end]]])
        let text = try XCTUnwrap(out["text"] as? String)
        XCTAssertEqual(Array(text.unicodeScalars), Array("진료 [전화번호] 우울증".unicodeScalars))
        let span = try XCTUnwrap((out["evidence_spans"] as? [[String: Any]])?.first)
        XCTAssertEqual([span["start"] as? Int, span["end"] as? Int], [10, 13])
        XCTAssertEqual(span["text"] as? String, "우울증")
    }

    /// A new masker rule without a placeholder here would reach v4 as [식별번호], which it learned only for foreign IDs.
    func testEveryKoreanAndContactRuleHasATrainingPlaceholder() {
        let foreignIDs: Set = ["us-ssn", "cn-ric", "jp-mynumber", "in-aadhaar", "in-pan", "hk-hkid", "tw-id", "sg-nric", "ca-sin", "mx-curp",
                               "br-cpf", "gb-nino", "fr-nir", "it-cf", "es-dni", "de-idnr", "pl-pesel", "se-pnr", "au-tfn", "nl-bsn"]
        let untagged = Set(PIIMasker.rules.map(\.name)).subtracting(LayaClient.tags.keys).subtracting(foreignIDs)
        XCTAssertEqual(untagged, [])
    }

    /// Training records are masked like the app's records, and evidence offsets (Python scalar counts) follow the masked text.
    func testMaskedTrainingRecordMovesEvidenceSpans() throws {
        let record: [String: Any] = [
            "label": "SENSITIVE", "window_title": "진료 kim@example.com",
            "text": "😀 연락 010-1234-5678 우울증 진단",
            "evidence_spans": [["field": "text", "start": 19, "end": 25, "text": "우울증 진단"],
                               ["field": "text", "start": 5, "end": 22, "text": "010-1234-5678 우울증"],
                               ["field": "text", "start": 9, "end": 22, "text": "1234-5678 우울증"],
                               ["field": "window_title", "start": 0, "end": 2, "text": "진료"]],
        ]
        let out = LayaClient.maskedTrainingRecord(record)
        XCTAssertEqual(out["label"] as? String, "SENSITIVE")
        XCTAssertEqual(out["window_title"] as? String, "진료 [이메일]")
        XCTAssertEqual(out["text"] as? String, "😀 연락 [전화번호] 우울증 진단")
        let spans = try XCTUnwrap(out["evidence_spans"] as? [[String: Any]]).map { [$0["start"] as? Int, $0["end"] as? Int] as [Int?] }
        XCTAssertEqual(spans, [[12, 18], [5, 15], [5, 15], [0, 2]])
        XCTAssertEqual((out["evidence_spans"] as? [[String: Any]])?[1]["text"] as? String, "[전화번호] 우울증")
    }

    func testSendsTrainingShapedRecordsAndReadsScores() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"results":[{"score":0.93,"category":"health"}]}"#)])
        let observation = Observation(ts: 1, trigger: "periodic", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "진료 예약")
        let scores = try await client().scores([LayaClient.Record(observation, source: "ocr", text: "우울증 재진 010-1234-5678")])

        XCTAssertEqual(scores, [0.93])
        let sent = try XCTUnwrap((StubURLProtocol.requests.first?.body["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["app_kind"] as? String, "browser")
        XCTAssertEqual(sent["capture_source"] as? String, "ocr")
        XCTAssertEqual(sent["window_title"] as? String, "진료 예약")
        XCTAssertEqual(sent["text"] as? String, "우울증 재진 [전화번호]")
    }

    /// One request for a whole backlog window would outlast its timeout and retry the same window forever.
    func testLongWindowIsScoredInSeveralRequests() async throws {
        let answer = { (n: Int) in #"{"results":["# + Array(repeating: #"{"score":0.1,"category":"none"}"#, count: n).joined(separator: ",") + "]}" }
        StubURLProtocol.reset([.init(status: 200, body: answer(16)), .init(status: 200, body: answer(1))])
        let records = (0..<17).map { LayaClient.Record(Observation(ts: Double($0), trigger: "periodic", appBundle: "x", appName: "X"), source: nil, text: "\($0)") }

        let scores = try await client().scores(records)

        XCTAssertEqual(scores.count, 17)
        XCTAssertEqual(StubURLProtocol.requests.map { ($0.body["records"] as? [Any])?.count }, [16, 1])
    }

    func testAnswerWithAMissingScoreIsAnError() async {
        StubURLProtocol.reset([.init(status: 200, body: #"{"results":[]}"#)])
        let observation = Observation(ts: 1, trigger: "periodic", appBundle: "x", appName: "X")
        do {
            _ = try await client().scores([LayaClient.Record(observation, source: nil, text: nil)])
            XCTFail("expected an error")
        } catch LayaError.badResponse {
        } catch { XCTFail("unexpected \(error)") }
    }

    func testSensitiveRowReachesTheModelWithoutItsContentAndChatSearchSkipsIt() async throws {
        let db = try SillogDatabase.inMemory()
        let store = EventStore(db)
        let clinic = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome",
                                                  windowTitle: "진료 예약 확인", url: "https://hospital.example/booking"))
        try store.attach(observationId: clinic, textId: try store.upsertText("정신건강의학과 우울증 재진 예약", source: "ax", at: 100), screenshotPath: nil)
        let code = try store.insert(Observation(ts: 200, trigger: "app_activate", appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "npm run dev"))
        StubURLProtocol.reset([.init(status: 200, body: #"{"results":[{"score":0.95,"category":"health"},{"score":0.02,"category":"health"}]}"#)])
        let llm = StubLLM([.success(#"{"tasks":[{"ref":"A","match":"new","title":"개발 서버","task_type":"코드작성"}],"rows":[{"rows":"1-2","task":"A"}],"work":[]}"#)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 500 })
        await batcher.setPrivacyFilter(client())

        let outcome = await batcher.runIfDue(force: true)

        guard case .ok = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual((StubURLProtocol.requests.first?.body["records"] as? [Any])?.count, 2)
        XCTAssertTrue(llm.lastUser.contains(LayaClient.placeholder))
        for leak in ["진료", "hospital.example", "우울증"] { XCTAssertFalse(llm.lastUser.contains(leak), leak) }
        XCTAssertTrue(llm.lastUser.contains("npm run dev"))
        let flags = try await db.writer.read { try Int.fetchAll($0, sql: "SELECT sensitive FROM observations WHERE id IN (?, ?) ORDER BY id", arguments: [clinic, code]) }
        XCTAssertEqual(flags, [1, 0])
        XCTAssertFalse(try ContextSearch(db).search(query: "우울증").contains { $0.id == "observation:\(clinic)" })
        XCTAssertTrue(try ContextSearch(db).read("observation:\(clinic)").isEmpty)
        let ledger = try await db.writer.read { try LedgerBuilder().compute($0, days: [PeriodCalendar().day(100)]) }
        XCTAssertFalse(ledger.isEmpty)
        XCTAssertFalse(ledger.contains { $0.target.contains("hospital") }, "\(ledger)")
    }

    /// A periodic row repeats the screen without its own text; scoring it as empty would let a long sensitive screen through.
    func testPeriodicRowIsScoredWithTheLastTextOfItsWindow() async throws {
        let db = try SillogDatabase.inMemory()
        let store = EventStore(db)
        let first = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "진료 예약"))
        try store.attach(observationId: first, textId: try store.upsertText("우울증 재진 예약", source: "ocr", at: 100), screenshotPath: nil)
        let later = try store.insert(Observation(ts: 160, trigger: "periodic", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "진료 예약"))
        StubURLProtocol.reset([.init(status: 200, body: #"{"results":[{"score":0.9,"category":"health"}]}"#)])
        let fetched = try await db.writer.read { try Observation.fetchOne($0, key: later) }
        let observation = try XCTUnwrap(fetched)

        let flagged = try await client().sensitiveIDs([observation], db: db)

        XCTAssertEqual(flagged, [later])
        let sent = try XCTUnwrap((StubURLProtocol.requests.first?.body["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["text"] as? String, "우울증 재진 예약")
        XCTAssertEqual(sent["capture_source"] as? String, "ocr")
    }

    func testUnreachableServerKeepsTheRowsForTheNextBatch() async throws {
        let db = try SillogDatabase.inMemory()
        _ = try EventStore(db).insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "npm run dev"))
        StubURLProtocol.reset([.init(status: 500, body: "{}")])
        let llm = StubLLM([])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 500 })
        await batcher.setPrivacyFilter(client())

        guard case .failed = await batcher.runIfDue(force: true) else { return XCTFail("the batch must wait for Laya") }
        XCTAssertEqual(llm.calls, 0)
        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 1)
    }
}
