import Testing
@testable import TranscriptCore

@Suite struct CaptionLinesTests {
    @Test func wrapsOnWordsWithinTheWidth() {
        var captions = CaptionLines(charactersPerLine: 10, maxLines: 5)
        let lines = captions.lines(for: "the quick brown fox jumps")
        #expect(lines == ["the quick", "brown fox", "jumps"])
        #expect(lines.allSatisfy { $0.count <= 10 })
    }

    @Test func appendingWordsNeverMovesEarlierWords() {
        var captions = CaptionLines(charactersPerLine: 10, maxLines: 2)
        let before = captions.lines(for: "the quick brown")
        let after = captions.lines(for: "the quick brown fox")
        #expect(before == ["the quick", "brown"])
        #expect(after == ["the quick", "brown fox"])  // only the last line gained a word
    }

    @Test func linesRollUpWhenTheLastLineIsFull() {
        var captions = CaptionLines(charactersPerLine: 10, maxLines: 2)
        _ = captions.lines(for: "the quick brown fox")
        let rolled = captions.lines(for: "the quick brown fox jumps")
        #expect(rolled == ["brown fox", "jumps"])  // old line 2 moved up intact
        // and stays rolled while the new last line fills
        #expect(captions.lines(for: "the quick brown fox jumps over") == ["brown fox", "jumps over"])
    }

    @Test func lineIDsStayTheSameWhenALineMovesUp() {
        var captions = CaptionLines(charactersPerLine: 10, maxLines: 2)
        let before = captions.captions(for: "the quick brown fox")
        let after = captions.captions(for: "the quick brown fox jumps")
        #expect(before.map(\.text) == ["the quick", "brown fox"])
        #expect(after.map(\.text) == ["brown fox", "jumps"])
        #expect(after[0].id == before[1].id)  // same line, now on the top row
        #expect(after[1].id != before[0].id)
        #expect(before.map(\.id) == [0, 10])  // offsets into the full text
        #expect(after.map(\.id) == [10, 20])
    }

    @Test func overlongWordsAreSplit() {
        var captions = CaptionLines(charactersPerLine: 4, maxLines: 5)
        #expect(captions.lines(for: "abcdefghij ok") == ["abcd", "efgh", "ij", "ok"])
    }

    @Test func revisionToShorterTextStartsOver() {
        var captions = CaptionLines(charactersPerLine: 5, maxLines: 1)
        _ = captions.lines(for: "aa bb cc dd")
        #expect(captions.start > 0)
        #expect(captions.lines(for: "aa") == ["aa"])
    }
}
