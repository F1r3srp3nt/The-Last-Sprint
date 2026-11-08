import Foundation

/// Original pasted material, kept in the project so it can always be recovered exactly.
public struct PastedSource: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// The text exactly as pasted.
    public var text: String
    public var importedAt: Date

    public init(id: UUID = UUID(), title: String, text: String, importedAt: Date = Date()) {
        self.id = id; self.title = title; self.text = text
        self.importedAt = ProjectCodec.wholeSeconds(importedAt)
    }
}

/// A block proposed from pasted text, before the user confirms it.
public struct ProposedBlock: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Exact text from the paste (see `ContextSplitter` for what boundaries are removed).
    public var text: String
    public var category: ContextCategory
    public var required: Bool

    public init(id: UUID = UUID(), title: String, text: String, category: ContextCategory, required: Bool = false) {
        self.id = id; self.title = title; self.text = text; self.category = category; self.required = required
    }
}

/// Deterministic splitting of pasted text into context blocks.
///
/// Rules:
/// - Text is split into lines at `\n` only; every block is an exact, contiguous run of whole lines from
///   the paste. Nothing is rewritten, summarised or truncated. Only the line breaks and whitespace-only
///   lines *between* blocks are left out (and a `\r` ending a block's last line, which is part of a
///   Windows line break). The complete original is kept separately as a `PastedSource`.
/// - Fenced code (``` or ~~~, closed by a fence of the same character at least as long) is never split,
///   even across blank lines. An unclosed fence runs to the end of the paste.
/// - If the paste has Markdown headings outside code (`# …` to `###### …`, or a line underlined with
///   `===`/`---`), each heading starts a block that runs to the next heading; text before the first
///   heading is its own block.
/// - Without headings, blocks are paragraphs separated by blank lines; a fenced code block is its own block.
public enum ContextSplitter {

    public static func keepAsOneBlock(_ text: String, title: String) -> [ProposedBlock] {
        guard !text.isEmpty else { return [] }
        return [ProposedBlock(title: title, text: text, category: isOnlyCode(text) ? .code : .reference)]
    }

    public static func split(_ text: String) -> [ProposedBlock] {
        let lines = splitLines(text)
        let kinds = classify(lines)
        let headingStarts = kinds.indices.filter { kinds[$0] == .heading }
        let ranges: [ClosedRange<Int>]
        if headingStarts.isEmpty {
            ranges = paragraphRanges(kinds)
        } else {
            var bounds = headingStarts
            if let first = firstContentLine(kinds), first < headingStarts[0] { bounds.insert(first, at: 0) }
            ranges = bounds.enumerated().compactMap { index, start in
                let end = index + 1 < bounds.count ? bounds[index + 1] - 1 : lines.count - 1
                return trimmed(start...end, kinds)
            }
        }
        var paragraphNumber = 0
        return ranges.map { range in
            var blockLines = Array(lines[range])
            if let last = blockLines.last, last.hasSuffix("\r") { blockLines[blockLines.count - 1] = String(last.dropLast()) }
            let blockText = blockLines.joined(separator: "\n")
            let codeOnly = range.allSatisfy { kinds[$0] == .fence || kinds[$0] == .code }
            paragraphNumber += 1
            return ProposedBlock(title: title(for: Array(lines[range]), kinds: Array(kinds[range]), number: paragraphNumber),
                                 text: blockText, category: codeOnly ? .code : .reference)
        }
    }

    // MARK: Line classification

    enum LineKind: Equatable { case blank, text, heading, underline, fence, code }

    static func classify(_ lines: [String]) -> [LineKind] {
        var kinds = [LineKind](repeating: .text, count: lines.count)
        var openFence: (char: Character, length: Int)? = nil
        for (i, line) in lines.enumerated() {
            if let fence = openFence {
                if let closing = fenceMarker(line), closing.char == fence.char, closing.length >= fence.length, closing.infoIsEmpty {
                    kinds[i] = .fence; openFence = nil
                } else {
                    kinds[i] = .code
                }
                continue
            }
            if let opening = fenceMarker(line) {
                kinds[i] = .fence; openFence = (opening.char, opening.length); continue
            }
            if isBlank(line) { kinds[i] = .blank; continue }
            if isATXHeading(line) { kinds[i] = .heading; continue }
            kinds[i] = .text
        }
        // Setext headings: a text line directly followed by a line of only = or - (at least 3).
        for i in lines.indices.dropLast() where kinds[i] == .text && kinds[i + 1] == .text && isSetextUnderline(lines[i + 1]) {
            if i == 0 || kinds[i - 1] == .blank || kinds[i - 1] == .heading || kinds[i - 1] == .fence {
                kinds[i] = .heading; kinds[i + 1] = .underline
            }
        }
        return kinds
    }

    static func paragraphRanges(_ kinds: [LineKind]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var start: Int? = nil
        var i = 0
        func close(_ end: Int) { if let s = start, let r = trimmed(s...end, kinds) { ranges.append(r) }; start = nil }
        while i < kinds.count {
            switch kinds[i] {
            case .fence:
                // A fenced block is its own block: close any paragraph, then take the fence through its end.
                if start != nil { close(i - 1) }
                var end = i + 1
                while end < kinds.count && kinds[end] == .code { end += 1 }
                if end >= kinds.count { end = kinds.count - 1 } // unclosed: runs to the end
                ranges.append(i...end)
                i = end + 1
                continue
            case .blank:
                if start != nil { close(i - 1) }
            default:
                if start == nil { start = i }
            }
            i += 1
        }
        if start != nil { close(kinds.count - 1) }
        return ranges
    }

    static func trimmed(_ range: ClosedRange<Int>, _ kinds: [LineKind]) -> ClosedRange<Int>? {
        var lower = range.lowerBound, upper = range.upperBound
        while lower <= upper && kinds[lower] == .blank { lower += 1 }
        while upper >= lower && kinds[upper] == .blank { upper -= 1 }
        return lower <= upper ? lower...upper : nil
    }

    static func firstContentLine(_ kinds: [LineKind]) -> Int? { kinds.firstIndex { $0 != .blank } }

    /// Split at U+000A only. Works on Unicode scalars because Swift treats "\r\n" as one Character,
    /// so splitting Characters at "\n" would miss Windows line breaks. Joining the lines with "\n"
    /// reproduces the original exactly.
    static func splitLines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }

    static func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func isATXHeading(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        let rest = line.drop { $0 == " " }
        let hashes = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let after = rest.dropFirst(hashes)
        return after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r"
    }

    static func isSetextUnderline(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        let body = line.drop { $0 == " " }.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        guard body.count >= 3, let first = body.first, first == "=" || first == "-" else { return false }
        return body.allSatisfy { $0 == first }
    }

    static func fenceMarker(_ line: String) -> (char: Character, length: Int, infoIsEmpty: Bool)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard let char = rest.first, char == "`" || char == "~" else { return nil }
        let length = rest.prefix { $0 == char }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        if char == "`" && info.contains("`") { return nil }
        return (char, length, info.isEmpty)
    }

    static func isOnlyCode(_ text: String) -> Bool {
        let lines = splitLines(text)
        let kinds = classify(lines).filter { $0 != .blank }
        return !kinds.isEmpty && kinds.allSatisfy { $0 == .fence || $0 == .code }
    }

    // MARK: Titles (metadata only; block text is never changed)

    static func title(for lines: [String], kinds: [LineKind], number: Int) -> String {
        if let index = kinds.firstIndex(of: .heading) {
            let raw = lines[index].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            let text = raw.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if !cleaned.isEmpty { return shorten(cleaned) }
        }
        if kinds.first == .fence, let marker = lines.first {
            let info = marker.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r`~"))
            return info.isEmpty ? "Code \(number)" : "Code (\(shorten(info)))"
        }
        if let first = lines.first(where: { !isBlank($0) }) {
            return shorten(first.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")))
        }
        return "Part \(number)"
    }

    static func shorten(_ s: String, limit: Int = 60) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
}
