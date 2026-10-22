import Combine
import Testing
@testable import Keet

@MainActor
struct AudioLevelsTests {
    @Test func repeatedReadingsDoNotPublish() {
        let levels = AudioLevels()
        var changes = 0
        let observation = levels.objectWillChange.sink { changes += 1 }
        for _ in 0..<400 { levels.update(level: 0.5) }
        #expect(changes == 1)
        levels.reset()
        #expect(changes == 2)
        withExtendedLifetime(observation) {}
    }

    @Test func meteringDoesNotInvalidateTheHistoryWindow() {
        let controller = AppController(history: HistoryStore(sample: []), dictionary: DictionaryStore(sample: []))
        var windowChanges = 0, meterChanges = 0
        let window = controller.objectWillChange.sink { windowChanges += 1 }
        let meter = controller.audioLevels.objectWillChange.sink { meterChanges += 1 }
        for i in 0..<400 { controller.audioLevels.update(level: Float(i % 10) / 10) }
        #expect(meterChanges > 390)
        #expect(windowChanges == 0)
        withExtendedLifetime((window, meter)) {}
    }
}
