import Foundation

/// One caption line. `id` is where the line starts in the full transcript, so it stays the
/// same while the line is on screen (including when it moves up a row as lines roll).
public struct Caption: Hashable, Sendable, Identifiable {
    public var id: Int
    public var text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// Wraps a growing transcript into a fixed number of caption lines, like live captions:
/// words are added to the last line, and when it's full the lines roll up.
///
/// Line breaks are decided here rather than by the text view, so as the text grows a
/// word never jumps from the end of one line to the start of the next; earlier lines
/// stay exactly as they were until they roll off the top.
public struct CaptionLines: Sendable {
    public let maxLines: Int
    /// Whether a line of text fits the available width.
    private let fits: @Sendable (String) -> Bool
    /// Character offset in the full text where the first shown line starts.
    public private(set) var start = 0

    /// Wraps at a character count (for monospaced text, or a rough estimate).
    public init(charactersPerLine: Int, maxLines: Int = 2) {
        let width = max(charactersPerLine, 1)
        self.init(maxLines: maxLines) { $0.count <= width }
    }

    /// Wraps by measured width: `fits` says whether a line's text fits.
    public init(maxLines: Int = 2, fits: @escaping @Sendable (String) -> Bool) {
        self.maxLines = max(maxLines, 1)
        self.fits = fits
    }

    public mutating func lines(for text: String) -> [String] {
        captions(for: text).map(\.text)
    }

    /// The lines with stable IDs (each line's start offset in `text`), so a view can keep a
    /// line's identity as it moves up a row.
    public mutating func captions(for text: String) -> [Caption] {
        if start > text.count {
            start = 0  // the text was revised to something shorter; start over
        }
        var (lines, starts) = Self.wrap(text.dropFirst(start), fits: fits)
        if lines.count > maxLines {
            let rolledOff = lines.count - maxLines
            start += starts[rolledOff]
            lines.removeFirst(rolledOff)
            starts = starts.dropFirst(rolledOff).map { $0 - starts[rolledOff] }
        }
        return zip(lines, starts).map { Caption(id: start + $1, text: $0) }
    }

    public mutating func reset() {
        start = 0
    }

    /// Greedy word wrap. Returns the lines and each line's start offset within `text`.
    /// Words too long for a line are split.
    static func wrap(_ text: Substring, fits: (String) -> Bool) -> (lines: [String], starts: [Int]) {
        var lines: [String] = []
        var starts: [Int] = []
        var current = ""
        var currentStart = 0
        var offset = 0
        var index = text.startIndex

        func finishLine() {
            guard !current.isEmpty else { return }
            lines.append(current)
            starts.append(currentStart)
            current = ""
        }

        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                offset += 1
                continue
            }
            var wordStart = offset
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
                offset += 1
            }
            var word = String(text[index..<end])
            index = end

            while word.count > 1, !fits(word) {  // an overlong word gets lines of its own
                finishLine()
                var piece = ""
                for character in word {
                    guard fits(piece + String(character)) else { break }
                    piece.append(character)
                }
                if piece.isEmpty { piece = String(word.first!) }
                lines.append(piece)
                starts.append(wordStart)
                word.removeFirst(piece.count)
                wordStart += piece.count
            }
            if word.isEmpty { continue }

            if current.isEmpty {
                current = word
                currentStart = wordStart
            } else if fits(current + " " + word) {
                current += " " + word
            } else {
                finishLine()
                current = word
                currentStart = wordStart
            }
        }
        finishLine()
        return (lines, starts)
    }
}
