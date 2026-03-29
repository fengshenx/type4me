import Foundation

/// Stores trigger → replacement snippet mappings in UserDefaults.
enum SnippetStorage {

    private static let key = "tf_snippets"
    private static let seededKey = "tf_snippets_seeded_v1"

    // MARK: - Built-in ASR correction mappings (verified by testing)

    /// Default snippet mappings seeded on first launch.
    /// Each entry is (trigger, replacement). Triggers are case-insensitive and
    /// tolerate whitespace variations via buildFlexPattern.
    ///
    /// Verified against: Volcengine Seed ASR 2.0, Qwen3-ASR 0.6B/1.7B, SenseVoice-Small.
    private static let defaultSnippets: [(trigger: String, value: String)] = [
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
        ("ELMA",            "Llama"),
        ("OELMA",           "Ollama"),
        ("finight tuning",  "fine-tuning"),

        // ── Frameworks & tools ──
        ("long chain",      "LangChain"),
        ("long train",      "LangChain"),
        ("LongChain",       "LangChain"),

        // ── SenseVoice-specific garbled output ──
        ("pinecom",         "Pinecone"),
        ("typepescript",    "TypeScript"),
        ("contexwin",       "context window"),
        ("multiag",         "multi-agent"),
        ("deepse",          "DeepSeek"),
    ]

    /// Seeds default ASR correction snippets, merging with any existing user snippets.
    /// Skips entries whose trigger already exists (case-insensitive) to avoid duplicates.
    static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        var existing = load()
        let existingTriggers = Set(existing.map { $0.trigger.lowercased() })
        for snippet in defaultSnippets where !existingTriggers.contains(snippet.trigger.lowercased()) {
            existing.append(snippet)
        }
        save(existing)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    static func load() -> [(trigger: String, value: String)] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data)
        else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (trigger: pair[0], value: pair[1])
        }
    }

    static func save(_ snippets: [(trigger: String, value: String)]) {
        let pairs = snippets.map { [$0.trigger, $0.value] }
        if let data = try? JSONEncoder().encode(pairs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Apply all snippet replacements to text.
    /// Builds a regex per trigger that allows optional whitespace between each character cluster,
    /// so "我的Gmail邮箱" matches "我的 Gmail 邮箱", "我的Gmail 邮箱", etc.
    static func apply(to text: String) -> String {
        let snippets = load()
        guard !snippets.isEmpty else { return text }
        var result = text
        for snippet in snippets {
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

    /// Splits trigger into character clusters and joins with flexible whitespace matchers.
    /// Words (whitespace-separated) are joined with `\s+`, and within each word, runs of
    /// different scripts (CJK vs ASCII) are joined with `\s*`.
    private static func buildFlexPattern(_ trigger: String) -> String {
        let words = trigger.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let wordPatterns = words.map { word -> String in
            var clusters: [String] = []
            var current = ""
            var lastType: CharType?
            for ch in word {
                let type = charType(ch)
                if let last = lastType, last != type {
                    if !current.isEmpty { clusters.append(NSRegularExpression.escapedPattern(for: current)) }
                    current = String(ch)
                } else {
                    current.append(ch)
                }
                lastType = type
            }
            if !current.isEmpty { clusters.append(NSRegularExpression.escapedPattern(for: current)) }
            return clusters.joined(separator: "\\s*")
        }
        return wordPatterns.joined(separator: "\\s+")
    }

    private enum CharType { case cjk, ascii, other }

    private static func charType(_ ch: Character) -> CharType {
        guard let scalar = ch.unicodeScalars.first else { return .other }
        let v = scalar.value
        // CJK Unified Ideographs + common CJK ranges
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) ||
           (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v) {
            return .cjk
        }
        if ch.isASCII { return .ascii }
        return .other
    }
}
