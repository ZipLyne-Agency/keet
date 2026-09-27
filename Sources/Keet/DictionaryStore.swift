import Foundation

/// A word Keet should get right: a name, a company, jargon.
struct DictionaryWord: Codable, Identifiable, Equatable {
    var id = UUID()
    /// How it should be written.
    var text: String
    /// What the model tends to hear instead ("zip line" for "ZipLyne"). Optional.
    var heardAs: [String] = []
}

/// Your dictionary, kept in ~/Library/Application Support/Keet/dictionary.json.
@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var words: [DictionaryWord] = []
    var onChange: () -> Void = {}

    private let url: URL
    private let persists: Bool

    /// In-memory store with the given words (screenshots, previews).
    init(sample: [DictionaryWord]) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("keet-sample-dictionary.json")
        persists = false
        words = sample
    }

    init() {
        persists = true
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("dictionary.json")
        if let data = try? Data(contentsOf: url) {
            words = (try? JSONDecoder().decode([DictionaryWord].self, from: data)) ?? []
        }
    }

    /// Adds a word, or updates its "heard as" list if it's already there.
    func add(_ text: String, heardAs: [String]) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let heard = heardAs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let index = words.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            words[index].text = text
            words[index].heardAs = Array(Set(words[index].heardAs + heard)).sorted()
        } else {
            words.insert(DictionaryWord(text: text, heardAs: heard), at: 0)
        }
        save()
    }

    func remove(_ id: DictionaryWord.ID) {
        words.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if persists, let data = try? JSONEncoder().encode(words) { try? data.write(to: url, options: .atomic) }
        onChange()
    }
}
