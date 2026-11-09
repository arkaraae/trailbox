import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @State private var showEvents = false
    @State private var showEmergency = false
    @State private var showTripPlan = false
    @State private var showConnectivity = false
    @StateObject private var agent = LiquidTrailAgent()

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusStrip
                    TripStatusCard(model: model)
                    tripPlanCard
                    connectionCard
                    emergencyCard
                    mapCard
                    replayCard
                    simulatorCard
                    eventCard
                    safetyNote
                }
                .padding(18)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showEvents) { eventSheet }
        .sheet(isPresented: $showEmergency) { EmergencyView(agent: agent).environmentObject(model) }
        .sheet(isPresented: $showTripPlan) { TripPlanView().environmentObject(model) }
        .sheet(isPresented: $showConnectivity) { ConnectivityView().environmentObject(model) }
        .alert("Trailbox error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } })) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: {
                Text(model.errorMessage ?? "Unknown error")
            }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "mountain.2.fill").foregroundStyle(.mint)
                    Text("TRAILBOX").font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(1.5)
                }
                Text("YOUR HIKE. YOUR BLACK BOX.")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Label("DEMO", systemImage: "play.rectangle.fill")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(.mint)
                .background(.mint.opacity(0.13), in: Capsule())
        }
        .accessibilityIdentifier("trailbox.header")
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            tier("ON-DEVICE", color: .mint, active: true)
            tier("EDGE", color: .orange, active: model.edgeConnected)
            tier("CLOUD", color: .cyan, active: model.cloudStatus.hasPrefix("Synced"))
            Spacer(minLength: 2)
            Image(systemName: model.forcedOffline ? "wifi.slash" : "wifi")
                .foregroundStyle(model.forcedOffline ? .orange : .mint)
            Text("\(model.pendingCount) PENDING")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
    }

    private func tier(_ name: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(active ? color : Color.gray).frame(width: 5, height: 5)
            Text(name).font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(active ? color : .white.opacity(0.4))
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color.white.opacity(0.065), in: Capsule())
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ROUTE REPLAY", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text("\(model.pointIndex + (model.points.isEmpty ? 0 : 1))/\(model.points.count) WAYPOINTS")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.mint)
            }
            Map(position: $model.cameraPosition) {
                if model.route.count >= 2 {
                    MapPolyline(coordinates: model.route)
                        .stroke(.mint.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                if let signal = model.lastSignalCoordinate {
                    Annotation("Last signal", coordinate: signal) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.white).padding(8).background(.blue, in: Circle())
                    }
                }
                if let current = model.currentPoint {
                    Annotation("Hiker", coordinate: current.coordinate) {
                        Image(systemName: "figure.hiking")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(10)
                            .background(.mint, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 5)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .frame(height: 290)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("trailbox.map")
            HStack(spacing: 8) {
                Image(systemName: "location.fill").foregroundStyle(.mint)
                Text(coordinateLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(model.lastSignalDistanceMeters.map { "SIGNAL \($0) M BACK" } ?? "GPX • INDOOR MODE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .cardStyle()
    }

    private var coordinateLabel: String {
        guard let point = model.currentPoint else { return "No GPS replay data" }
        return String(format: "%.5f, %.5f", point.latitude, point.longitude)
    }

    private var replayCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("SIMULATED HIKE").font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text(model.simulatedTime, format: .dateTime.hour().minute())
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.mint)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(durationLabel)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("SIM ELAPSED").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text(model.isPlaying ? "● RECORDING" : "● PAUSED")
                    .foregroundStyle(model.isPlaying ? .mint : .orange)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            ProgressView(value: Double(model.pointIndex), total: Double(max(1, model.points.count - 1)))
                .tint(.mint)
            HStack(spacing: 10) {
                Button {
                    model.startOrPause()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Start Hike", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrailButtonStyle(prominent: true))
                .disabled(model.isFinished || !model.hasTripPlan)
                .accessibilityIdentifier("trailbox.startPause")

                Button { model.nextPoint() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 48)
                }
                .buttonStyle(TrailButtonStyle(prominent: false))
                .disabled(model.isFinished)
                .accessibilityLabel("Next waypoint")
                .accessibilityIdentifier("trailbox.nextPoint")

                Button { model.resetReplay() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 48)
                }
                .buttonStyle(TrailButtonStyle(prominent: false))
                .accessibilityLabel("Reset replay")
            }
            HStack {
                Text("REPLAY SPEED").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Picker("Replay speed", selection: $model.speed) {
                    Text("1×").tag(1)
                    Text("10×").tag(10)
                    Text("60×").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
        }
        .cardStyle()
    }

    private var durationLabel: String {
        let total = Int(model.elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var simulatorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("SCENARIO CONTROLS", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text("LOCAL ONLY").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            }
            Toggle("Force simulated offline", isOn: $model.forcedOffline).tint(.mint)
            Divider().overlay(.white.opacity(0.1))
            Toggle("Fake barometer drop", isOn: $model.fakeStorm).tint(.orange)
                .onChange(of: model.fakeStorm) { _, _ in model.evaluateDemoSafety() }
            Divider().overlay(.white.opacity(0.1))
            Toggle("Fake low battery", isOn: $model.fakeLowBattery).tint(.orange)
                .onChange(of: model.fakeLowBattery) { _, _ in model.evaluateDemoSafety() }
            Divider().overlay(.white.opacity(0.1))
            HStack {
                Text("Heart rate")
                Spacer()
                Text("\(Int(model.heartRate)) BPM").foregroundStyle(.mint).monospacedDigit()
            }
            Slider(value: $model.heartRate, in: 45...180, step: 1).tint(.mint)
            Button { model.logVitals() } label: {
                Label("Log simulated vitals", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrailButtonStyle(prominent: false))
            Text("Scenario toggles affect deterministic demo alerts.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
        }
        .cardStyle()
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("BLACK BOX", systemImage: "externaldrive.fill")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text("SQLITE • ON DEVICE").font(.system(size: 9, weight: .bold)).foregroundStyle(.mint)
            }
            HStack(spacing: 12) {
                metric("\(model.events.count)", "EVENTS STORED")
                metric("\(model.pendingCount)", "PENDING SYNC")
                metric("\(Set(model.events.map(\.type)).count)", "EVENT TYPES")
            }
            Button { showEvents = true } label: {
                HStack {
                    Text("Inspect event log")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
            }
            .buttonStyle(TrailButtonStyle(prominent: false))
            Button { model.checkIn() } label: {
                Label("Record demo check-in", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrailButtonStyle(prominent: false))
            .accessibilityIdentifier("trailbox.checkIn")
        }
        .cardStyle()
    }

    private var tripPlanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TRIP PLAN", systemImage: "list.clipboard")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text(model.hasTripPlan ? "SAVED" : "SET UP")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.mint)
            }
            Text(model.hasTripPlan ? "\(model.groupName) · Return \(model.expectedReturn.formatted(date: .omitted, time: .shortened))" : "Add a return time and emergency contact before starting.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Button { showTripPlan = true } label: {
                Label(model.hasTripPlan ? "Edit trip plan" : "Plan hike", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrailButtonStyle(prominent: false))
            .accessibilityIdentifier("trailbox.tripPlan")
        }
        .cardStyle()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AGENT HANDOFFS", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text("Nearby: \(model.edgeStatus)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            Text("Guardian: \(model.cloudStatus)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            Button { showConnectivity = true } label: {
                Label("Configure edge and cloud", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(TrailButtonStyle(prominent: false))
        }.cardStyle()
    }

    private var emergencyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("EMERGENCY READINESS", systemImage: "cross.case.fill")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text("LOCAL FIRST").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            }
            Text(agent.status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            if !agent.isReady {
                Button { agent.downloadModel() } label: {
                    Label("Prepare Liquid offline (696 MB)", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrailButtonStyle(prominent: false))
                .disabled(agent.isBusy)
                .accessibilityIdentifier("trailbox.downloadLiquid")
            }
            Button { showEmergency = true } label: {
                Label("Record emergency", systemImage: "sos.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrailButtonStyle(prominent: false))
            .accessibilityIdentifier("trailbox.openEmergency")
            Text("SOS saves immediately. Delivery depends on a connected peer or configured Guardian; check handoff status above.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.48))
        }
        .cardStyle()
    }

    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(title).font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("Route replay is a demo. Nearby and Guardian connections require setup and are not a substitute for emergency services.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }.padding(.horizontal, 4).padding(.bottom, 15)
    }

    private var eventSheet: some View {
        NavigationStack {
            List(model.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(event.type.rawValue.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(event.recordedAt, style: .time)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(event.payload.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(event.payload[key] ?? "")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("ID: \(event.id)").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Black Box Events")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showEvents = false } }
            }
        }
    }
}

private struct TrailButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 12).frame(height: 46)
            .background(prominent ? Color.mint : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension View {
    func cardStyle() -> some View {
        self.padding(16)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.09)))
    }
}
