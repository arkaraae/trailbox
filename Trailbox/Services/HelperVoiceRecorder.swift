import Foundation
import AVFoundation
import Speech

/// Records a short AAC voice note and requests on-device transcription when supported.
@MainActor
final class HelperVoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "Ready to record the injured person's voice"
    @Published private(set) var audioBase64 = ""
    @Published private(set) var transcript = ""
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var continuation: CheckedContinuation<String, Never>?

    func start() async {
        let allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { status = "Microphone permission denied"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                            options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                           AVSampleRateKey: 16_000,
                                           AVNumberOfChannelsKey: 1,
                                           AVEncoderBitRateKey: 24_000]
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recordingURL = url
            guard recorder?.record(forDuration: 30) == true else {
                status = "Voice recording could not start"
                return
            }
            isRecording = true
            status = "Recording (30 second maximum)"
        } catch { status = "Microphone: \(error.localizedDescription)" }
    }

    func stop() async {
        guard isRecording, let url = recordingURL else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        isProcessing = true
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 500_000 else { status = "Voice clip is too large"; isProcessing = false; return }
            audioBase64 = data.base64EncodedString()
            status = "Voice saved; transcribing on device…"
            transcript = await transcribe(url)
            status = transcript.isEmpty ? "Voice saved. Add a text summary if transcription is unavailable." : "Voice saved and transcribed"
        } catch { status = "Voice file: \(error.localizedDescription)" }
        isProcessing = false
    }

    private func transcribe(_ url: URL) async -> String {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { return "" }
        speechRecognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result, result.isFinal {
                        self.finishTranscription(result.bestTranscription.formattedString)
                    } else if error != nil {
                        self.finishTranscription("")
                    }
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishTranscription("")
            }
        }
    }

    private func finishTranscription(_ value: String) {
        guard let continuation else { return }
        self.continuation = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        speechRecognizer = nil
        continuation.resume(returning: value)
    }
}

/// Plays the AAC bytes saved in an append-only voice event; no network is needed.
@MainActor
final class OfflineVoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    @Published private(set) var status = ""
    private var player: AVAudioPlayer?

    func toggle(_ note: TrailEvent) {
        if playingID == note.id {
            player?.stop()
            player = nil
            playingID = nil
            status = "Stopped"
            return
        }
        guard let encoded = note.payload["audio_m4a_base64"],
              let data = Data(base64Encoded: encoded) else {
            status = "Voice clip unavailable"
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            guard player?.play() == true else { status = "Could not play voice clip"; return }
            playingID = note.id
            status = "Playing voice clip"
        } catch { status = "Playback: \(error.localizedDescription)" }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playingID = nil
            self.status = flag ? "Finished" : "Playback stopped"
        }
    }
}
