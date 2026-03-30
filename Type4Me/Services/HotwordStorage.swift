import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Hotword storage with two independent stores:
/// - **Built-in file** (`builtin-hotwords.json`): seeded from defaults, user-editable via Finder for bulk ops
/// - **User file** (`hotwords.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime (deduplicated, case-insensitive).
enum HotwordStorage {

    // MARK: - File paths

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Type4Me")
    }

    /// Built-in hotwords file (seeded from defaults, user-editable for bulk ops)
    static var builtinFileURL: URL { appSupportDir.appendingPathComponent("builtin-hotwords.json") }

    /// User hotwords file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("hotwords.json") }

    // MARK: - Default hotwords (used for initial seeding)

    /// Common tech terms that ASR engines frequently mis-transcribe.
    static let defaultHotwords: [String] = [
        // ── AI models & companies ──
        "Claude", "Claude Code", "GPT", "GPT-4", "GPT-4o", "Gemini", "LLaMA", "Llama",
        "Anthropic", "OpenAI", "DeepSeek", "Qwen", "Mistral", "Cohere", "Perplexity",
        "Midjourney", "Stable Diffusion", "ComfyUI", "Hugging Face", "xAI", "Grok",
        "Copilot", "ChatGPT", "DALL-E", "Whisper", "Sora",

        // ── Dev tools ──
        "GitHub", "GitLab", "VS Code", "Cursor", "Docker", "Kubernetes",
        "Terraform", "Homebrew", "npm", "pip", "Vercel", "Netlify", "Supabase",
        "Firebase", "Redis", "PostgreSQL", "MongoDB", "Elasticsearch", "Grafana",
        "Prometheus", "Nginx", "Ollama", "Pinecone", "ChromaDB", "Weaviate",

        // ── Programming terms ──
        "API", "SDK", "LLM", "ASR", "token", "prompt", "fine-tune", "fine-tuning",
        "embedding", "RAG", "webhook", "microservice", "DevOps", "CI/CD", "GraphQL",
        "WebSocket", "REST", "OAuth", "JWT", "CORS", "SSL", "DNS", "CRUD",
        "refactor", "linting", "boilerplate", "serialization",

        // ── Frameworks & languages ──
        "React", "Next.js", "Vue", "Angular", "SwiftUI", "PyTorch", "TensorFlow",
        "LangChain", "Tailwind", "TypeScript", "JavaScript", "Rust", "Kotlin",
        "Flutter", "Django", "FastAPI", "Express", "Vite", "Nuxt", "SvelteKit",
        "Prisma", "Drizzle",

        // ── Business & work ──
        "deadline", "meeting", "schedule", "feedback", "stakeholder", "milestone",
        "roadmap", "KPI", "OKR", "standup", "sprint", "backlog", "retrospective",
        "onboarding", "sync", "blockers",

        // ── Daily high-freq tech ──
        "Wi-Fi", "Bluetooth", "AirDrop", "iCloud", "FaceTime", "App Store",
        "podcast", "playlist", "subscription", "screenshot", "notification",
        "AirPods", "HomePod", "MacBook", "iPad",
    ]

    // MARK: - Initialization

    private static let migratedKey = "tf_hotwords_migrated_to_file_v2"
    private static let oldUDKey = "tf_hotwords"

    /// Seeds built-in file and migrates old UserDefaults data to user file.
    static func migrateIfNeeded() {
        // Seed built-in file if missing
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            saveBuiltin(defaultHotwords)
        }

        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else { return }
        let raw = UserDefaults.standard.string(forKey: oldUDKey) ?? ""
        let oldWords = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Filter out entries that duplicate built-in
        let builtinSet = Set(defaultHotwords.map { $0.lowercased() })
        let userOnly = oldWords.filter { !builtinSet.contains($0.lowercased()) }

        if !userOnly.isEmpty {
            save(userOnly)
        }
    }

    // MARK: - User file (Settings UI)

    static func load() -> [String] {
        return readFile(userFileURL)
    }

    static func save(_ words: [String]) {
        writeFile(words, to: userFileURL)
        SenseVoiceServerManager.syncHotwordsAndRestart()
    }

    // MARK: - Built-in file (Finder editable)

    static func loadBuiltin() -> [String] {
        return readFile(builtinFileURL)
    }

    static func saveBuiltin(_ words: [String]) {
        writeFile(words, to: builtinFileURL)
        SenseVoiceServerManager.syncHotwordsAndRestart()
    }

    static func builtinCount() -> Int {
        return loadBuiltin().count
    }

    /// Reveal built-in hotwords file in Finder.
    static func revealBuiltinInFinder() {
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            saveBuiltin(defaultHotwords)
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([builtinFileURL])
        #endif
    }

    // MARK: - Effective (merge both stores)

    /// Returns built-in + user hotwords merged (deduplicated, case-insensitive).
    static func loadEffective() -> [String] {
        let builtin = loadBuiltin()
        let user = load()
        var seen = Set(builtin.map { $0.lowercased() })
        var result = builtin
        for word in user {
            let lower = word.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                result.append(word)
            }
        }
        return result
    }

    // MARK: - Finder

    /// Reveal user hotwords file in Finder.
    static func revealUserInFinder() {
        let url = userFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            save([])
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return words
    }

    private static func writeFile(_ words: [String], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(words) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
