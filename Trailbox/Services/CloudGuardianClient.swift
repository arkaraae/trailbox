import Foundation

/// Ships immutable events to a configured Guardian. Retries are safe because IDs are stable.
enum CloudGuardianClient {
    enum UploadError: LocalizedError {
        case notConfigured, invalidResponse(Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Set a Guardian URL and token first"
            case .invalidResponse(let code): "Guardian returned HTTP \(code)"
            }
        }
    }

    static func upload(tripID: String, groupName: String, contactName: String,
                       contactEmail: String, expectedReturn: Date,
                       events: [TrailEvent]) async throws {
        guard let rawURL = UserDefaults.standard.string(forKey: "trailbox.guardianURL"),
              let base = URL(string: rawURL), ["https", "http"].contains(base.scheme),
              let token = TrailSecurity.read("guardianToken"), !token.isEmpty else {
            throw UploadError.notConfigured
        }
        let formatter = ISO8601DateFormatter()
        let plan: [String: String] = ["tripID": tripID, "groupName": groupName,
                                      "contactName": contactName, "contactEmail": contactEmail,
                                      "expectedReturn": formatter.string(from: expectedReturn)]
        try await post(plan, to: base.appending(path: "trip"), token: token)
        try await uploadEvents(events)
    }

    static func uploadEvents(_ events: [TrailEvent]) async throws {
        guard let rawURL = UserDefaults.standard.string(forKey: "trailbox.guardianURL"),
              let base = URL(string: rawURL), ["https", "http"].contains(base.scheme),
              let token = TrailSecurity.read("guardianToken"), !token.isEmpty else {
            throw UploadError.notConfigured
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(EventBatch(events: events))
        try await post(body, to: base.appending(path: "events"), token: token)
    }

    struct GuardianStatus: Decodable {
        let escalations: [Escalation]
        struct Escalation: Decodable {
            let status: String
            let packet: String?
            let lastError: String?
        }
    }

    static func fetchStatus(tripID: String) async throws -> GuardianStatus {
        guard let rawURL = UserDefaults.standard.string(forKey: "trailbox.guardianURL"),
              let base = URL(string: rawURL),
              let token = TrailSecurity.read("guardianToken"), !token.isEmpty else {
            throw UploadError.notConfigured
        }
        var request = URLRequest(url: base.appending(path: "status").appending(path: tripID))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GuardianStatus.self, from: data)
    }

    private struct EventBatch: Encodable { let events: [TrailEvent] }

    private static func post<T: Encodable>(_ value: T, to url: URL, token: String) async throws {
        try await post(JSONEncoder().encode(value), to: url, token: token)
    }

    private static func post(_ body: Data, to url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
