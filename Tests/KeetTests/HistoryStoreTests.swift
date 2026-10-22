import Foundation
import Testing
@testable import Keet

@MainActor
struct HistoryStoreTests {
    private func entry(_ text: String = "A local test transcript.") -> Dictation {
        Dictation(date: Date(timeIntervalSince1970: 1_792_656_000), text: text,
                  audioSeconds: 1, latencyMs: 50, delivery: .card)
    }

    @Test func disablingHistoryCannotBeUndoneByAnAlreadyQueuedWrite() throws {
        let suite = "keet-history-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let writer = DispatchQueue(label: suite)
        let store = HistoryStore(storageURL: url, preferences: preferences, writer: writer)
        writer.suspend()
        store.add(entry())
        store.keepOnDisk = false
        writer.resume()
        writer.sync {}
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.entries.count == 1)
    }

    @Test func historyLoadsAndCapsEntries() throws {
        let suite = "keet-history-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let writer = DispatchQueue(label: suite)
        let store = HistoryStore(storageURL: url, preferences: preferences, writer: writer)
        store.add(entry())
        writer.sync {}
        let restored = HistoryStore(storageURL: url, preferences: preferences, writer: writer)
        #expect(restored.entries == store.entries)
        let many = HistoryStore(sample: (0..<10_000).map { entry("Test \($0)") })
        let newest = entry("Newest")
        many.add(newest)
        #expect(many.entries.count == 10_000)
        #expect(many.entries.first?.id == newest.id)
    }

    @Test func disabledPersistenceDoesNotReloadAnOldSnapshot() throws {
        let suite = "keet-history-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let writer = DispatchQueue(label: suite)
        let store = HistoryStore(storageURL: url, preferences: preferences, writer: writer)
        store.add(entry())
        writer.sync {}
        preferences.set(false, forKey: "keepHistory")
        preferences.set(["A legacy transcript"], forKey: "history")
        let restored = HistoryStore(storageURL: url, preferences: preferences, writer: writer)
        writer.sync {}
        #expect(restored.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(preferences.stringArray(forKey: "history") == nil)
    }
}
