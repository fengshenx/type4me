import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Snippet replacement with two independent stores:
/// - **Built-in file** (`builtin-snippets.json`): seeded from defaults, user-editable via Finder for bulk ops
/// - **User file** (`snippets.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime; user entries override built-in on trigger conflict.
enum SnippetStorage {

    // MARK: - File paths

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("Type4Me")
    }

    /// Built-in snippets file (seeded from defaults, user-editable for bulk ops)
    static var builtinFileURL: URL { appSupportDir.appendingPathComponent("builtin-snippets.json") }

    /// User snippets file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("snippets.json") }

    // MARK: - Codable model

    private struct Entry: Codable {
        let trigger: String
        let replacement: String
    }

    // MARK: - Default snippets (used for initial seeding)

    /// Default ASR correction mappings. Seeded into builtin-snippets.json on first launch.
    /// Triggers are matched case-insensitively and space-insensitively.
    ///
    /// Verified against: Volcengine Seed ASR 2.0, Qwen3-ASR 0.6B/1.7B, SenseVoice-Small.
    static let defaultSnippets: [(trigger: String, value: String)] = [
        // ── vibe coding (all engines consistently fail) ──
        ("web coding",      "vibe coding"),
        ("webb coding",     "vibe coding"),
        ("vab coding",      "vibe coding"),
        ("vabe coding",     "vibe coding"),
        ("vibes coding",    "vibe coding"),
        ("Vipcoding",       "vibe coding"),
        ("vipe coding",     "vibe coding"),

        // ── Claude → Cloud (universal error) ──
        ("Cloud Code",      "Claude Code"),

        // ── Model & company names ──
        ("Asthropic",       "Anthropic"),
        ("Anthropropic",    "Anthropic"),
        ("Anthropick",      "Anthropic"),
        ("Anthrobic",       "Anthropic"),
        ("ELMA",            "Llama"),
        ("OELMA",           "Ollama"),
        ("finight tuning",  "fine-tuning"),
        ("fine tune",       "fine-tune"),

        // ── Frameworks & tools ──
        ("long chain",      "LangChain"),
        ("long train",      "LangChain"),
        ("get hub",         "GitHub"),
        ("git hub",         "GitHub"),
        ("VS code",         "VS Code"),
        ("Kubanetes",       "Kubernetes"),
        ("Kubenetes",       "Kubernetes"),
        ("Nextjs",          "Next.js"),
        ("type script",     "TypeScript"),
        ("open source",     "open-source"),

        // ── SenseVoice-specific garbled output ──
        ("pinecom",         "Pinecone"),
        ("typepescript",    "TypeScript"),
        ("contexwin",       "context window"),
        ("multiag",         "multi-agent"),
        ("deepse",          "DeepSeek"),
    ]

    // MARK: - Initialization

    private static let migratedKey = "tf_snippets_migrated_to_file_v2"
    private static let oldUDKey = "tf_snippets"

    /// Seeds built-in file and migrates old UserDefaults data to user file.
    static func migrateIfNeeded() {
        // Seed built-in file if missing
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            saveBuiltin(defaultSnippets)
        }

        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else { return }
        guard let data = UserDefaults.standard.data(forKey: oldUDKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data)
        else { return }

        let oldSnippets = pairs.compactMap { pair -> (trigger: String, value: String)? in
            guard pair.count == 2 else { return nil }
            return (trigger: pair[0], value: pair[1])
        }

        // Filter out entries that duplicate built-in
        func norm(_ s: String) -> String { s.filter { !$0.isWhitespace }.lowercased() }
        let builtinKeys = Set(defaultSnippets.map { "\(norm($0.trigger))\t\($0.value)" })
        let userOnly = oldSnippets.filter { !builtinKeys.contains("\(norm($0.trigger))\t\($0.value)") }

        if !userOnly.isEmpty {
            save(userOnly)
        }
    }

    // MARK: - User file (Settings UI)

    static func load() -> [(trigger: String, value: String)] {
        return readFile(userFileURL)
    }

    static func save(_ snippets: [(trigger: String, value: String)]) {
        writeFile(snippets, to: userFileURL)
    }

    // MARK: - Built-in file (Finder editable)

    static func loadBuiltin() -> [(trigger: String, value: String)] {
        return readFile(builtinFileURL)
    }

    static func saveBuiltin(_ snippets: [(trigger: String, value: String)]) {
        writeFile(snippets, to: builtinFileURL)
    }

    static func builtinCount() -> Int {
        return loadBuiltin().count
    }

    /// Reveal built-in snippets file in Finder.
    static func revealBuiltinInFinder() {
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            saveBuiltin(defaultSnippets)
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([builtinFileURL])
        #endif
    }

    // MARK: - Apply (merge both stores)

    /// Apply built-in + user snippets. User entries override built-in on trigger conflict.
    static func applyEffective(to text: String) -> String {
        let builtinSnippets = loadBuiltin()
        let userSnippets = load()
        let userTriggers = Set(userSnippets.map { $0.trigger.lowercased() })
        let effectiveBuiltin = builtinSnippets.filter { !userTriggers.contains($0.trigger.lowercased()) }
        let allSnippets = effectiveBuiltin + userSnippets

        var result = text
        for snippet in allSnippets {
            let pattern = buildFlexPattern(snippet.trigger)
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: snippet.value)
                )
            }
        }
        return result
    }

    // MARK: - Pattern building

    /// Builds a regex that matches the trigger case-insensitively and space-insensitively.
    /// Strips all whitespace from trigger, then inserts `\s*` between each character.
    private static func buildFlexPattern(_ trigger: String) -> String {
        let chars = trigger.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return NSRegularExpression.escapedPattern(for: trigger) }
        return chars.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [(trigger: String, value: String)] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.map { (trigger: $0.trigger, value: $0.replacement) }
    }

    private static func writeFile(_ snippets: [(trigger: String, value: String)], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = snippets.map { Entry(trigger: $0.trigger, replacement: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
