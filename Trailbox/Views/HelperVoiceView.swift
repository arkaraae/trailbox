import SwiftUI

struct HelperVoiceView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @Environment(\.dismiss) private var dismiss
    let incident: TrailEvent
    @StateObject private var recorder = HelperVoiceRecorder()
    @State private var editedTranscript = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nearby hiker incident") {
                    Text("Incident code: \(incident.tripID)")
                        .font(.system(.caption, design: .monospaced))
                    if let lat = incident.payload["latitude"], let lon = incident.payload["longitude"] {
                        Text("Last known location: \(lat), \(lon)")
                    }
                    Text(incident.payload["what_happened"] ?? "Reason unknown")
                }
                Section("Record the injured person's account") {
                    Text("Ask what happened, where they hurt, whether they can walk, and how many people need help. Record only with their consent when possible.")
                        .font(.caption)
                    Text(recorder.status).font(.caption).foregroundStyle(.secondary)
                    Button(recorder.isRecording ? "Stop recording" : "Start voice recording") {
                        if recorder.isRecording {
                            Task { await recorder.stop(); editedTranscript = recorder.transcript }
                        } else { Task { await recorder.start() } }
                    }
                    .disabled(recorder.isProcessing || saved)
                    if recorder.isProcessing { ProgressView("Transcribing") }
                    TextField("Transcript or helper summary", text: $editedTranscript, axis: .vertical)
                        .lineLimit(3...8)
                    Text("The voice clip is saved in the incident event. On-device transcription may be unavailable; review the text before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(saved ? "Saved to incident log" : "Save voice account") {
                        saved = model.recordHelperVoice(for: incident.tripID,
                            transcript: editedTranscript, audioBase64: recorder.audioBase64)
                    }
                    .disabled(saved || recorder.audioBase64.isEmpty || recorder.isProcessing ||
                              editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Help nearby hiker")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
