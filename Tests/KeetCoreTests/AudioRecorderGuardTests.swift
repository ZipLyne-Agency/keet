import Foundation
import Testing
@testable import KeetCore

/// AVAudioEngine raises Objective-C exceptions (format mismatch while devices change).
/// Uncaught, one of those ended Keet on 2026-11-08 and left the dictation key dead.
struct AudioRecorderGuardTests {
    @Test func exceptionBecomesAnError() {
        var reason = ""
        do {
            try AudioRecorder.guarded {
                NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                            reason: "Input HW format and tap format not matching", userInfo: nil).raise()
            }
            Issue.record("expected a thrown error")
        } catch AudioRecorder.RecorderError.engine(let message) {
            reason = message
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(reason.contains("format not matching"))
    }

    @Test func swiftErrorsAndValuesPassThrough() throws {
        #expect(try AudioRecorder.guarded { 42 } == 42)
        #expect(throws: AudioRecorder.RecorderError.self) {
            try AudioRecorder.guarded { throw AudioRecorder.RecorderError.noInputDevice }
        }
    }
}
