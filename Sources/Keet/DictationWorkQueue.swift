import Foundation

/// Final dictations run in capture order, including cleanup and delivery. A newer
/// recording owns the indicator even while older speech is still being processed.
@MainActor
final class DictationWorkQueue {
    private var pending: Task<Void, Never>?
    private var latestID = 0

    func beginRecording() -> Int {
        latestID += 1
        return latestID
    }

    func isLatest(_ id: Int) -> Bool { id == latestID }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = pending
        let task = Task {
            await previous?.value
            await operation()
        }
        pending = task
        return task
    }
}
