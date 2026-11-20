import Testing
@testable import TranscriptCore

@Suite struct TranscriptCondenserTests {
    @Test func shortTextIsUnchanged() {
        #expect(TranscriptCondenser.tail(of: "hello there", maxCharacters: 20) == "hello there")
    }

    @Test func longTextIsTrimmedOnAWordBoundary() {
        let text = "the quick brown fox jumps over the lazy dog"
        // The last 15 chars are "er the lazy dog"; the partial "er" is dropped.
        #expect(TranscriptCondenser.tail(of: text, maxCharacters: 16) == "…the lazy dog")
    }

    @Test func cutThatFallsOnASpaceKeepsTheWholeWord() {
        // Budget is 8 chars after the ellipsis: "lazy dog" starts right after a space.
        #expect(TranscriptCondenser.tail(of: "the lazy dog", maxCharacters: 9) == "…lazy dog")
    }

    @Test func singleLongWordIsCutMidWord() {
        #expect(TranscriptCondenser.tail(of: "supercalifragilistic", maxCharacters: 8) == "…ilistic")
    }

    @Test func interimSegmentsAreReplacedAndFinalsAppended() {
        var condenser = TranscriptCondenser(maxCharacters: 200)
        condenser.ingest(.init("so the", isFinal: false))
        condenser.ingest(.init("so the plan", isFinal: false))
        #expect(condenser.fullText == "so the plan")

        condenser.ingest(.init("So the plan is set.", isFinal: true))
        condenser.ingest(.init("Next", isFinal: false))
        #expect(condenser.fullText == "So the plan is set. Next")
        #expect(condenser.wordCount == 6)

        condenser.ingest(.init("", isFinal: true))
        #expect(condenser.fullText == "So the plan is set.")
    }
}
