import SwiftUI

struct HelperVoiceView: View {
    @EnvironmentObject private var model: TrailboxViewModel
    @Environment(\.dismiss) private var dismiss
    let incident: TrailEvent?
    @StateObject private var recorder = HelperVoiceRecorder()
    @State private var editedTranscript = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                if let incident {
                    Section("Nearby incident") {
                        Text("Incident ID: \(incident.tripID)")
                            .font(.system(.caption, design: .monospaced))
                        if let lat = incident.payload["latitude"], let lon = incident.payload["longitude"] {
                            Text("Last position: \(lat), \(lon)")
                        }
                        Text(incident.payload["what_happened"] ?? "Help requested")
                    }
                } else {
                    Section("Offline note") {
                        Text("Record now. This note stays on this iPhone until you attach it to a nearby incident.")
                            .font(.caption)
                    }
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
                    Text("The voice clip is saved offline in Trailbox. On-device transcription may be unavailable; review the text before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(saved ? "Saved offline" : (incident == nil ? "Save offline note" : "Save to incident")) {
                        if let incident {
                            saved = model.recordHelperVoice(for: incident.tripID,
                                transcript: editedTranscript, audioBase64: recorder.audioBase64)
                        } else {
                            saved = model.recordOfflineVoice(transcript: editedTranscript,
                                                            audioBase64: recorder.audioBase64)
                        }
                    }
                    .disabled(saved || recorder.audioBase64.isEmpty || recorder.isProcessing ||
                              editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(incident == nil ? "Offline voice note" : "Help nearby hiker")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
