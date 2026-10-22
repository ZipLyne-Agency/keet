import Testing
@testable import Keet

@MainActor
struct DictationWorkQueueTests {
    @Test func slowCleanupCannotReorderOrOverlapDelivery() async throws {
        let queue = DictationWorkQueue()
        var delivered: [Int] = []
        var processing = false
        queue.enqueue {
            processing = true
            try? await Task.sleep(for: .milliseconds(30))
            delivered.append(1)
            processing = false
        }
        let last = queue.enqueue {
            #expect(!processing)
            delivered.append(2)
        }
        await last.value
        #expect(delivered == [1, 2])
    }

    @Test func oldResultsNeverOwnANewerRecordingOrItsTranscription() {
        let queue = DictationWorkQueue()
        let first = queue.beginRecording()
        #expect(queue.isLatest(first))
        let second = queue.beginRecording()
        #expect(!queue.isLatest(first))
        #expect(queue.isLatest(second))
    }
}
