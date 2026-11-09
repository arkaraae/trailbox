import SwiftUI

struct ConnectivityView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var guardianURL = ""
    @State private var guardianToken = ""
    @State private var joinCode = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nearby incident handoff") {
                    Text("After SOS, the injured phone shows an incident code. Enter that code on the helper's phone to pair. Only this incident's SOS and voice events cross the encrypted link.")
                        .font(.caption)
                    if model.activeIncidentID == model.tripID {
                        Text("Your incident code: \(model.tripID)")
                            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        ShareLink(item: model.tripID) { Label("Share incident code", systemImage: "square.and.arrow.up") }
                    }
                    TextField("Injured hiker's incident code", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                    Button("Pair with incident") { model.helpIncident(code: joinCode) }
                        .disabled(joinCode.isEmpty)
                    if let relay = model.relay { RelayStatusView(relay: relay) }
                }
                Section("Cloud Guardian") {
                    Text("Events upload only after you configure an endpoint. Your Guardian token stays in this iPhone's Keychain. Medical details are included only in a recorded SOS event.")
                        .font(.caption)
                    TextField("https://your-guardian.example", text: $guardianURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                    SecureField("Ingest token", text: $guardianToken)
                    Button("Save and sync") {
                        saved = model.configureGuardian(url: guardianURL, token: guardianToken)
                    }
                    .disabled(guardianURL.isEmpty || guardianToken.isEmpty)
                    Button("Retry upload") { Task { await model.syncCloud() } }
                    Text(model.cloudStatus).font(.caption).foregroundStyle(.secondary)
                    if saved { Text("Guardian configuration saved").foregroundStyle(.green) }
                }
            }
            .navigationTitle("Agent connections")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { guardianURL = UserDefaults.standard.string(forKey: "trailbox.guardianURL") ?? "" }
        }
    }
}

private struct RelayStatusView: View {
    @ObservedObject var relay: EdgeRelayService

    var body: some View {
        Text(relay.status).font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Enable relay") { relay.start() }
            Spacer()
            Button("Stop") { relay.stop() }
        }
    }
}
