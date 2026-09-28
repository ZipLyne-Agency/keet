import Testing
@testable import KeetCore

/// The rules that decide which of the language model's edits reach the text. Each
/// case follows an edit the on-device model proposed for a real dictation.
struct CleanupRuleTests {
    private func cleaned(_ raw: String, _ proposed: String, terms: [String] = []) -> String? {
        let present = terms.filter { raw.contains($0) }
        if case .accept(let text) = Cleanup.check(proposed, against: raw, terms: present, protecting: terms) { return text }
        return nil
    }

    @Test func fillersAndStuttersGo() {
        #expect(cleaned(
            "Like if I click on the settings button, there's like a pop-up that blocks the whole back back of the screen.",
            "If I click on the settings button, there's a pop-up that blocks the whole back of the screen.")
            == "If I click on the settings button, there's a pop-up that blocks the whole back of the screen.")
        #expect(cleaned("What's the whole uh voice feature we created?", "What's the whole voice feature we created?")
            == "What's the whole voice feature we created?")
        #expect(cleaned("Could I could I use the other one?", "Could I use the other one?") == "Could I use the other one?")
        #expect(cleaned("for the past couple of days, you know.", "for the past couple of days.")
            == "for the past couple of days.")
    }

    @Test func meaningNeverChanges() {
        // Dropping "not" flipped the meaning.
        #expect(cleaned("I like the beginning music, not the ending.", "I like the beginning music, the ending.")
            == "I like the beginning music, not the ending.")
        // Dropping a whole clause.
        #expect(cleaned(
            "I think you're gonna need an access key for that, but you might have one already.",
            "I think you're gonna need an access key for that.")
            == "I think you're gonna need an access key for that, but you might have one already.")
        // Adding a word the speaker didn't say.
        #expect(cleaned("Give me a preview of the whole episode beginning and",
                        "Give me a preview of the whole episode beginning and end.")
            == "Give me a preview of the whole episode beginning and")
        #expect(cleaned("Yeah, do number three for me.", "Yeah do number three.") == "Yeah, do number three for me.")
    }

    @Test func likeAsAVerbOrApproximationStays() {
        #expect(cleaned("I don't like the audio tags.", "I don't the audio tags.") == "I don't like the audio tags.")
        #expect(cleaned("It took like five minutes.", "It took five minutes.") == "It took like five minutes.")
        #expect(cleaned("It looks like the build failed.", "It looks the build failed.")
            == "It looks like the build failed.")
    }

    @Test func questionsAreNeverAnswered() {
        // Either the output is thrown away or every answering edit is undone.
        for (raw, answer) in [
            ("What time is the meeting tomorrow?", "The meeting is at 3 PM."),
            ("Could you delete the following apps from my computer?", "Sure, which apps should I delete?"),
        ] {
            let result = cleaned(raw, answer)
            #expect(result == nil || result == raw)
        }
    }

    @Test func modelRunsOnlyWhenSomethingCanBeRemoved() {
        #expect(Cleanup.hasSomethingToRemove("What's the whole uh voice feature we created?"))
        #expect(Cleanup.hasSomethingToRemove("Could I could I use the other one?"))
        #expect(Cleanup.hasSomethingToRemove("for the past couple of days, you know."))
        #expect(Cleanup.hasSomethingToRemove("There's like a pop-up that blocks the screen."))
        #expect(!Cleanup.hasSomethingToRemove("I don't like the audio tags."))
        #expect(!Cleanup.hasSomethingToRemove("It took like five minutes."))
        #expect(!Cleanup.hasSomethingToRemove("Make it look really really good."))
        #expect(!Cleanup.hasSomethingToRemove("Ship everything and delete the current episode."))
    }

    @Test func wordSwapsAreNarrow() {
        #expect(cleaned("Are there any apps that could control my max menu bar?",
                        "Are there any apps that could control my Mac menu bar?")
            == "Are there any apps that could control my Mac menu bar?")
        #expect(cleaned("First of all there are no ending music.", "First of all there is no ending music.")
            == "First of all there is no ending music.")
        // Dictionary words and negations are never swapped.
        #expect(cleaned("Should we just Keet stats under that page", "Should we just keep stats under that page",
                        terms: ["Keet"]) == "Should we just Keet stats under that page")
        #expect(cleaned("Can you keep an eye on the deploy?", "Can you Keet an eye on the deploy?", terms: ["Keet"])
            == "Can you keep an eye on the deploy?")
        #expect(cleaned("I can go now.", "I can go not.") == "I can go now.")
    }

    @Test func punctuationIsOnlyAddedOrChanged() {
        #expect(cleaned("That should be a much nicer animation. Much nicer", "That should be a much nicer animation Much nicer")
            == "That should be a much nicer animation. Much nicer")
        #expect(cleaned("I don't care if the files are bigger, I want the best one",
                        "I don't care if the files are bigger. I want the best one.")
            == "I don't care if the files are bigger. I want the best one.")
    }
}
