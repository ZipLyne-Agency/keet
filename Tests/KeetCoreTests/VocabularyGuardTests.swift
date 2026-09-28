import Testing
@testable import KeetCore

/// Which of the word spotter's swaps reach the text. Each case is a swap FluidAudio
/// proposed on spoken test sentences.
struct VocabularyGuardTests {
    private let words = [
        Transcriber.VocabularyWord(text: "Claude", heardAs: ["clawed", "claud"]),
        Transcriber.VocabularyWord(text: "CLAUDE.md", heardAs: ["Claude MD", "cloud MD"]),
        Transcriber.VocabularyWord(text: "ChatGPT", heardAs: ["chat GPT"]),
        Transcriber.VocabularyWord(text: "OpenAI", heardAs: ["open AI"]),
        Transcriber.VocabularyWord(text: "React Native"),
        Transcriber.VocabularyWord(text: "Vercel", heardAs: ["Versal"]),
        Transcriber.VocabularyWord(text: "Firebase"),
        Transcriber.VocabularyWord(text: "Infisical", heardAs: ["in physical"]),
        Transcriber.VocabularyWord(text: "Postgres"),
        Transcriber.VocabularyWord(text: "Ollama", heardAs: ["olima"]),
    ]

    private func apply(_ text: String, _ swaps: [(String, String)]) -> String {
        VocabularyGuard.apply(swaps.map { VocabularyGuard.Swap(heard: $0.0, term: $0.1) }, to: text, words: words,
                              isEnglishWord: EnglishWords.contains)
    }

    @Test func realWordsStay() {
        #expect(apply("Log in to Google Cloud Console.", [("Cloud", "Claude")]) == "Log in to Google Cloud Console.")
        #expect(apply("Rebase the branch.", [("Rebase", "Firebase")]) == "Rebase the branch.")
        #expect(apply("Run Llama locally.", [("Llama", "Ollama")]) == "Run Llama locally.")
    }

    @Test func smallNeighborsAreNotSwallowed() {
        #expect(apply("Push the fix and open a PR.", [("open a", "OpenAI")]) == "Push the fix and open a PR.")
        #expect(apply("Rewrite the React native screens.", [("the React native", "React Native")])
            == "Rewrite the React native screens.")
        #expect(apply("Ask Claude to review it.", [("Claude to", "CLAUDE.md")]) == "Ask Claude to review it.")
    }

    @Test func punctuationAndPossessivesStay() {
        #expect(apply("Claude's answer was better than Chat GPT's.", [("Claude's", "Claude"), ("Chat GPT's", "ChatGPT")])
            == "Claude's answer was better than ChatGPT's.")
        #expect(apply("Deploy it on Versal.", [("Versal", "Vercel")]) == "Deploy it on Vercel.")
    }

    @Test func realFixesApply() {
        #expect(apply("Pull the secrets from in physical.", [("in physical", "Infisical")])
            == "Pull the secrets from Infisical.")
        #expect(apply("Store it in postgers, then restart.", [("postgers", "Postgres")]) == "Store it in Postgres, then restart.")
        #expect(apply("Use clawed for it", [("clawed", "Claude")]) == "Use Claude for it")
        #expect(apply("Run Olima on the Mac.", [("Olima", "Ollama")]) == "Run Ollama on the Mac.")
    }
}
