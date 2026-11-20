import Foundation

/// A chunk of recognized speech. Interim segments replace the previous interim
/// segment; final segments are committed to the transcript.
public struct TranscriptSegment: Hashable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(_ text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Accumulates a live transcript from the recognizer's interim and final segments.
/// `tail` is a short preview of its end.
public struct TranscriptCondenser: Sendable {
    public private(set) var committed = ""
    public private(set) var interim = ""
    public let maxCharacters: Int

    public init(maxCharacters: Int = 80) {
        self.maxCharacters = max(maxCharacters, 2)
    }

    public mutating func ingest(_ segment: TranscriptSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.isFinal {
            if !text.isEmpty {
                committed = committed.isEmpty ? text : committed + " " + text
            }
            interim = ""
        } else {
            interim = text
        }
    }

    public var fullText: String {
        [committed, interim].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var wordCount: Int {
        fullText.split(whereSeparator: \.isWhitespace).count
    }

    public var tail: String {
        Self.tail(of: fullText, maxCharacters: maxCharacters)
    }

    /// The end of `text`, at most `maxCharacters` long. When trimmed, the cut
    /// lands on a word boundary (unless a single word is longer than the budget)
    /// and the result starts with "…".
    public static func tail(of text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let budget = max(maxCharacters - 1, 1)  // leave room for the ellipsis
        let start = text.index(text.endIndex, offsetBy: -budget)
        var kept = text[start...]

        let startsMidWord = !text[text.index(before: start)].isWhitespace
            && !(kept.first?.isWhitespace ?? true)
        if startsMidWord, let space = kept.firstIndex(where: \.isWhitespace) {
            kept = kept[space...]
        }
        return "…" + kept.trimmingCharacters(in: .whitespaces)
    }
}
