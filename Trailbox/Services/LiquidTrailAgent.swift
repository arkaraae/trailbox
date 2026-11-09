import Foundation
import CryptoKit
import Combine
import llama

/// Liquid inference reads the local event log. It never changes safety state or sends data off device.
@MainActor
final class LiquidTrailAgent: ObservableObject {
    @Published private(set) var status = "Model not downloaded"
    @Published private(set) var answer = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false

    private static let modelName = "LFM2.5-1.2B-Instruct-Q4_0.gguf"
    private static let modelURL = URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/LFM2.5-1.2B-Instruct-Q4_0.gguf")!
    private static let expectedSize: Int64 = 695_751_488
    private static let expectedSHA256 = "2ea801949d760cdf1a2cc04a54262c22c3c0c54f0769d57760c9adeb0e59233f"
    private let engine = LiquidInferenceEngine()

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trailbox/Models", isDirectory: true)
            .appendingPathComponent(Self.modelName)
    }

    init() {
        let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        isReady = size.map(Int64.init) == Self.expectedSize
        status = isReady ? "Liquid model available offline" : "Liquid model not downloaded"
    }

    func downloadModel() {
        guard !isBusy else { return }
        isBusy = true
        status = "Downloading Liquid model (696 MB)…"
        Task {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: Self.modelURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw LiquidAgentError.downloadFailed
                }
                status = "Verifying model…"
                let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
                guard size == Self.expectedSize else { throw LiquidAgentError.invalidModel }
                let digest = try Self.sha256(temporaryURL)
                guard digest == Self.expectedSHA256 else { throw LiquidAgentError.invalidModel }
                let destination = fileURL
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                isReady = true
                status = "Liquid model available offline"
            } catch {
                status = "Model download failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    func summarizeEmergency(events: [TrailEvent], onComplete: @escaping (String) -> Void) {
        guard isReady, !isBusy, events.last(where: { $0.type == .sos }) != nil else { return }
        isBusy = true
        answer = ""
        status = "Liquid is summarizing the emergency locally…"
        let context = Self.eventContext(events.filter { $0.type != .agentNote })
        let path = fileURL.path
        Task {
            do {
                let result = try await engine.generate(modelPath: path, context: context) { [weak self] chunk in
                    Task { @MainActor [weak self] in self?.answer += chunk }
                }
                answer = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { throw LiquidAgentError.inferenceFailed }
                status = "Emergency note saved on this iPhone"
                onComplete(answer)
            } catch {
                status = "Emergency facts remain saved. Liquid summary failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private static func eventContext(_ events: [TrailEvent]) -> String {
        let formatter = ISO8601DateFormatter()
        let lines = events.suffix(12).map { event in
            let payload = event.payload.keys.sorted().map { key in
                "\(key)=\(String((event.payload[key] ?? "").prefix(120)))"
            }.joined(separator: ", ")
            return "\(formatter.string(from: event.recordedAt)) \(event.type.rawValue): \(payload)"
        }
        return lines.isEmpty ? "No trip events recorded yet." : lines.joined(separator: "\n")
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum LiquidAgentError: LocalizedError {
    case downloadFailed, invalidModel, loadFailed, contextFailed, inferenceFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "The model server did not return a download."
        case .invalidModel: return "The model file failed size or checksum verification."
        case .loadFailed: return "The Liquid model could not be loaded."
        case .contextFailed: return "The inference context could not be created."
        case .inferenceFailed: return "The model stopped while generating."
        }
    }
}

/// Actor isolation keeps the native inference context on one executor across questions.
private actor LiquidInferenceEngine {
    private var runner: LFMRunner?

    func generate(modelPath: String, context: String,
                  onText: @escaping (String) -> Void) throws -> String {
        if runner == nil { runner = try LFMRunner(modelPath: modelPath) }
        var output = ""
        let system = """
        You are Trailbox's on-device emergency intake assistant. Summarize only the recorded facts.
        Include what happened, injuries, number of people, mobility, and location with its source.
        If a fact is missing, say unknown. Do not diagnose, invent details, give treatment advice,
        or claim rescue dispatch or event delivery. Safety decisions are deterministic code.
        """
        let prompt = "Local emergency and recent trail events:\n\(context)\n\nWrite a concise factual responder note."
        do {
            try runner!.generate(system: system, user: prompt, maxTokens: 200) { chunk in
                output += chunk
                onText(chunk)
            }
        } catch {
            runner = nil
            throw error
        }
        return output
    }
}

/// Native llama.cpp C API runner for Liquid's LFM2.5 GGUF.
private final class LFMRunner {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>

    init(modelPath: String) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99
        #endif
        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            llama_backend_free()
            throw LiquidAgentError.loadFailed
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = 256
        contextParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        contextParams.n_threads_batch = contextParams.n_threads
        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LiquidAgentError.contextFailed
        }
        guard let loadedVocab = llama_model_get_vocab(loadedModel),
              let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            llama_backend_free()
            throw LiquidAgentError.contextFailed
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(50))
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            llama_vocab_n_tokens(loadedVocab), 64, 1.05, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.max))
        model = loadedModel
        context = loadedContext
        vocab = loadedVocab
        sampler = chain
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    func generate(system: String, user: String, maxTokens: Int,
                  onText: (String) -> Void) throws {
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
        let prompt = """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant

        """
        var tokens = tokenize(prompt)
        guard !tokens.isEmpty else { throw LiquidAgentError.inferenceFailed }
        var pending: [UInt8] = []
        var result = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        for _ in 0..<maxTokens {
            guard result == 0 else { throw LiquidAgentError.inferenceFailed }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            pending += piece(token)
            if let text = String(bytes: pending, encoding: .utf8) {
                onText(text)
                pending.removeAll()
            }
            result = withUnsafeMutablePointer(to: &token) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
        }
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(count) + 2)
        let used = llama_tokenize(vocab, text, count, &tokens, Int32(tokens.count), true, true)
        return used > 0 ? Array(tokens.prefix(Int(used))) : []
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var bytes = [CChar](repeating: 0, count: 256)
        let length = llama_token_to_piece(vocab, token, &bytes, Int32(bytes.count), 0, false)
        return length > 0 ? bytes.prefix(Int(length)).map { UInt8(bitPattern: $0) } : []
    }
}
