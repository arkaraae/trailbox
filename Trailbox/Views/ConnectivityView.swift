import SwiftUI

struct ConnectivityView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var guardianURL = ""
    @State private var guardianToken = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Guardian server") {
                    Text("Enter the Guardian endpoint and its ingest token. Claude and email keys stay on the server.")
                        .font(.caption)
                    TextField("https://guardian.example", text: $guardianURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                    SecureField("Ingest token", text: $guardianToken)
                    Button("Save and sync") {
                        saved = model.configureGuardian(url: guardianURL, token: guardianToken)
                    }
                    .disabled(guardianURL.isEmpty || guardianToken.isEmpty)
                    Text(model.cloudStatus).font(.caption).foregroundStyle(.secondary)
                    if saved { Text("Guardian connection saved").foregroundStyle(.green) }
                }
            }
            .navigationTitle("Connect Guardian")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { guardianURL = UserDefaults.standard.string(forKey: "trailbox.guardianURL") ?? "" }
        }
    }
}
