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
                Section("Nearby iPhone relay") {
                    Text("Share this trip code with the second iPhone. Both phones must use the same code and enable nearby relay.")
                        .font(.caption)
                    Text(model.tripID).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    ShareLink(item: model.tripID) { Label("Share trip code", systemImage: "square.and.arrow.up") }
                    TextField("Join another trip code", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                    Button("Join trip") { model.joinTrip(code: joinCode) }
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
