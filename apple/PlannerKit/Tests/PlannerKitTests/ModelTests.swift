import XCTest
@testable import PlannerKit

final class ModelTests: XCTestCase {
    func testDecodesProjectsChecklistsWaitingAndBatches() throws {
        let json = """
        {
          "tasks": [
            {"id":"t1","title":"Send proposal","notes":"","status":"waiting","priority":2,"estimateMin":30,"dueAt":null,
             "createdAt":"2026-11-20T10:00:00.000Z","completedAt":null,"projectId":"p1",
             "checklist":[{"id":"c1","text":"Draft","done":true},{"id":"c2","text":"Send","done":false}],
             "waitingOn":"Sam","followUpAt":"2026-11-25T14:00:00.000Z"}
          ],
          "events": [
            {"id":"b1","title":"Quick: 2 tasks","notes":"","startAt":"2026-11-24T14:00:00.000Z","endAt":"2026-11-24T14:30:00.000Z",
             "allDay":false,"taskId":null,"googleId":null,"externalId":null,"source":"local","projectId":"p1","taskIds":["t2","t3"]}
          ],
          "projects": [
            {"id":"p1","name":"Freelance","tag":"freelance","color":"indigo","emoji":"💼","archived":false,"sortOrder":1,
             "windows":[{"days":[1,2,3],"start":"13:00","end":"17:00"}],"windowStrict":false,"hostMatch":null}
          ],
          "settings": {"timezone":"UTC","timezoneConfirmed":true,"workStart":"09:00","workEnd":"17:00","workDays":[1,2,3,4,5],
                       "maxBlockMin":120,"horizonDays":14,"bufferMin":15,"bufferMinEventMin":120},
          "google": {"configured":false,"connected":false,"lastSyncAt":null,"error":null}
        }
        """
        let state = try PlannerJSON.decoder().decode(AppState.self, from: Data(json.utf8))

        let task = try XCTUnwrap(state.tasks.first)
        XCTAssertEqual(task.status, .waiting)
        XCTAssertTrue(task.isWaiting)
        XCTAssertEqual(task.waitingOn, "Sam")
        XCTAssertEqual(task.checklistProgress, "1/2")
        XCTAssertEqual(task.projectId, "p1")

        let block = try XCTUnwrap(state.events.first)
        XCTAssertTrue(block.isTaskBlock)
        XCTAssertTrue(block.isBatch)
        XCTAssertEqual(block.allTaskIds, ["t2", "t3"])

        XCTAssertEqual(state.projects.first?.label, "💼 Freelance")
        XCTAssertEqual(state.projects.first?.windows.first?.days, [1, 2, 3])
        XCTAssertEqual(state.settings.bufferMin, 15)
    }

    func testDecodesStateFromBeforeProjects() throws {
        // What an older server (or an older cache on disk) sends: no projects, checklists or buffers.
        let state = try PlannerJSON.decoder().decode(AppState.self, from: Data(Fixture.legacyState.utf8))
        XCTAssertEqual(state.projects, [])
        XCTAssertEqual(state.tasks.first?.checklist, [])
        XCTAssertNil(state.tasks.first?.projectId)
        XCTAssertEqual(state.events.first?.taskIds, [])
        XCTAssertEqual(state.settings.bufferMinEventMin, 120)
    }

    func testUnknownValuesFromANewerServerDoNotBreakDecoding() throws {
        let json = #"{"id":"t9","title":"x","notes":"","status":"someday","priority":2,"estimateMin":30,"dueAt":null,"createdAt":"2026-11-20T10:00:00.000Z","completedAt":null}"#
        XCTAssertEqual(try PlannerJSON.decoder().decode(PlannerTask.self, from: Data(json.utf8)).status, .todo)
        XCTAssertEqual(try PlannerJSON.decoder().decode(ProjectColor.self, from: Data(#""plaid""#.utf8)), .slate)
    }

    func testTaskPatchClearsProjectAndFollowUpWithNull() throws {
        let body = try JSONSerialization.jsonObject(with: PlannerJSON.encoder().encode(
            TaskPatch(status: .todo, projectId: .some(nil), checklist: [ChecklistItem(id: "a", text: "Step")], followUpAt: .some(nil))
        )) as! [String: Any]
        XCTAssertTrue(body["projectId"] is NSNull)
        XCTAssertTrue(body["followUpAt"] is NSNull)
        XCTAssertNil(body["waitingOn"], "unset fields are not sent")
        XCTAssertEqual((body["checklist"] as? [[String: Any]])?.first?["text"] as? String, "Step")
    }

    func testBatchBookingSendsEveryTask() throws {
        let block = ProposedBlock(taskId: "a", title: "Quick: 2 tasks", startAt: date("2026-11-24T14:00:00Z"), endAt: date("2026-11-24T14:30:00Z"), late: false, taskIds: ["a", "b"])
        XCTAssertTrue(block.isBatch)
        let body = try JSONSerialization.jsonObject(with: PlannerJSON.encoder().encode(BlockBooking(block))) as! [String: Any]
        XCTAssertEqual(body["taskIds"] as? [String], ["a", "b"])
    }

    func testChecklistFromNotes() {
        let (items, rest) = Checklist.fromNotes("""
        Before the rep visit.
        1. Balance the drawer
        2) Order mix
        - [x] Primer
        * Tape
        Bring the regular's number.
        """)
        XCTAssertEqual(items.map(\.text), ["Balance the drawer", "Order mix", "Primer", "Tape"])
        XCTAssertEqual(items.map(\.done), [false, false, true, false])
        XCTAssertEqual(rest, "Before the rep visit.\nBring the regular's number.")
        XCTAssertTrue(Checklist.fromNotes("Just a sentence. No list.").items.isEmpty)
    }

    func testDecodesLinksContactAndRepeats() throws {
        let json = #"""
        {"id":"t1","title":"Mortgage","notes":"","status":"todo","priority":2,"estimateMin":15,"dueAt":"2026-12-15T22:00:00.000Z",
         "createdAt":"2026-11-20T10:00:00.000Z","completedAt":null,
         "links":[{"label":"Lender","url":"https://example.com/pay"}],
         "contact":{"name":"Matt","email":"matt@example.com"},
         "source":"gmail","externalRef":"thread-1",
         "recurrence":{"freq":"monthly","byMonthDay":[15],"leadTimeDays":3},
         "seriesId":"s1","showFrom":"2099-12-12T05:00:00.000Z"}
        """#
        let task = try PlannerJSON.decoder().decode(PlannerTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.links.first?.destination?.host(), "example.com")
        XCTAssertEqual(task.contact, Contact(name: "Matt", email: "matt@example.com"))
        XCTAssertEqual(task.recurrence?.summary, "Monthly on the 15th · shows 3 days before")
        XCTAssertTrue(task.repeats)
        XCTAssertTrue(task.isUpcoming())

        // The cache writes what it read, so a round trip keeps the new fields.
        let again = try PlannerJSON.decoder().decode(PlannerTask.self, from: PlannerJSON.encoder().encode(task))
        XCTAssertEqual(again, task)
    }

    func testAnUnreadableRepeatRuleIsDropped() throws {
        let json = #"{"id":"t9","title":"x","notes":"","status":"todo","priority":2,"estimateMin":30,"dueAt":null,"createdAt":"2026-11-20T10:00:00.000Z","completedAt":null,"recurrence":{"freq":"yearly"}}"#
        XCTAssertNil(try PlannerJSON.decoder().decode(PlannerTask.self, from: Data(json.utf8)).recurrence)
    }

    func testRepeatSummaries() {
        XCTAssertEqual(Recurrence(freq: .weekly, byDay: [5, 2]).summary, "Every week on Tue, Fri")
        XCTAssertEqual(Recurrence(freq: .weekly, interval: 2, byDay: [7]).summary, "Every 2 weeks on Sun")
        XCTAssertEqual(Recurrence(freq: .daily).summary, "Every day")
        XCTAssertEqual(Recurrence(freq: .monthly, byMonthDay: [1, 22]).summary, "Monthly on the 1st and 22nd")
    }

    func testNormalizesTypedLinks() {
        XCTAssertEqual(TaskLink.normalized(label: "", url: "docs.google.com/d/1"), TaskLink(label: "docs.google.com", url: "https://docs.google.com/d/1"))
        XCTAssertEqual(TaskLink.normalized(label: "Matt", url: "matt@example.com")?.url, "mailto:matt@example.com")
        XCTAssertNil(TaskLink.normalized(label: "x", url: "javascript:alert(1)"))
        XCTAssertNil(TaskLink.normalized(label: "x", url: "  "))
    }

    func testPatchSendsAndClearsTheNewFields() throws {
        let patch = TaskPatch(links: [TaskLink(label: "Doc", url: "https://d")], contact: .some(nil), recurrence: .some(Recurrence(freq: .daily)))
        let body = try JSONSerialization.jsonObject(with: PlannerJSON.encoder().encode(patch)) as! [String: Any]
        XCTAssertEqual((body["links"] as? [[String: String]])?.first?["url"], "https://d")
        XCTAssertTrue(body["contact"] is NSNull)
        XCTAssertEqual((body["recurrence"] as? [String: Any])?["freq"] as? String, "daily")
        XCTAssertNil(body["title"])
    }
}
