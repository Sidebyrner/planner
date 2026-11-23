import XCTest
@testable import PlannerKit

final class PlannerAPITests: XCTestCase {
    let base = URL(string: "https://planner.example.ts.net")!

    func testDecodesStateAndSendsBearerToken() async throws {
        let stub = StubTransport()
        stub.on("GET", "/api/state") { _ in (200, Fixture.state) }
        let api = PlannerAPI(baseURL: base, token: "secret-token", transport: stub)

        let state = try await api.state()

        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(state.tasks.first?.title, "Write report")
        XCTAssertEqual(state.tasks.first?.status, .todo)
        XCTAssertEqual(state.tasks.first?.dueAt, date("2026-11-25T17:00:00Z"))
        XCTAssertNil(state.tasks.first?.completedAt)
        XCTAssertEqual(state.events.first?.source, .device)
        XCTAssertEqual(state.events.first?.isReadOnly, true)
        XCTAssertEqual(state.settings.workDays, [1, 2, 3, 4, 5])
        XCTAssertNil(state.google.lastSyncAt)
    }

    func testParsesDatesWithAndWithoutMilliseconds() {
        XCTAssertEqual(PlannerJSON.parseDate("2026-11-23T13:00:00.000Z"), PlannerJSON.parseDate("2026-11-23T13:00:00Z"))
        XCTAssertNotNil(PlannerJSON.parseDate("2026-11-23T13:00:00.250Z"))
        XCTAssertNil(PlannerJSON.parseDate("next tuesday"))
        XCTAssertEqual(PlannerJSON.format(date("2026-11-23T13:00:00Z")), "2026-11-23T13:00:00.000Z")
    }

    func testUnauthorizedIsItsOwnError() async {
        let stub = StubTransport()
        stub.on("GET", "/api/state") { _ in (401, #"{"error":"Sign in to continue."}"#) }
        let api = PlannerAPI(baseURL: base, token: "wrong", transport: stub)

        do {
            _ = try await api.state()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PlannerAPIError, .unauthorized)
        }
    }

    func testServerErrorCarriesTheServerMessage() async {
        let stub = StubTransport()
        stub.on("POST", "/api/tasks") { _ in (400, #"{"error":"title: Too small"}"#) }
        let api = PlannerAPI(baseURL: base, token: "t", transport: stub)

        do {
            _ = try await api.createTask(TaskDraft(title: " "))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PlannerAPIError, .server(status: 400, message: "title: Too small"))
            XCTAssertEqual(error.localizedDescription, "title: Too small")
        }
    }

    func testTaskPatchSendsOnlySetFieldsAndNullToClearDueDate() throws {
        let clear = try JSONSerialization.jsonObject(with: PlannerJSON.encoder().encode(TaskPatch(dueAt: .some(nil)))) as! [String: Any]
        XCTAssertEqual(clear.count, 1)
        XCTAssertTrue(clear["dueAt"] is NSNull)

        let done = try JSONSerialization.jsonObject(with: PlannerJSON.encoder().encode(TaskPatch(status: .done))) as! [String: Any]
        XCTAssertEqual(done as NSDictionary, ["status": "done"])
    }

    func testCapturePreviewAndSave() async throws {
        let stub = StubTransport()
        let parsed = #"{"kind":"task","title":"Call Sam","priority":2,"estimateMin":15,"dueAt":"2026-11-24T17:00:00.000Z","startAt":null,"endAt":null}"#
        stub.on("POST", "/api/capture") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if body["preview"] as? Bool == true { return (200, #"{"parsed":\#(parsed)}"#) }
            return (200, #"{"parsed":\#(parsed),"task":{"id":"t2","title":"Call Sam","notes":"","status":"todo","priority":2,"estimateMin":15,"dueAt":"2026-11-24T17:00:00.000Z","createdAt":"2026-11-23T12:00:00.000Z","completedAt":null}}"#)
        }
        let api = PlannerAPI(baseURL: base, token: "t", transport: stub)

        let preview = try await api.previewCapture("call Sam tomorrow 15m")
        XCTAssertEqual(preview.kind, .task)
        XCTAssertEqual(preview.estimateMin, 15)
        XCTAssertEqual(try stub.lastBody("POST", "/api/capture")["preview"] as? Bool, true)

        let saved = try await api.capture("call Sam tomorrow 15m")
        XCTAssertEqual(saved.task?.id, "t2")
        XCTAssertNil(saved.event)
        XCTAssertNil(try stub.lastBody("POST", "/api/capture")["preview"])
    }

    func testApplyScheduleSendsAcceptedBlocks() async throws {
        let stub = StubTransport()
        stub.on("POST", "/api/schedule/apply") { _ in
            (200, "[" + Fixture.block(start: "2026-11-23T13:00:00.000Z", end: "2026-11-23T14:30:00.000Z") + "]")
        }
        let api = PlannerAPI(baseURL: base, token: "t", transport: stub)
        let proposed = ProposedBlock(taskId: "t1", title: "Write report", startAt: date("2026-11-23T13:00:00Z"), endAt: date("2026-11-23T14:30:00Z"), late: false)

        let created = try await api.applySchedule([BlockBooking(proposed)])

        XCTAssertEqual(created.map(\.taskId), ["t1"])
        let blocks = try stub.lastBody("POST", "/api/schedule/apply")["blocks"] as! [[String: Any]]
        XCTAssertEqual(blocks.first?["taskId"] as? String, "t1")
        XCTAssertEqual(blocks.first?["startAt"] as? String, "2026-11-23T13:00:00.000Z")
    }
}
