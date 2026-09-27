import AppKit
import Foundation

/// One finished dictation.
struct Dictation: Codable, Identifiable, Equatable {
    enum Delivery: String, Codable {
        /// Pasted into the focused field.
        case pasted
        /// No field had focus; shown on the Copy card.
        case card
        /// Escape pressed on a long dictation: kept, not pasted.
        case cancelled
    }

    var id = UUID()
    var date: Date
    var text: String
    /// The app the text went to.
    var appName: String?
    var bundleID: String?
    var audioSeconds: Double
    /// Key release to text delivered.
    var latencyMs: Int
    var delivery: Delivery
    /// Loudest 10 ms of the recording, in dBFS. Older entries don't have it.
    var peakDb: Float?

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// Every dictation, newest first, kept in ~/Library/Application Support/Keet/history.json.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [Dictation] = []

    /// When off, dictations live only in memory until Keet quits.
    @Published var keepOnDisk: Bool = UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepOnDisk, forKey: "keepHistory")
            if keepOnDisk { save() } else { try? FileManager.default.removeItem(at: url) }
        }
    }

    private let url: URL
    private let limit = 10_000
    private let writer = DispatchQueue(label: "keet.history", qos: .utility)

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        load()
        migrateLegacy()
    }

    /// In-memory store with the given entries (screenshots, previews).
    init(sample: [Dictation]) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("keet-sample-history.json")
        // Set the storage directly: going through the property would run its
        // observer and switch off saving in the real app's settings.
        _keepOnDisk = Published(initialValue: false)
        entries = sample
    }

    func add(_ dictation: Dictation) {
        entries.insert(dictation, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func delete(_ id: Dictation.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Dictation].self, from: data)) ?? []
    }

    private func save() {
        guard keepOnDisk else { return }
        let snapshot = entries
        let url = url
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Early builds kept plain strings in UserDefaults; bring them over once.
    private func migrateLegacy() {
        guard let old = UserDefaults.standard.stringArray(forKey: "history"), !old.isEmpty else { return }
        let now = Date()
        let migrated = old.enumerated().map { index, text in
            Dictation(date: now.addingTimeInterval(-Double(index)), text: text, appName: nil, bundleID: nil,
                      audioSeconds: 0, latencyMs: 0, delivery: .pasted)
        }
        entries.append(contentsOf: migrated)
        UserDefaults.standard.removeObject(forKey: "history")
        save()
    }
}
