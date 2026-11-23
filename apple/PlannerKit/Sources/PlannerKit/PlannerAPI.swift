import Foundation

/// The HTTP layer, so tests can stand in for the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public enum PlannerAPIError: Error, Equatable, LocalizedError {
    /// The server rejected the device token (or none was set).
    case unauthorized
    /// The server answered with an error; `message` is its `error` field.
    case server(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The server did not accept the device token. Check it in Settings."
        case let .server(_, message): message
        case .invalidResponse: "The server sent a response Planner could not read."
        }
    }
}

/// Client for the Planner server's JSON API (src/server/api.ts).
public struct PlannerAPI: Sendable {
    public var baseURL: URL
    /// The server's DEVICE_TOKEN. Sent as `Authorization: Bearer …`.
    public var token: String?
    private let transport: any HTTPTransport

    public init(baseURL: URL, token: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    // MARK: Endpoints

    public func health() async throws -> Bool {
        struct Health: Decodable { var ok: Bool }
        return try await call("GET", "healthz", as: Health.self).ok
    }

    public func state() async throws -> AppState {
        try await call("GET", "api/state")
    }

    public func createTask(_ draft: TaskDraft) async throws -> PlannerTask {
        try await call("POST", "api/tasks", body: draft)
    }

    public func updateTask(id: String, _ patch: TaskPatch) async throws -> PlannerTask {
        try await call("PATCH", "api/tasks/\(id)", body: patch)
    }

    public func deleteTask(id: String) async throws {
        _ = try await call("DELETE", "api/tasks/\(id)", as: OK.self)
    }

    public func createEvent(_ draft: EventDraft) async throws -> CalEvent {
        try await call("POST", "api/events", body: draft)
    }

    public func updateEvent(id: String, _ patch: EventPatch) async throws -> CalEvent {
        try await call("PATCH", "api/events/\(id)", body: patch)
    }

    public func deleteEvent(id: String) async throws {
        _ = try await call("DELETE", "api/events/\(id)", as: OK.self)
    }

    /// How the server would read `text`, without saving anything.
    public func previewCapture(_ text: String) async throws -> Captured {
        struct Body: Encodable { var text: String; var preview = true }
        struct Preview: Decodable { var parsed: Captured }
        return try await call("POST", "api/capture", body: Body(text: text), as: Preview.self).parsed
    }

    /// Saves `text` as a task or an event, as the server reads it.
    public func capture(_ text: String) async throws -> CaptureResult {
        struct Body: Encodable { var text: String }
        return try await call("POST", "api/capture", body: Body(text: text))
    }

    public func proposeSchedule() async throws -> ScheduleProposal {
        try await call("POST", "api/schedule/propose")
    }

    public func applySchedule(_ blocks: [BlockBooking]) async throws -> [CalEvent] {
        struct Body: Encodable { var blocks: [BlockBooking] }
        return try await call("POST", "api/schedule/apply", body: Body(blocks: blocks))
    }

    public func projects() async throws -> [Project] {
        try await call("GET", "api/projects")
    }

    /// `patch.name` is required when creating.
    public func createProject(_ patch: ProjectPatch) async throws -> Project {
        try await call("POST", "api/projects", body: patch)
    }

    public func updateProject(id: String, _ patch: ProjectPatch) async throws -> Project {
        try await call("PATCH", "api/projects/\(id)", body: patch)
    }

    public enum ProjectRemoval: String, Decodable, Sendable { case deleted, archived }

    /// Deletes an unused project; archives one that has tasks.
    public func removeProject(id: String) async throws -> ProjectRemoval {
        struct Result: Decodable { var result: ProjectRemoval }
        return try await call("DELETE", "api/projects/\(id)", as: Result.self).result
    }

    public func updateSettings(_ patch: SettingsPatch) async throws -> Settings {
        try await call("PUT", "api/settings", body: patch)
    }

    public func syncDevice(_ request: DeviceSyncRequest) async throws -> DeviceSyncResult {
        try await call("PUT", "api/device/events", body: request)
    }

    // MARK: Plumbing

    private struct OK: Decodable {}
    private struct ErrorBody: Decodable { var error: String }

    private func call<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try PlannerJSON.encoder().encode(body)
        }

        let (data, response) = try await transport.send(request)
        guard let http = response as? HTTPURLResponse else { throw PlannerAPIError.invalidResponse }
        if http.statusCode == 401 { throw PlannerAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw PlannerAPIError.server(status: http.statusCode, message: message)
        }
        do {
            return try PlannerJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw PlannerAPIError.invalidResponse
        }
    }
}
