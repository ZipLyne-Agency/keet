import Foundation

/// Applies the Dictionary's word swaps to a transcript itself, keeping only safe ones.
///
/// FluidAudio's rescorer finds where a dictionary word was misheard and rebuilds the
/// sentence around its swaps. Run over AI and coding terms, that rebuild dropped the
/// period and the "'s" next to a swapped word ("Claude's" became "Claude"), swallowed
/// small neighbors ("the React native" became "React Native", "open a PR" became
/// "OpenAI PR"), and turned real words into dictionary words ("Google Cloud Console"
/// became "Google Claude Console", "Rebase" became "Firebase"). Keet takes the list of
/// swaps instead and applies each one only if:
///
/// - what was heard is the dictionary word or one of its "heard as" spellings, or
/// - it doesn't pull in a small word at either edge that the dictionary word lacks, and
/// - it isn't a real English word unless it is nearly the dictionary word already.
///
/// The punctuation and "'s" around the heard words stay.
enum VocabularyGuard {
    struct Swap: Equatable {
        let heard: String
        let term: String
    }

    static func apply(
        _ swaps: [Swap], to text: String, words: [Transcriber.VocabularyWord], isEnglishWord: (String) -> Bool
    ) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let norms = tokens.map(normalize)
        var edits: [(range: Range<Int>, text: String)] = []
        var cursor = 0

        for swap in swaps {
            let heard = swap.heard.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
            guard !heard.isEmpty,
                  let start = find(heard, in: norms, from: cursor) ?? find(heard, in: norms, from: 0)
            else { continue }
            let range = start..<(start + heard.count)
            guard !edits.contains(where: { $0.range.overlaps(range) }),
                  let word = words.first(where: { $0.text == swap.term })
                      ?? words.first(where: { $0.text.lowercased() == swap.term.lowercased() }),
                  allowed(heard, as: word, isEnglishWord: isEnglishWord)
            else { continue }

            let first = tokens[range.lowerBound], last = tokens[range.upperBound - 1]
            let lead = String(first.prefix(while: { openers.contains($0) }))
            let trail = String(last.reversed().prefix(while: { closers.contains($0) }).reversed())
            var core = String(last.dropLast(trail.count)).lowercased()
            core = core.replacingOccurrences(of: "\u{2019}", with: "'")
            var suffix = ""
            if core.hasSuffix("'s"), !word.text.lowercased().hasSuffix("'s") {
                suffix = last.contains("\u{2019}s") ? "\u{2019}s" : "'s"
            } else if core.hasSuffix("s"), !word.text.lowercased().hasSuffix("s"),
                      spellings(of: word).contains(String(heard.joined().dropLast())) {
                suffix = "s"
            }
            edits.append((range, lead + word.text + suffix + trail))
            cursor = range.upperBound
        }

        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            tokens.replaceSubrange(edit.range, with: [edit.text])
        }
        return tokens.joined(separator: " ")
    }

    private static let openers = Set("\"'(\u{201C}\u{2018}[")
    private static let closers = Set(".,!?;:\"')\u{201D}]")

    /// Small words a swap must not swallow ("open a" is not "OpenAI").
    private static let smallWords: Set<String> = [
        "a", "an", "the", "to", "and", "or", "of", "in", "on", "at", "it", "its", "it's", "for", "with", "is",
        "are", "was", "be", "my", "your", "our", "this", "that", "then", "than", "so", "but", "if", "as", "by",
        "from", "up", "out", "into", "not", "no", "i", "you", "we", "they", "he", "she", "me", "us", "them",
        "his", "her", "their", "do", "did", "just", "also", "all",
    ]

    static func allowed(_ heard: [String], as word: Transcriber.VocabularyWord, isEnglishWord: (String) -> Bool) -> Bool {
        let joined = heard.joined()
        let known = spellings(of: word)
        if known.contains(joined) || known.contains(stripPossessive(joined)) { return true }

        if heard.count > 1 {
            let termWords = Set(([word.text] + word.heardAs).flatMap {
                $0.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
            })
            for edge in [heard[0], heard[heard.count - 1]] where smallWords.contains(edge) && !termWords.contains(edge) {
                return false
            }
        }

        // "cloud" is not "Claude", "rebase" is not "Firebase", "agents" is not "AGENTS.md".
        let target = known.first ?? joined
        let everyWordIsEnglish = heard.allSatisfy { isEnglish(stripPossessive($0), isEnglishWord) }
        if everyWordIsEnglish, similarity(stripPossessive(joined), target) < 0.85 { return false }
        return true
    }

    /// The dictionary word and its "heard as" spellings, normalized and without spaces.
    private static func spellings(of word: Transcriber.VocabularyWord) -> [String] {
        ([word.text] + word.heardAs).map {
            $0.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.joined()
        }
    }

    private static func isEnglish(_ word: String, _ isEnglishWord: (String) -> Bool) -> Bool {
        if isEnglishWord(word) { return true }
        if word.hasSuffix("es"), isEnglishWord(String(word.dropLast(2))) { return true }
        if word.hasSuffix("s"), isEnglishWord(String(word.dropLast())) { return true }
        return false
    }

    private static func stripPossessive(_ word: String) -> String {
        word.hasSuffix("'s") ? String(word.dropLast(2)) : word
    }

    /// Lowercase letters, digits and apostrophes only.
    static func normalize(_ token: String) -> String {
        String(token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == "'" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    private static func find(_ needle: [String], in haystack: [String], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        for i in start...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }
}

/// The system word list (/usr/share/dict/words, Webster's Second), searched in place.
/// It has no plurals and few modern words, which suits the guard: it only needs to
/// know that "cloud" and "rebase" are ordinary words.
enum EnglishWords {
    private static let data: Data? = try? Data(
        contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"), options: .alwaysMapped)

    static func contains(_ word: String) -> Bool {
        guard let data, !word.isEmpty else { return false }
        let lower = word.lowercased()
        for form in [lower, lower.prefix(1).uppercased() + lower.dropFirst()] {
            let line = Data(("\n" + form + "\n").utf8)
            if data.range(of: line) != nil || data.starts(with: line.dropFirst()) { return true }
        }
        return false
    }
}
