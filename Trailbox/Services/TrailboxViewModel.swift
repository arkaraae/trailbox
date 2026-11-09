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
    @Published private(set) var activeIncidentID: String?
    @Published private(set) var isLiveTracking = false
    @Published private(set) var liveStatus = "Live tracking off"
    @Published private(set) var liveCoordinate: CLLocationCoordinate2D?
    @Published private(set) var liveElapsedSeconds: TimeInterval = 0
    @Published private(set) var liveDistanceMeters: Double = 0
    @Published private(set) var checkInReason: String?
    @Published private(set) var checkInPromptedAt: Date?
    @Published private(set) var importedRouteName: String?

    let deviceID: String
    private(set) var tripID: String
    private var store: EventStore?
    private var timer: Timer?
    private var uploadInFlight = false
    private var uploadQueued = false
    private let liveMonitor = LiveTrailMonitor()
    private var liveTimer: Timer?
    private var lastMovement = Date()
    private var lastLocation: CLLocation?
    private var previousLiveLocation: CLLocation?
    private var liveStartedAt: Date?
    private var offRouteSamples = 0
    private var relayIncidentID: String?

    var currentPoint: TrackPoint? { points.indices.contains(pointIndex) ? points[pointIndex] : nil }
    var route: [CLLocationCoordinate2D] { points.map(\.coordinate) }
    var isFinished: Bool { !points.isEmpty && pointIndex == points.count - 1 }
    var simulatedTime: Date {
        (points.first?.timestamp ?? Date()).addingTimeInterval(elapsedSeconds)
    }
    var pendingCount: Int { events.filter { !uploadedEventIDs.contains($0.id) }.count }
    var edgeConnected: Bool { connectedPeers > 0 || cloudStatus.hasPrefix("Trailhead synced") }
    var lastSignalCoordinate: CLLocationCoordinate2D? {
        guard let event = events.last(where: { $0.tripID == tripID && $0.type == .sync }),
              let latitude = event.payload["latitude"].flatMap(Double.init),
              let longitude = event.payload["longitude"].flatMap(Double.init) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var lastSignalDistanceMeters: Int? {
        guard let lastSignalCoordinate else { return nil }
        guard let position = isLiveTracking ? liveCoordinate : currentPoint?.coordinate else { return nil }
        let a = CLLocation(latitude: lastSignalCoordinate.latitude, longitude: lastSignalCoordinate.longitude)
        let b = CLLocation(latitude: position.latitude, longitude: position.longitude)
        return Int(a.distance(from: b).rounded())
    }
    var hasTripPlan: Bool { (!groupName.isEmpty && !contactEmail.isEmpty) || events.contains(where: { $0.tripID == tripID && $0.type == .tripPlan }) }
    var nearbyIncidents: [TrailEvent] {
        events.filter { $0.tripID == activeIncidentID && $0.type == .sos && $0.deviceID != deviceID }
    }

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
            events = try store?.allEvents() ?? []
            applyTripPlanFromLog()
            if let first = points.first {
                cameraPosition = .region(MKCoordinateRegion(center: first.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
            }
        } catch { errorMessage = "Setup failed: \(error.localizedDescription)" }
        configureRelay(for: tripID)
        liveMonitor.onStatus = { [weak self] in self?.liveStatus = $0 }
        liveMonitor.onImpact = { [weak self] impact in
            self?.raiseCheckIn(reason: "possible_fall", detail: String(format: "Impact %.1f g", impact))
        }
        liveMonitor.onLocation = { [weak self] location in self?.recordLiveLocation(location) }
        if UserDefaults.standard.string(forKey: "trailbox.guardianURL") != nil {
            cloudStatus = "Pending upload"
            Task { await syncCloud() }
        }
    }

    func dismissError() { errorMessage = nil }

    func startRelay() { relay?.start() }
    func stopRelay() { relay?.stop() }

    /// The helper enters the incident code visible on the injured phone. Their own trip stays intact.
    func helpIncident(code: String) {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard UUID(uuidString: value) != nil else { errorMessage = "Enter the incident code shown on the injured phone"; return }
        relay?.stop()
        activeIncidentID = value
        configureRelay(for: value)
        relay?.start()
    }

    private func configureRelay(for incidentID: String) {
        relayIncidentID = incidentID
        let service = EdgeRelayService(tripID: incidentID, deviceID: deviceID)
        service.onStatus = { [weak self] status, count in
            self?.edgeStatus = status
            self?.connectedPeers = count
        }
        service.eventsProvider = { [weak self] in self?.events ?? [] }
        service.receiveEvents = { [weak self] incoming in
            guard let self, let store = self.store else { return }
            do {
                try store.merge(incoming)
                self.events = try store.allEvents()
                if UserDefaults.standard.string(forKey: "trailbox.guardianURL") != nil {
                    Task { await self.syncCloud() }
                }
            } catch { self.errorMessage = "Incident merge: \(error.localizedDescription)" }
        }
        relay = service
    }

    private func applyTripPlanFromLog() {
        guard let payload = events.last(where: { $0.tripID == tripID && $0.type == .tripPlan })?.payload else { return }
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
        let plan = events.last(where: { $0.tripID == tripID && $0.type == .tripPlan })
        guard !forcedOffline else { cloudStatus = "Offline; events queued locally"; return }
        cloudStatus = "Uploading events…"
        do {
            if let plan,
               let group = plan.payload["group"],
               let contact = plan.payload["contact_name"],
               let email = plan.payload["contact_email"],
               let returnString = plan.payload["expected_return"],
               let returnDate = ISO8601DateFormatter().date(from: returnString) {
                try await CloudGuardianClient.upload(tripID: tripID, groupName: group,
                                                      contactName: contact, contactEmail: email,
                                                      expectedReturn: returnDate, events: events)
            } else {
                try await CloudGuardianClient.uploadEvents(events)
            }
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
                                          "route": importedRouteName ?? "sample-hike.gpx"])
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
                       "group": groupName,
                       "contact_name": contactName, "contact_email": contactEmail,
                       "expected_return": ISO8601DateFormatter().string(from: expectedReturn),
                       "route": importedRouteName ?? "sample-hike.gpx"]
        if let medical = TrailSecurity.read("medical.\(tripID)"), !medical.isEmpty {
            payload["medical"] = medical
        }
        if let coordinate {
            payload["latitude"] = String(coordinate.latitude)
            payload["longitude"] = String(coordinate.longitude)
        }
        let saved = write(.sos, payload: payload)
        if saved {
            activeIncidentID = tripID
            if relayIncidentID != tripID {
                relay?.stop()
                configureRelay(for: tripID)
            }
            relay?.start()
        }
        return saved
    }

    @discardableResult
    func recordHelperVoice(for incidentID: String, transcript: String, audioBase64: String) -> Bool {
        guard events.contains(where: { $0.tripID == incidentID && $0.type == .sos }) else {
            errorMessage = "Receive the incident before recording a helper note"
            return false
        }
        let event = TrailEvent(tripID: incidentID, deviceID: deviceID, type: .injuryVoice,
            payload: ["transcript": transcript, "audio_m4a_base64": audioBase64,
                      "captured_by": "nearby_helper", "source": "voice_recording"])
        return appendEvent(event)
    }

    private func recordSignalBreadcrumb() {
        guard let store else { return }
        let coordinate = isLiveTracking ? liveCoordinate : currentPoint?.coordinate
        guard let coordinate else { return }
        let marker = isLiveTracking ? String(Int(Date().timeIntervalSince1970 / 60)) : String(pointIndex)
        if events.last(where: { $0.tripID == tripID && $0.type == .sync })?.payload["marker"] == marker { return }
        let event = TrailEvent(tripID: tripID, deviceID: deviceID, type: .sync,
            payload: ["latitude": String(coordinate.latitude),
                      "longitude": String(coordinate.longitude),
                      "marker": marker, "transport": "guardian",
                      "source": isLiveTracking ? "live_gps" : "gpx_replay"])
        do {
            try store.append(event)
            events = try store.allEvents()
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
        appendEvent(TrailEvent(tripID: tripID, deviceID: deviceID, type: type, payload: payload))
    }

    @discardableResult
    private func appendEvent(_ event: TrailEvent) -> Bool {
        guard let store else { errorMessage = "Event log is unavailable"; return false }
        do {
            let inserted = try store.append(event)
            events = try store.allEvents()
            relay?.sendSnapshot()
            if UserDefaults.standard.string(forKey: "trailbox.guardianURL") != nil {
                Task { await syncCloud() }
            }
            return inserted
        } catch { errorMessage = "Event log: \(error.localizedDescription)"; return false }
    }

    func importRoute(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let parsed = try GPXTrack.parse(data: Data(contentsOf: url))
            points = parsed
            pointIndex = 0
            importedRouteName = url.lastPathComponent
            focusCurrentPoint()
        } catch { errorMessage = "GPX import failed: \(error.localizedDescription)" }
    }

    func startLive() {
        guard hasTripPlan else { errorMessage = "Save a trip plan first"; return }
        stopTimer()
        isLiveTracking = true
        lastMovement = Date()
        liveStartedAt = Date()
        liveElapsedSeconds = 0
        liveDistanceMeters = 0
        previousLiveLocation = nil
        lastLocation = nil
        liveMonitor.start()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateLiveSafety() }
        }
    }

    func stopLive() {
        isLiveTracking = false
        liveTimer?.invalidate()
        liveTimer = nil
        liveMonitor.stop()
    }

    private func recordLiveLocation(_ location: CLLocation) {
        guard isLiveTracking, location.horizontalAccuracy <= 65 else { return }
        liveCoordinate = location.coordinate
        if let previous = previousLiveLocation {
            let segment = location.distance(from: previous)
            if segment >= 5 && segment <= 100 { liveDistanceMeters += segment }
        }
        previousLiveLocation = location
        if let previous = lastLocation, location.distance(from: previous) >= 15 {
            lastMovement = Date()
        }
        if lastLocation == nil { lastLocation = location }
        cameraPosition = .region(MKCoordinateRegion(center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        write(.position, payload: ["latitude": String(location.coordinate.latitude),
                                  "longitude": String(location.coordinate.longitude),
                                  "accuracy_m": String(location.horizontalAccuracy), "source": "live_gps"])
        if importedRouteName != nil {
            if let nearest = points.indices.min(by: {
                CLLocation(latitude: points[$0].latitude, longitude: points[$0].longitude).distance(from: location) <
                CLLocation(latitude: points[$1].latitude, longitude: points[$1].longitude).distance(from: location)
            }) { pointIndex = nearest }
            let distance = SafetyRules.distanceFromRouteMeters(location.coordinate, route: route)
            offRouteSamples = distance > 60 ? offRouteSamples + 1 : 0
            if offRouteSamples >= 2 {
                raiseCheckIn(reason: "off_route", detail: String(format: "%.0f m from route", distance))
            }
        }
        evaluateLiveSafety()
    }

    private func evaluateLiveSafety() {
        guard isLiveTracking else { return }
        if let liveStartedAt { liveElapsedSeconds = Date().timeIntervalSince(liveStartedAt) }
        if let promptedAt = checkInPromptedAt,
           SafetyRules.checkInExpired(now: Date(), promptedAt: promptedAt) {
            let reason = checkInReason ?? "unanswered_check_in"
            checkInReason = nil
            checkInPromptedAt = nil
            _ = recordEmergency(whatHappened: "No response to \(reason) check-in",
                                injuries: "unknown", people: 1, canWalk: false,
                                coordinate: liveCoordinate, locationSource: liveCoordinate == nil ? "unavailable" : "live_gps")
        } else if lastLocation != nil && checkInReason == nil && SafetyRules.needsStillnessCheckIn(now: Date(), lastMovement: lastMovement) {
            raiseCheckIn(reason: "stillness", detail: "No movement for 20 minutes")
        }
    }

    private func raiseCheckIn(reason: String, detail: String) {
        guard isLiveTracking, checkInReason == nil else { return }
        checkInReason = reason
        checkInPromptedAt = Date()
        write(.warning, payload: ["rule": reason, "message": detail,
                                  "action": "check_in_requested", "source": "deterministic_live"])
    }

    func simulateFallCheckIn() {
        guard isLiveTracking else { errorMessage = "Start live monitoring first"; return }
        if SafetyRules.possibleFall(impactG: 3.2) {
            raiseCheckIn(reason: "possible_fall", detail: "Demo impact 3.2 g")
        }
    }

    func simulateOffRouteCheckIn() {
        guard isLiveTracking, let first = route.first else { errorMessage = "Start monitoring with a route first"; return }
        let offset = CLLocationCoordinate2D(latitude: first.latitude + 0.002, longitude: first.longitude)
        if SafetyRules.offRoute(offset, route: route) {
            raiseCheckIn(reason: "off_route", detail: "Demo position more than 60 m from route")
        }
    }

    func simulateStillnessCheckIn() {
        guard isLiveTracking else { errorMessage = "Start live monitoring first"; return }
        lastLocation = CLLocation(latitude: liveCoordinate?.latitude ?? 0,
                                  longitude: liveCoordinate?.longitude ?? 0)
        lastMovement = Date().addingTimeInterval(-21 * 60)
        evaluateLiveSafety()
    }

    func confirmSafe() {
        guard let reason = checkInReason else { return }
        checkInReason = nil
        checkInPromptedAt = nil
        lastMovement = Date()
        offRouteSamples = 0
        write(.checkedIn, payload: ["reason": reason, "status": "safe", "source": "hiker_response"])
    }

    func sendSOSForCheckIn() {
        guard let reason = checkInReason else { return }
        checkInReason = nil
        checkInPromptedAt = nil
        _ = recordEmergency(whatHappened: "Hiker requested help after \(reason) check-in",
                            injuries: "unknown", people: 1, canWalk: false,
                            coordinate: liveCoordinate, locationSource: liveCoordinate == nil ? "unavailable" : "live_gps")
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
