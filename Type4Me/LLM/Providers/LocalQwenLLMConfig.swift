import Foundation

/// Config for the bundled local Qwen model running inside SenseVoice server.
/// No credentials needed — base URL comes from the server's dynamic port.
struct LocalQwenLLMConfig: LLMProviderConfig, Sendable {

    static var provider: LLMProvider { .localQwen }

    static var credentialFields: [CredentialField] { [] }

    init?(credentials: [String: String]) {
        // Always valid — no credentials required
    }

    func toCredentials() -> [String: String] { [:] }

    func toLLMConfig() -> LLMConfig {
        // Actual base URL is resolved dynamically in KeychainService.loadLLMConfig()
        let name = Self.availableModel?.name ?? "qwen3-4b"
        return LLMConfig(apiKey: "", model: name, baseURL: "")
    }

    // MARK: - Model Discovery

    /// Available local LLM models, ordered by preference (best first).
    static let knownModels: [LocalLLMModel] = [
        LocalLLMModel(
            name: "qwen3.5-9b",
            displayName: "Qwen3.5-9B",
            bundleFile: "qwen3.5-9b-q4_k_m.gguf",
            devFile: "Qwen3.5-9B-Q4_K_M.gguf",
            sizeGB: 5.3,
            minRAMGB: 16,
            tokPerSec: "~45-90"
        ),
        LocalLLMModel(
            name: "qwen3-4b",
            displayName: "Qwen3-4B",
            bundleFile: "qwen3-4b-q4_k_m.gguf",
            devFile: "qwen3-4b-q4_k_m.gguf",
            sizeGB: 2.3,
            minRAMGB: 8,
            tokPerSec: "~60-120"
        ),
    ]

    /// The best available model (prefers 9B, falls back to 4B).
    static var availableModel: LocalLLMModel? {
        knownModels.first { $0.path != nil }
    }

    /// Check if any GGUF model file exists.
    static var isModelAvailable: Bool {
        availableModel != nil
    }

    /// Path to the best available model.
    static var modelPath: String? {
        availableModel?.path
    }
}

// MARK: - Local LLM Model Descriptor

struct LocalLLMModel: Sendable {
    let name: String
    let displayName: String
    let bundleFile: String
    let devFile: String
    let sizeGB: Double
    let minRAMGB: Int
    let tokPerSec: String

    /// Resolved path: checks bundle first, then dev location.
    var path: String? {
        // 1. App bundle: Contents/Resources/Models/<bundleFile>
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent(bundleFile),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        // 2. Dev mode: ~/projects/type4me/sensevoice-server/models/<devFile>
        let home = NSHomeDirectory()
        let devPath = (home as NSString)
            .appendingPathComponent("projects/type4me/sensevoice-server/models/\(devFile)")
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }
}
