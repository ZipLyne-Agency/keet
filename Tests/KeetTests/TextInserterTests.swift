import AppKit
import Testing
@testable import Keet

@MainActor
struct TextInserterTests {
    @Test func overlappingPastesRestoreTheOriginalClipboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let binary = Data([0, 1, 2, 255])
        let custom = NSPasteboard.PasteboardType("agency.ziplyne.keet.test")
        item.setString("Original clipboard", forType: .string)
        item.setData(binary, forType: custom)
        board.writeObjects([item])
        var pasteEvents = 0
        let inserter = TextInserter(pasteboard: board, postPaste: { pasteEvents += 1 })
        inserter.paste("First dictation")
        inserter.paste("Second dictation")
        #expect(board.string(forType: .string) == "Second dictation")
        #expect(pasteEvents == 2)
        try await Task.sleep(for: .milliseconds(650))
        #expect(board.string(forType: .string) == "Original clipboard")
        #expect(board.data(forType: custom) == binary)
    }

    @Test func aNewCopyDuringPasteIsPreserved() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let inserter = TextInserter(pasteboard: board, postPaste: {})
        inserter.paste("Dictation")
        board.clearContents()
        board.setString("Something copied by the user", forType: .string)
        try await Task.sleep(for: .milliseconds(650))
        #expect(board.string(forType: .string) == "Something copied by the user")
    }
}
