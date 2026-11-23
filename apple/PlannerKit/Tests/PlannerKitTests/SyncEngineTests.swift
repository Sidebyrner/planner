import XCTest
@testable import PlannerKit

@MainActor
final class SyncEngineTests: XCTestCase {
    let now = date("2026-11-23T12:00:00Z")
    var stub: StubTransport!
    var calendar: InMemoryCalendarStore!
    var cacheDir: URL!

    override func setUp() async throws {
        stub = StubTransport()
        stub.on("GET", "/api/state") { _ in (200, Fixture.state) }
        calendar = InMemoryCalendarStore(calendars: [
            CalendarInfo(id: "work", title: "Work", source: "iCloud"),
            CalendarInfo(id: "home", title: "Home", source: "iCloud"),
        ])
        cacheDir = FileManager.default.temporaryDirectory.appending(path: "PlannerKitTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func makeEngine(busy: Set<String>? = nil) -> SyncEngine {
        SyncEngine(
            api: PlannerAPI(baseURL: URL(string: "https://planner.test")!, token: "t", transport: stub),
            calendar: calendar,
            cache: PlannerCache(directory: cacheDir),
            options: .init(busyCalendarIDs: busy),
            now: { [now] in now }
        )
    }

    var plannerBlocks: [DeviceEvent] {
        calendar.items.filter { $0.calendarID == calendar.plannerID }
    }

    func serverReturns(_ blocks: [String]) {
        stub.on("PUT", "/api/device/events") { _ in (200, Fixture.syncResult(blocks: blocks)) }
    }

    let block1 = Fixture.block(start: "2026-11-23T13:00:00.000Z", end: "2026-11-23T14:00:00.000Z")

    func testMirrorsBusyCalendarsAndWritesReturnedBlocks() async throws {
        calendar.items = [
            DeviceEvent(identifier: "standup", calendarID: "work", title: "Standup", start: date("2026-11-24T09:00:00Z"), end: date("2026-11-24T09:15:00Z"), isRecurring: true),
            DeviceEvent(identifier: "standup", calendarID: "work", title: "Standup", start: date("2026-11-25T09:00:00Z"), end: date("2026-11-25T09:15:00Z"), isRecurring: true),
            DeviceEvent(identifier: "review", calendarID: "work", title: "Review", notes: "Room 4", start: date("2026-11-24T15:00:00Z"), end: date("2026-11-24T16:00:00Z")),
            DeviceEvent(identifier: "gym", calendarID: "home", title: "Gym", start: date("2026-11-24T18:00:00Z"), end: date("2026-11-24T19:00:00Z")),
            DeviceEvent(identifier: "old", calendarID: "work", title: "Long ago", start: date("2026-01-01T09:00:00Z"), end: date("2026-01-01T10:00:00Z")),
        ]
        serverReturns([block1])
        let engine = makeEngine(busy: ["work"])

        let report = try await engine.sync()

        let body = try stub.lastBody("PUT", "/api/device/events")
        XCTAssertEqual(body["from"] as? String, "2026-11-09T12:00:00.000Z")
        XCTAssertEqual(body["to"] as? String, "2027-01-22T12:00:00.000Z")
        let events = body["events"] as! [[String: Any]]
        XCTAssertEqual(Set(events.map { $0["externalId"] as! String }), [
            "standup@2026-11-24T09:00:00.000Z",
            "standup@2026-11-25T09:00:00.000Z",
            "review",
        ])
        XCTAssertEqual(events.first { $0["externalId"] as? String == "review" }?["notes"] as? String, "Room 4")
        XCTAssertEqual((body["blockChanges"] as! [Any]).count, 0)

        XCTAssertEqual(plannerBlocks.count, 1)
        XCTAssertEqual(plannerBlocks.first?.title, "Write report")
        XCTAssertEqual(plannerBlocks.first?.start, date("2026-11-23T13:00:00Z"))
        XCTAssertEqual(engine.ledger.entries["b1"]?.deviceID, plannerBlocks.first?.identifier)
        XCTAssertEqual(report.uploaded, 3)
        XCTAssertEqual(report.blocksWritten, 1)
        XCTAssertEqual(report.state?.tasks.count, 1)

        // State and ledger survive a relaunch.
        let relaunched = makeEngine()
        XCTAssertEqual(relaunched.cachedState()?.tasks.first?.id, "t1")
        XCTAssertEqual(relaunched.ledger, engine.ledger)
    }

    func testDoesNotUploadPlannerCalendarEvents() async throws {
        serverReturns([block1])
        let engine = makeEngine()
        try await engine.sync()
        try await engine.sync()

        let events = try stub.lastBody("PUT", "/api/device/events")["events"] as! [[String: Any]]
        XCTAssertTrue(events.isEmpty, "the Planner calendar's own blocks must not be mirrored back as busy time")
        XCTAssertEqual(plannerBlocks.count, 1, "an unchanged block is not written twice")
    }

    func testReportsBlocksMovedInAppleCalendarThenFollowsTheServer() async throws {
        serverReturns([block1])
        let engine = makeEngine()
        try await engine.sync()

        // The user drags the block to 15:00 in Apple Calendar.
        let id = plannerBlocks[0].identifier
        _ = try calendar.saveBlock(identifier: id, title: "Write report", notes: "", start: date("2026-11-23T15:00:00Z"), end: date("2026-11-23T16:00:00Z"), in: calendar.plannerID!)

        // The server accepts the move.
        serverReturns([Fixture.block(start: "2026-11-23T15:00:00.000Z", end: "2026-11-23T16:00:00.000Z")])
        let report = try await engine.sync()

        let changes = try stub.lastBody("PUT", "/api/device/events")["blockChanges"] as! [[String: Any]]
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["id"] as? String, "b1")
        XCTAssertEqual(changes[0]["startAt"] as? String, "2026-11-23T15:00:00.000Z")
        XCTAssertEqual(changes[0]["endAt"] as? String, "2026-11-23T16:00:00.000Z")
        XCTAssertEqual(report.blocksWritten, 0)
        XCTAssertEqual(engine.ledger.entries["b1"]?.start, date("2026-11-23T15:00:00Z"))

        // A third sync has nothing to report.
        try await engine.sync()
        XCTAssertEqual((try stub.lastBody("PUT", "/api/device/events")["blockChanges"] as! [Any]).count, 0)
    }

    func testRejectedMovePutsTheBlockBack() async throws {
        serverReturns([block1])
        let engine = makeEngine()
        try await engine.sync()

        let id = plannerBlocks[0].identifier
        _ = try calendar.saveBlock(identifier: id, title: "Write report", notes: "", start: date("2026-11-23T20:00:00Z"), end: date("2026-11-23T21:00:00Z"), in: calendar.plannerID!)
        stub.on("PUT", "/api/device/events") { [block1] _ in
            (200, Fixture.syncResult(blocks: [block1], rejected: #"[{"id":"b1","reason":"Outside working hours"}]"#))
        }

        let report = try await engine.sync()

        XCTAssertEqual(report.rejected.first?.reason, "Outside working hours")
        XCTAssertEqual(plannerBlocks.first?.start, date("2026-11-23T13:00:00Z"))
        XCTAssertEqual(plannerBlocks.first?.identifier, id, "the same calendar event is moved back, not duplicated")
    }

    func testReportsBlocksDeletedInAppleCalendar() async throws {
        serverReturns([block1])
        let engine = makeEngine()
        try await engine.sync()

        try calendar.removeEvent(withIdentifier: plannerBlocks[0].identifier)
        serverReturns([])
        try await engine.sync()

        let changes = try stub.lastBody("PUT", "/api/device/events")["blockChanges"] as! [[String: Any]]
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["id"] as? String, "b1")
        XCTAssertEqual(changes[0]["deleted"] as? Bool, true)
        XCTAssertTrue(engine.ledger.entries.isEmpty)
    }

    func testRemovesBlocksTheServerNoLongerHas() async throws {
        serverReturns([block1, Fixture.block(id: "b2", title: "Plan trip", start: "2026-11-24T10:00:00.000Z", end: "2026-11-24T11:00:00.000Z")])
        let engine = makeEngine()
        try await engine.sync()
        XCTAssertEqual(plannerBlocks.count, 2)

        // An agent deleted b2 on the server.
        serverReturns([block1])
        let report = try await engine.sync()

        XCTAssertEqual(plannerBlocks.map(\.title), ["Write report"])
        XCTAssertEqual(report.blocksRemoved, 1)
        XCTAssertNil(engine.ledger.entries["b2"])
    }

    func testWithoutCalendarAccessOnlyFetchesState() async throws {
        calendar.access = false
        serverReturns([block1])
        let engine = makeEngine()

        let report = try await engine.sync()

        XCTAssertFalse(report.calendarSynced)
        XCTAssertNotNil(report.state)
        XCTAssertFalse(stub.requests.contains { $0.url?.path == "/api/device/events" },
                       "an empty mirror would wipe this device's events on the server")
    }

    func testFailedUploadLeavesTheCalendarAlone() async throws {
        stub.on("PUT", "/api/device/events") { _ in (500, #"{"error":"Something went wrong on the server."}"#) }
        let engine = makeEngine()

        do {
            try await engine.sync()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PlannerAPIError, .server(status: 500, message: "Something went wrong on the server."))
        }
        XCTAssertTrue(plannerBlocks.isEmpty)
        XCTAssertNil(engine.cachedState())
    }
}
