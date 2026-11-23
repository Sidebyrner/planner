import Foundation
@testable import PlannerKit

/// Answers requests from handlers keyed by "METHOD /path", and records every request.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, String)

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func on(_ method: String, _ path: String, _ handler: @escaping Handler) {
        lock.withLock { handlers["\(method) \(path)"] = handler }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let handler = lock.withLock { () -> Handler? in
            recorded.append(request)
            return handlers[key]
        }
        let (status, body) = try handler?(request) ?? (404, #"{"error":"no stub for \#(key)"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }

    /// The JSON body of the last request to `path`.
    func lastBody(_ method: String, _ path: String) throws -> [String: Any] {
        let request = try XCTUnwrapCompat(requests.last { $0.httpMethod == method && $0.url?.path == path })
        let data = try XCTUnwrapCompat(request.httpBody)
        return try XCTUnwrapCompat(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

struct MissingValue: Error {}

func XCTUnwrapCompat<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingValue() }
    return value
}

func date(_ iso: String) -> Date {
    PlannerJSON.parseDate(iso)!
}

enum Fixture {
    static func block(id: String = "b1", taskId: String = "t1", title: String = "Write report", start: String, end: String) -> String {
        """
        {"id":"\(id)","title":"\(title)","notes":"","startAt":"\(start)","endAt":"\(end)","allDay":false,"taskId":"\(taskId)","googleId":null,"externalId":null,"source":"local"}
        """
    }

    static func syncResult(blocks: [String] = [], rejected: String = "[]") -> String {
        #"{"upserted":0,"removed":0,"blocks":[\#(blocks.joined(separator: ","))],"rejected":\#(rejected)}"#
    }

    static let state = """
    {
      "tasks": [
        {"id":"t1","title":"Write report","notes":"","status":"todo","priority":3,"estimateMin":90,
         "dueAt":"2026-11-25T17:00:00.000Z","createdAt":"2026-11-20T10:00:00.000Z","completedAt":null}
      ],
      "events": [
        {"id":"e9","title":"Dentist","notes":"","startAt":"2026-11-24T08:00:00.000Z","endAt":"2026-11-24T09:00:00.000Z",
         "allDay":false,"taskId":null,"googleId":null,"externalId":"abc","source":"device"}
      ],
      "settings": {"timezone":"Europe/London","timezoneConfirmed":true,"workStart":"09:00","workEnd":"17:00",
                   "workDays":[1,2,3,4,5],"maxBlockMin":120,"horizonDays":14},
      "google": {"configured":false,"connected":false,"lastSyncAt":null,"error":null}
    }
    """
}
