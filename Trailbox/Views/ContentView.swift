import SwiftUI
import MapKit
import UniformTypeIdentifiers

private enum TrailColors {
    static let background = Color(red: 0.07, green: 0.085, blue: 0.08)
    static let card = Color(red: 0.14, green: 0.16, blue: 0.15)
    static let green = Color(red: 0.58, green: 0.92, blue: 0.43)
    static let orange = Color(red: 1, green: 0.67, blue: 0.32)
}

struct ContentView: View {
    @EnvironmentObject private var model: TrailboxViewModel

    var body: some View {
        TabView {
            HikeScreen()
                .tabItem { Label("Hike", systemImage: "figure.hiking") }
            HelpScreen()
                .tabItem { Label("Nearby", systemImage: "person.2.wave.2") }
            ReportScreen()
                .tabItem { Label("Report", systemImage: "doc.text") }
        }
        .tint(TrailColors.green)
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(get: { model.checkInReason != nil }, set: { _ in })) {
            CheckInView().environmentObject(model).interactiveDismissDisabled()
        }
        .alert("Trailbox", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } })) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: { Text(model.errorMessage ?? "Unknown error") }
    }
}

private struct HikeScreen: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @State private var showPlan = false
    @State private var showEmergency = false
    @State private var showImporter = false
    @State private var showControls = false

    var body: some View {
        ZStack {
            routeMap
            VStack(spacing: 0) {
                HStack {
                    Text("Route replay")
                        .font(.title3.bold())
                    Spacer()
                    Button("Plan") { showPlan = true }
                    Button("GPX") { showImporter = true }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 14).padding(.top, 8)
                Spacer()
                replayPanel
            }
        }
        .background(TrailColors.background)
        .sheet(isPresented: $showPlan) { TripPlanView().environmentObject(model) }
        .sheet(isPresented: $showEmergency) { EmergencyView(agent: model.liquidAgent).environmentObject(model) }
        .sheet(isPresented: $showControls) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) { hikeControls; demoControls }
                        .padding(16)
                }
                .background(TrailColors.background)
                .navigationTitle("Hike controls")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showControls = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.importRoute(url) }
        }
    }

    private var replayPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(model.importedRouteName ?? "Demo route")
                    .font(.headline).lineLimit(1)
                Spacer()
                Text("\(model.pointIndex + 1)/\(model.points.count)")
                    .font(.system(.caption, design: .monospaced))
                Text("\(Int(model.elapsedSeconds / 60))m")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button(model.isPlaying ? "Pause" : "Play route") {
                    model.startOrPause()
                }
                .buttonStyle(.borderedProminent).tint(TrailColors.green)
                Button { model.nextPoint() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(.bordered)
                Button { model.resetReplay() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.bordered)
                Menu("\(model.speed)×") {
                    Button("1×") { model.speed = 1 }
                    Button("10×") { model.speed = 10 }
                    Button("60×") { model.speed = 60 }
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Button(model.isLiveTracking ? "Stop hike" : "Start hike") {
                    if model.hasTripPlan {
                        model.isLiveTracking ? model.stopLive() : model.startLive()
                    } else { showPlan = true }
                }
                .buttonStyle(.borderedProminent).tint(TrailColors.green)
                Button("SOS") { showEmergency = true }
                    .buttonStyle(.borderedProminent).tint(.red)
                Button("Demo") { showControls = true }
                    .buttonStyle(.bordered)
            }
            if model.reportSOS != nil { Text("Nearby help alert active").font(.caption).foregroundStyle(TrailColors.orange) }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var hikeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your hike", systemImage: "map")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(model.hasTripPlan ? "PLAN SAVED" : "SETUP NEEDED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.hasTripPlan ? TrailColors.green : TrailColors.orange)
            }
            if model.hasTripPlan {
                Text("\(model.groupName) · Return \(model.expectedReturn.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.72))
            } else {
                Text("Add a return time and emergency contact to start.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.72))
            }
            Button(model.hasTripPlan ? "Edit trip plan" : "Set up hike") { showPlan = true }
                .buttonStyle(TrailActionStyle())
            Button(model.isLiveTracking ? "Stop hike" : "Start hike") {
                if model.hasTripPlan {
                    model.isLiveTracking ? model.stopLive() : model.startLive()
                } else { showPlan = true }
            }
            .buttonStyle(TrailActionStyle(primary: true))
            .accessibilityIdentifier("trailbox.startHike")
            Text(model.liveStatus)
                .font(.caption).foregroundStyle(.white.opacity(0.53))
        }
        .trailCard()
    }

    private var demoControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("TRY A CHECK-IN")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text("INDOORS").font(.system(size: 9, weight: .bold)).foregroundStyle(TrailColors.orange)
            }
            Text("Start the hike, then choose one trigger. The same rule opens the check-in used on trail.")
                .font(.caption).foregroundStyle(.white.opacity(0.62))
            HStack(spacing: 8) {
                demoButton("Fall", icon: "figure.fall") { model.simulateFallCheckIn() }
                demoButton("Off trail", icon: "point.topleft.down.curvedto.point.bottomright.up") { model.simulateOffRouteCheckIn() }
                demoButton("Still", icon: "figure.stand") { model.simulateStillnessCheckIn() }
            }
            .disabled(!model.isLiveTracking)
            Button { showEmergency = true } label: {
                Label("Record SOS now", systemImage: "sos.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(TrailActionStyle(danger: true))
            if model.activeIncidentID == model.tripID, model.reportSOS != nil {
                Text("Nearby help alert active")
                    .font(.caption.bold()).foregroundStyle(TrailColors.orange)
            }
        }
        .trailCard()
    }

    private func demoButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 56)
        }
        .buttonStyle(TrailActionStyle())
    }

    private var routeMap: some View {
        Map(position: $model.cameraPosition) {
            if model.route.count > 1 {
                MapPolyline(coordinates: model.route).stroke(TrailColors.green, lineWidth: 5)
            }
            if let location = model.liveCoordinate, model.isLiveTracking {
                Annotation("You", coordinate: location) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.black).padding(10).background(TrailColors.green, in: Circle())
                }
            } else if let point = model.currentPoint {
                Annotation("Replay", coordinate: point.coordinate) {
                    Image(systemName: "figure.hiking")
                        .foregroundStyle(.black).padding(10).background(TrailColors.green, in: Circle())
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea(edges: .top)
        .accessibilityIdentifier("trailbox.map")
    }

}

private struct HelpScreen: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @StateObject private var voicePlayer = OfflineVoicePlayer()
    @State private var showOfflineNote = false
    @State private var voiceIncident: TrailEvent?

    var body: some View {
        ZStack {
            TrailColors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    screenTitle("Nearby help", subtitle: "Record what the injured hiker says")
                    pairingCard
                    incidentCard
                    offlineNotesCard
                }
                .padding(18).padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showOfflineNote) { HelperVoiceView(incident: nil).environmentObject(model) }
        .sheet(item: $voiceIncident) { HelperVoiceView(incident: $0).environmentObject(model) }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("NEARBY IPHONES")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("Trailbox looks for other iPhones automatically. After SOS, it sends a small help alert without medical details or exact GPS.")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 7) {
                Circle().fill(model.connectedPeers > 0 ? TrailColors.green : TrailColors.orange)
                    .frame(width: 7, height: 7)
                Text(model.edgeStatus).font(.subheadline)
            }
            Text("\(model.connectedPeers) nearby iPhone(s) connected")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
        }
        .trailCard()
    }

    private var incidentCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("RECEIVED INCIDENT")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            if let incident = model.nearbyIncidents.last {
                Text(incident.payload["what_happened"] ?? "Help requested")
                    .font(.title3.bold())
                if let lat = incident.payload["latitude"], let lon = incident.payload["longitude"] {
                    Text("Last position: \(lat), \(lon)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                }
                Button("Record their voice") { voiceIncident = incident }
                    .buttonStyle(TrailActionStyle(primary: true))
                    .accessibilityIdentifier("trailbox.recordVoice")
            } else {
                Text("Waiting for a nearby help alert.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.62))
            }
        }
        .trailCard()
    }

    private var offlineNotesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OFFLINE VOICE NOTES")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("Record now, even without a connection. The note stays on this iPhone until a nearby help alert arrives.")
                .font(.caption).foregroundStyle(.white.opacity(0.62))
            Button("Record an offline note") { showOfflineNote = true }
                .buttonStyle(TrailActionStyle())
            ForEach(model.offlineVoiceNotes.reversed()) { note in
                VStack(alignment: .leading, spacing: 7) {
                    Text(note.payload["transcript"] ?? "Voice note")
                        .font(.subheadline).lineLimit(3)
                    HStack {
                        Text(note.recordedAt, style: .time)
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button(voicePlayer.playingID == note.id ? "Stop" : "Play voice") {
                            voicePlayer.toggle(note)
                        }
                        .font(.caption.bold())
                    }
                    if let incident = model.nearbyIncidents.last {
                        let attached = model.events.contains {
                            $0.tripID == incident.tripID && $0.payload["source_note_id"] == note.id
                        }
                        Button(attached ? "Attached to incident" : "Attach to this incident") {
                            _ = model.attachOfflineVoice(note: note, to: incident.tripID)
                        }
                        .font(.caption.bold())
                        .disabled(attached)
                    }
                }
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .trailCard()
    }
}

private struct ReportScreen: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @StateObject private var voicePlayer = OfflineVoicePlayer()
    @State private var showGuardianSetup = false
    @State private var showEvents = false

    var body: some View {
        ZStack {
            TrailColors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    screenTitle("Rescuer report", subtitle: "What we know, and what was sent")
                    incidentFacts
                    LiquidAgentCard(agent: model.liquidAgent)
                    guardianCard
                    eventCard
                }
                .padding(18).padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showGuardianSetup) { ConnectivityView().environmentObject(model) }
        .sheet(isPresented: $showEvents) { eventSheet }
    }

    private var incidentFacts: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("INCIDENT FACTS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text("ON THIS IPHONE").font(.system(size: 9, weight: .bold)).foregroundStyle(TrailColors.green)
            }
            if let sos = model.reportSOS {
                if sos.payload["demo"] == "true" {
                    Text("DEMO INCIDENT · GPX position may be simulated")
                        .font(.caption.bold()).foregroundStyle(TrailColors.orange)
                }
                fact("What happened", sos.payload["what_happened"] ?? "Unknown")
                fact("Location", location(for: sos))
                fact("Injuries", sos.payload["injuries"] ?? "Unknown")
                if let voice = model.reportVoice {
                    fact("Helper's voice note", voice.payload["transcript"] ?? "No reviewed text")
                    Button(voicePlayer.playingID == voice.id ? "Stop voice" : "Play voice note") {
                        voicePlayer.toggle(voice)
                    }
                    .font(.subheadline.bold())
                } else {
                    Text("Waiting for a nearby helper's voice note")
                        .font(.caption).foregroundStyle(.white.opacity(0.56))
                }
            } else {
                Text("No SOS yet. Start a hike and use a demo trigger to show the full handoff.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.62))
            }
        }
        .trailCard()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }

    private func location(for sos: TrailEvent) -> String {
        guard let lat = sos.payload["latitude"], let lon = sos.payload["longitude"] else { return "Unavailable" }
        return "\(lat), \(lon) · \(sos.payload["location_source"] ?? "unknown source")"
    }

    private var guardianCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("REPORT DELIVERY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Circle().fill(model.cloudStatus.hasPrefix("Synced") ? .cyan : .gray)
                    .frame(width: 7, height: 7)
            }
            Text(model.cloudStatus).font(.caption).foregroundStyle(.white.opacity(0.67))
            Button("Connect report service") { showGuardianSetup = true }
                .buttonStyle(TrailActionStyle())
            Button("Send incident") { Task { await model.syncCloud() } }
                .buttonStyle(TrailActionStyle(primary: true))
            if model.reportSOS != nil {
                Button("Get rescuer report") { Task { await model.refreshGuardianReport() } }
                    .font(.subheadline.bold())
                Text(model.guardianReportStatus)
                    .font(.caption).foregroundStyle(.white.opacity(0.58))
            }
            if !model.guardianReport.isEmpty {
                Text(model.guardianReport)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Your incident facts stay available offline. The server sends the final report when connected.")
                .font(.caption2).foregroundStyle(.white.opacity(0.48))
        }
        .trailCard()
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("EVENT HISTORY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("\(model.events.count) saved events · \(model.pendingCount) queued for sync")
                .font(.subheadline).foregroundStyle(.white.opacity(0.65))
            Button("View event log") { showEvents = true }
                .buttonStyle(TrailActionStyle())
        }
        .trailCard()
    }

    private var eventSheet: some View {
        NavigationStack {
            List(model.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(event.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline.bold())
                        Spacer()
                        Text(event.recordedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    if event.type == .injuryVoice {
                        Text(event.payload["transcript"] ?? "Voice clip recorded")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let message = event.payload["message"] ?? event.payload["what_happened"] {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(event.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Event log")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showEvents = false } } }
        }
    }
}

private struct LiquidAgentCard: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @ObservedObject var agent: LiquidTrailAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIQUID · ON THIS IPHONE")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(agent.status).font(.subheadline)
            if !agent.isReady {
                Button("Prepare offline model (696 MB)") { agent.downloadModel() }
                    .buttonStyle(TrailActionStyle())
                    .disabled(agent.isBusy)
            }
            if let note = model.events.last(where: {
                $0.tripID == model.tripID && $0.type == .agentNote &&
                $0.payload["question"] == "Emergency responder summary"
            }) {
                Text(note.payload["answer"] ?? "")
                    .font(.subheadline).textSelection(.enabled)
            } else if model.reportSOS != nil {
                Text(agent.isBusy ? "Summarizing saved SOS facts…" :
                     "SOS saved. A local summary requires the downloaded model.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Runs only after SOS. Safety checks use fixed rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .trailCard()
    }
}

private func screenTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
        Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.58))
    }
}

private struct TrailActionStyle: ButtonStyle {
    var primary = false
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 45)
            .foregroundStyle(primary ? Color.black : (danger ? Color.white : TrailColors.green))
            .background(primary ? TrailColors.green : (danger ? Color.red.opacity(0.82) : Color.white.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension View {
    func trailCard() -> some View {
        padding(16)
            .background(TrailColors.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
    }
}
