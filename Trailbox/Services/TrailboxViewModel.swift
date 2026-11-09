import Foundation
import SwiftUI
import MapKit

@MainActor
final class TrailboxViewModel: ObservableObject {
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var pointIndex = 0
    @Published private(set) var events: [TrailEvent] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published var speed: Int = 10
    @Published var forcedOffline = false
    @Published var fakeStorm = false
    @Published var fakeLowBattery = false
    @Published var heartRate: Double = 86
    @Published private(set) var errorMessage: String?
    @Published private(set) var groupName = ""
    @Published private(set) var contactName = ""
    @Published private(set) var contactEmail = ""
    @Published private(set) var expectedReturn = Date().addingTimeInterval(3 * 3_600)
    @Published var cameraPosition: MapCameraPosition = .automatic
    @Published private(set) var cloudStatus = "Not configured"
    @Published private(set) var edgeStatus = "Not connected"
    @Published private(set) var connectedPeers = 0
    @Published private(set) var uploadedEventIDs: Set<String> = []
    @Published private(set) var relay: EdgeRelayService?

    let deviceID: String
    private(set) var tripID: String
    private var store: EventStore?
    private var timer: Timer?
    private var uploadInFlight = false
    private var uploadQueued = false

    var currentPoint: TrackPoint? { points.indices.contains(pointIndex) ? points[pointIndex] : nil }
    var route: [CLLocationCoordinate2D] { points.map(\.coordinate) }
    var isFinished: Bool { !points.isEmpty && pointIndex == points.count - 1 }
    var simulatedTime: Date {
        (points.first?.timestamp ?? Date()).addingTimeInterval(elapsedSeconds)
    }
    var pendingCount: Int { events.filter { !uploadedEventIDs.contains($0.id) }.count }
    var edgeConnected: Bool { connectedPeers > 0 || cloudStatus.hasPrefix("Trailhead synced") }
    var lastSignalCoordinate: CLLocationCoordinate2D? {
        guard let event = events.last(where: { $0.type == .sync }),
              let latitude = event.payload["latitude"].flatMap(Double.init),
              let longitude = event.payload["longitude"].flatMap(Double.init) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var lastSignalDistanceMeters: Int? {
        guard let lastSignalCoordinate, let currentPoint else { return nil }
        let a = CLLocation(latitude: lastSignalCoordinate.latitude, longitude: lastSignalCoordinate.longitude)
        let b = CLLocation(latitude: currentPoint.latitude, longitude: currentPoint.longitude)
        return Int(a.distance(from: b).rounded())
    }
    var hasTripPlan: Bool { (!groupName.isEmpty && !contactEmail.isEmpty) || events.contains(where: { $0.type == .tripPlan }) }

    init() {
        let defaults = UserDefaults.standard
        uploadedEventIDs = Set(defaults.stringArray(forKey: "trailbox.uploadedEventIDs") ?? [])
        groupName = defaults.string(forKey: "trailbox.groupName") ?? ""
        contactName = defaults.string(forKey: "trailbox.contactName") ?? ""
        contactEmail = defaults.string(forKey: "trailbox.contactEmail") ?? ""
        if defaults.object(forKey: "trailbox.expectedReturn") != nil {
            expectedReturn = Date(timeIntervalSince1970: defaults.double(forKey: "trailbox.expectedReturn"))
        }
        if let existing = defaults.string(forKey: "trailbox.deviceID") { deviceID = existing }
        else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "trailbox.deviceID")
            deviceID = id
        }
        if let existing = defaults.string(forKey: "trailbox.tripID") { tripID = existing }
        else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "trailbox.tripID")
            tripID = id
        }
        do {
            points = try GPXTrack.bundled()
            store = try EventStore()
            events = try store?.events(for: tripID) ?? []
            if let first = points.first {
                cameraPosition = .region(MKCoordinateRegion(center: first.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
            }
        } catch { errorMessage = "Setup failed: \(error.localizedDescription)" }
        configureRelay()
        if UserDefaults.standard.string(forKey: "trailbox.guardianURL") != nil {
            cloudStatus = "Pending upload"
            Task { await syncCloud() }
        }
    }

    func dismissError() { errorMessage = nil }

    func startRelay() { relay?.start() }
    func stopRelay() { relay?.stop() }

    func joinTrip(code: String) {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard UUID(uuidString: value) != nil else { errorMessage = "Enter a valid trip code"; return }
        guard !isPlaying else { errorMessage = "Pause the hike before joining a trip"; return }
        relay?.stop()
        tripID = value
        UserDefaults.standard.set(value, forKey: "trailbox.tripID")
        groupName = ""
        contactName = ""
        contactEmail = ""
        UserDefaults.standard.removeObject(forKey: "trailbox.groupName")
        UserDefaults.standard.removeObject(forKey: "trailbox.contactName")
        UserDefaults.standard.removeObject(forKey: "trailbox.contactEmail")
        do {
            events = try store?.events(for: tripID) ?? []
            applyTripPlanFromLog()
        } catch { errorMessage = "Event log: \(error.localizedDescription)" }
        configureRelay()
        relay?.start()
    }

    private func configureRelay() {
        let service = EdgeRelayService(tripID: tripID, deviceID: deviceID)
        service.onStatus = { [weak self] status, count in
            self?.edgeStatus = status
            self?.connectedPeers = count
        }
        service.eventsProvider = { [weak self] in self?.events ?? [] }
        service.receiveEvents = { [weak self] incoming in
            guard let self, let store = self.store else { return }
            do {
                try store.merge(incoming)
                self.events = try store.events(for: self.tripID)
                self.applyTripPlanFromLog()
                if UserDefaults.standard.string(forKey: "trailbox.guardianURL") != nil {
                    Task { await self.syncCloud() }
                }
            } catch { self.errorMessage = "Relay merge: \(error.localizedDescription)" }
        }
        relay = service
    }

    private func applyTripPlanFromLog() {
        guard let payload = events.last(where: { $0.type == .tripPlan })?.payload else { return }
        groupName = payload["group"] ?? ""
        contactName = payload["contact_name"] ?? ""
        contactEmail = payload["contact_email"] ?? ""
        if let value = payload["expected_return"],
           let date = ISO8601DateFormatter().date(from: value) { expectedReturn = date }
    }

    func configureGuardian(url: String, token: String) -> Bool {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: value), ["https", "http"].contains(parsed.scheme),
              parsed.host != nil, !token.isEmpty else {
            errorMessage = "Enter a Guardian URL and token"
            return false
        }
        guard TrailSecurity.save(token, key: "guardianToken") else {
            errorMessage = "Could not secure Guardian token"
            return false
        }
        UserDefaults.standard.set(value.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                  forKey: "trailbox.guardianURL")
        cloudStatus = "Configured; pending upload"
        Task { await syncCloud() }
        return true
    }

    func syncCloud() async {
        if uploadInFlight { uploadQueued = true; return }
        uploadInFlight = true
        defer {
            uploadInFlight = false
            if uploadQueued {
                uploadQueued = false
                Task { await syncCloud() }
            }
        }
        guard let plan = events.last(where: { $0.type == .tripPlan }),
              let group = plan.payload["group"],
              let contact = plan.payload["contact_name"],
              let email = plan.payload["contact_email"],
              let returnString = plan.payload["expected_return"],
              let returnDate = ISO8601DateFormatter().date(from: returnString) else {
            cloudStatus = "Save trip plan first"
            return
        }
        guard !forcedOffline else { cloudStatus = "Offline; events queued locally"; return }
        cloudStatus = "Uploading events…"
        do {
            try await CloudGuardianClient.upload(tripID: tripID, groupName: group,
                                                  contactName: contact, contactEmail: email,
                                                  expectedReturn: returnDate, events: events)
            uploadedEventIDs.formUnion(events.map(\.id))
            UserDefaults.standard.set(Array(uploadedEventIDs), forKey: "trailbox.uploadedEventIDs")
            let hostname = URL(string: UserDefaults.standard.string(forKey: "trailbox.guardianURL") ?? "")?.host ?? ""
            let local = hostname.hasSuffix(".local") || hostname == "localhost" || hostname.hasPrefix("192.168.") || hostname.hasPrefix("10.")
            cloudStatus = local ? "Trailhead synced \(events.count) events" : "Synced \(events.count) events"
            recordSignalBreadcrumb()
        } catch { cloudStatus = "Upload pending: \(error.localizedDescription)" }
    }

    func startOrPause() {
        if isPlaying { stopTimer(); return }
        guard !points.isEmpty, !isFinished else { return }
        guard hasTripPlan else { errorMessage = "Save a trip plan before starting"; return }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if pointIndex == 0 { recordPosition() }
    }

    func nextPoint() {
        guard pointIndex + 1 < points.count else { stopTimer(); return }
        pointIndex += 1
        elapsedSeconds = points[pointIndex].timestamp.timeIntervalSince(points[0].timestamp)
        recordPosition()
        focusCurrentPoint()
        evaluateDemoSafety()
        if isFinished { stopTimer() }
    }

    func resetReplay() {
        stopTimer()
        pointIndex = 0
        elapsedSeconds = 0
        focusCurrentPoint()
        // Historical events are intentionally never deleted; Reset rewinds the visual replay only.
    }

    func logVitals() {
        write(.vitals, payload: ["heart_rate_bpm": String(Int(heartRate)),
                                 "battery_simulated_low": String(fakeLowBattery),
                                 "barometer_simulated_drop": String(fakeStorm)])
        evaluateDemoSafety()
    }

    func evaluateDemoSafety() {
        if fakeStorm && SafetyRules.storm(olderHectopascals: 1012, currentHectopascals: 1009,
                                          elapsedMinutes: 30, adverseForecast: true) {
            warnOnce(rule: "storm", message: "Simulated pressure drop and adverse forecast: consider turning back.")
        }
        if fakeLowBattery && SafetyRules.batteryCritical(currentPercent: 18,
                                                          drainPercentPerHour: 8,
                                                          hoursUntilReturn: 1) {
            warnOnce(rule: "battery", message: "Simulated battery may fall below 15% before return.")
        }
    }

    private func warnOnce(rule: String, message: String) {
        guard !events.contains(where: { $0.type == .warning && $0.payload["rule"] == rule }) else { return }
        write(.warning, payload: ["rule": rule, "message": message, "source": "deterministic_demo"])
    }

    func checkIn() { write(.checkedIn, payload: ["mode": "demo", "status": "safe"]) }

    @discardableResult
    func saveTripPlan(groupName: String, contactName: String, contactEmail: String,
                      expectedReturn: Date, medical: String) -> Bool {
        guard TrailSecurity.save(medical, key: "medical.\(tripID)") else {
            errorMessage = "Could not secure medical details in Keychain"
            return false
        }
        self.groupName = groupName
        self.contactName = contactName
        self.contactEmail = contactEmail
        self.expectedReturn = expectedReturn
        let defaults = UserDefaults.standard
        defaults.set(groupName, forKey: "trailbox.groupName")
        defaults.set(contactName, forKey: "trailbox.contactName")
        defaults.set(contactEmail, forKey: "trailbox.contactEmail")
        defaults.set(expectedReturn.timeIntervalSince1970, forKey: "trailbox.expectedReturn")
        return write(.tripPlan, payload: ["group": groupName, "contact_name": contactName,
                                          "contact_email": contactEmail,
                                          "expected_return": ISO8601DateFormatter().string(from: expectedReturn),
                                          "route": "sample-hike.gpx"])
    }


    func recordAgentNote(question: String, answer: String) {
        write(.agentNote, payload: ["question": question, "answer": answer,
                                    "model": "LFM2.5-1.2B-Instruct-Q4_0", "source": "on_device"])
    }

    @discardableResult
    func recordEmergency(whatHappened: String, injuries: String, people: Int,
                         canWalk: Bool, coordinate: CLLocationCoordinate2D?,
                         locationSource: String) -> Bool {
        var payload = ["what_happened": whatHappened, "injuries": injuries,
                       "people_affected": String(people), "can_walk": String(canWalk),
                       "location_source": locationSource, "delivery": "local_pending",
                       "group": groupName]
        if let medical = TrailSecurity.read("medical.\(tripID)"), !medical.isEmpty {
            payload["medical"] = medical
        }
        if let coordinate {
            payload["latitude"] = String(coordinate.latitude)
            payload["longitude"] = String(coordinate.longitude)
        }
        return write(.sos, payload: payload)
    }

    private func recordSignalBreadcrumb() {
        guard let currentPoint, let store else { return }
        let index = String(pointIndex)
        if events.last(where: { $0.type == .sync })?.payload["waypoint_index"] == index { return }
        let event = TrailEvent(tripID: tripID, deviceID: deviceID, type: .sync,
            payload: ["latitude": String(currentPoint.latitude),
                      "longitude": String(currentPoint.longitude),
                      "waypoint_index": index, "transport": "guardian", "source": "gpx_replay"])
        do {
            try store.append(event)
            events = try store.events(for: tripID)
            relay?.sendSnapshot()
        } catch { errorMessage = "Signal breadcrumb: \(error.localizedDescription)" }
    }

    private func tick() {
        guard !points.isEmpty else { return }
        elapsedSeconds += Double(speed)
        while pointIndex + 1 < points.count,
              points[pointIndex + 1].timestamp.timeIntervalSince(points[0].timestamp) <= elapsedSeconds {
            pointIndex += 1
            recordPosition()
            focusCurrentPoint()
        }
        evaluateDemoSafety()
        if isFinished { stopTimer() }
    }

    private func recordPosition() {
        guard let currentPoint else { return }
        write(.position, payload: [
            "latitude": String(currentPoint.latitude),
            "longitude": String(currentPoint.longitude),
            "elevation_m": String(currentPoint.elevationMeters),
            "replay_time": ISO8601DateFormatter().string(from: simulatedTime),
            "source": "gpx_replay"
        ])
    }

    @discardableResult
    private func write(_ type: TrailEventType, payload: [String: String]) -> Bool {
        guard let store else {
            errorMessage = "Event log is unavailable"
            return false
        }
        let event = TrailEvent(tripID: tripID, deviceID: deviceID, type: type, payload: payload)
        do {
            let inserted = try store.append(event)
            events = try store.events(for: tripID)
            relay?.sendSnapshot()
            if UserDefaults.standard.string(forKey: "trailbox.guardianURL") != nil {
                Task { await syncCloud() }
            }
            return inserted
        } catch {
            errorMessage = "Event log: \(error.localizedDescription)"
            return false
        }
    }

    private func focusCurrentPoint() {
        guard let currentPoint else { return }
        cameraPosition = .region(MKCoordinateRegion(center: currentPoint.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.017, longitudeDelta: 0.017)))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }
}
