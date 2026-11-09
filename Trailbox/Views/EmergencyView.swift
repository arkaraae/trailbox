import SwiftUI
import CoreLocation

struct EmergencyView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var agent: LiquidTrailAgent
    @StateObject private var location = EmergencyLocation()
    @State private var whatHappened = ""
    @State private var injuries = ""
    @State private var people = 1
    @State private var canWalk = true
    @State private var manualLatitude = ""
    @State private var manualLongitude = ""
    @State private var saved = false

    private var manualCoordinate: CLLocationCoordinate2D? {
        guard let lat = Double(manualLatitude), let lon = Double(manualLongitude),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("SOS records immediately. A configured Guardian can forward it, but this does not contact emergency services directly.")
                        .foregroundStyle(.orange)
                }
                Section("What happened") {
                    TextField("Describe what happened", text: $whatHappened, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Injuries or symptoms", text: $injuries, axis: .vertical)
                        .lineLimit(2...4)
                    Stepper("People affected: \(people)", value: $people, in: 1...20)
                    Toggle("Able to walk", isOn: $canWalk)
                }
                Section("Location") {
                    Text(location.status).font(.caption)
                    Button("Refresh current GPS") { location.requestCurrentLocation() }
                    TextField("Latitude if GPS unavailable", text: $manualLatitude)
                        .keyboardType(.decimalPad)
                    TextField("Longitude if GPS unavailable", text: $manualLongitude)
                        .keyboardType(.decimalPad)
                    if let point = model.currentPoint {
                        Text(String(format: "Replay point (demo only): %.5f, %.5f", point.latitude, point.longitude))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Liquid AI emergency intake") {
                    Text(agent.status).font(.caption)
                    if !agent.isReady {
                        Button("Prepare offline model (696 MB)") { agent.downloadModel() }
                            .disabled(agent.isBusy)
                    }
                    if !agent.answer.isEmpty { Text(agent.answer).textSelection(.enabled) }
                    Text("Liquid summarizes saved facts; it does not decide whether SOS is recorded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(saved ? "SOS recorded" : "Record SOS") { saveEmergency() }
                        .foregroundStyle(.red)
                        .disabled(saved || whatHappened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("trailbox.recordSOS")
                }
            }
            .navigationTitle("Emergency record")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { location.requestCurrentLocation() }
        }
    }

    private func saveEmergency() {
        let coordinate = location.coordinate ?? manualCoordinate
        let source = location.coordinate != nil ? "gps" : (manualCoordinate != nil ? "manual" : "unavailable")
        guard model.recordEmergency(whatHappened: whatHappened, injuries: injuries,
                                    people: people, canWalk: canWalk,
                                    coordinate: coordinate, locationSource: source) else { return }
        saved = true
        if agent.isReady {
            agent.summarizeEmergency(events: model.events) { summary in
                model.recordAgentNote(question: "Emergency responder summary", answer: summary)
            }
        }
    }
}
