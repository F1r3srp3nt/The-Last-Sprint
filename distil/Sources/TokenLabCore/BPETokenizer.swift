import Foundation

/// Byte-pair-encoding vocabularies this app can count with. The vocabulary files are NOT bundled:
/// the user imports an official copy, which is accepted only if its SHA-256 matches the published value.
public enum BPEEncodingID: String, Codable, CaseIterable, Identifiable, Sendable {
    case cl100k_base
    case o200k_base
    public var id: String { rawValue }
    public var spec: BPEEncodingSpec { BPEEncodingSpec.forID(self) }
}

/// Facts about an encoding, transcribed from the open-source (MIT) tiktoken project, version 0.14.0:
/// `tiktoken_ext/openai_public.py` (pattern, file URL, expected hash) and `tiktoken/model.py` (model mapping).
public struct BPEEncodingSpec: Sendable {
    public let id: BPEEncodingID
    /// Pre-tokenisation pattern, rewritten for ICU (NSRegularExpression): `\s`/`\S` are expressed as
    /// `\p{White_Space}`/`\P{White_Space}` to match the Unicode semantics of the reference implementation.
    public let pattern: String
    public let expectedSHA256: String
    public let expectedRankCount: Int
    public let officialFileURL: String
    public let modelFamilies: [String]
    public let referenceVersion = "tiktoken 0.14.0 definitions"

    public static func forID(_ id: BPEEncodingID) -> BPEEncodingSpec {
        switch id {
        case .cl100k_base:
            return BPEEncodingSpec(
                id: id,
                pattern: #"'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}++|\p{N}{1,3}+| ?[^\p{White_Space}\p{L}\p{N}]++[\r\n]*+|\p{White_Space}++$|\p{White_Space}*[\r\n]|\p{White_Space}+(?!\P{White_Space})|\p{White_Space}"#,
                expectedSHA256: "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7",
                expectedRankCount: 100_256,
                officialFileURL: "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken",
                modelFamilies: ["gpt-4", "gpt-3.5-turbo", "text-embedding-3-small", "text-embedding-3-large", "text-embedding-ada-002"])
        case .o200k_base:
            let parts = [
                #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
                #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
                #"\p{N}{1,3}"#,
                #" ?[^\p{White_Space}\p{L}\p{N}]+[\r\n/]*"#,
                #"\p{White_Space}*[\r\n]+"#,
                #"\p{White_Space}+(?!\P{White_Space})"#,
                #"\p{White_Space}+"#
            ]
            return BPEEncodingSpec(
                id: id,
                pattern: parts.joined(separator: "|"),
                expectedSHA256: "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d",
                expectedRankCount: 199_998,
                officialFileURL: "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken",
                modelFamilies: ["gpt-4o", "gpt-4.1", "gpt-4.5", "gpt-5", "o1", "o3", "o4-mini"])
        }
    }

    public var fileName: String { "\(id.rawValue).tiktoken" }
}

/// Tiktoken-compatible byte-pair encoder written for this project (no third-party code).
/// Counts plain text the way `Encoding.encode_ordinary` does: special-token strings are treated as text,
/// and chat message formatting is not added.
public final class BPETokenizer: TokenCounter, @unchecked Sendable {
    public static let implementationVersion = "tokenlab-bpe-1"
    public let descriptor: TokenCounterDescriptor
    public let rankCount: Int

    private let ranks: [[UInt8]: Int]
    private let regex: NSRegularExpression
    private let lock = NSLock()
    /// Keyed by UTF-8 bytes, not `String`: Swift string equality is canonical, so "é" and "e\u{301}"
    /// would otherwise share an entry even though they tokenize differently.
    private var pieceCache: [[UInt8]: Int] = [:]
    private static let pieceCacheLimit = 200_000

    /// Load an official encoding file. Fails unless the SHA-256 matches the published value.
    public convenience init(spec: BPEEncodingSpec, fileData: Data) throws {
        let digest = SHA256Digest.hex(fileData)
        guard digest == spec.expectedSHA256 else {
            throw LabError.invalid("This file is not the official \(spec.id.rawValue) encoding. Expected SHA-256 \(spec.expectedSHA256), found \(digest).")
        }
        let ranks = try Self.parseRanks(fileData)
        guard ranks.count == spec.expectedRankCount else {
            throw LabError.invalid("Expected \(spec.expectedRankCount) entries in \(spec.fileName), found \(ranks.count).")
        }
        let descriptor = TokenCounterDescriptor(
            id: "bpe:\(spec.id.rawValue)",
            displayName: "\(spec.id.rawValue) text tokens",
            kind: .modelTokenizer,
            encoding: spec.id.rawValue,
            version: "\(Self.implementationVersion); ranks-sha256=\(digest.prefix(16)); \(spec.referenceVersion)",
            scope: "Text tokens of the prompt string only (as encode_ordinary). Excludes chat message formatting, role markers, tool definitions and any provider-side overhead, so it is not provider-reported usage.")
        try self.init(ranks: ranks, pattern: spec.pattern, descriptor: descriptor)
    }

    /// Lower-level initialiser, used directly by tests with small synthetic vocabularies.
    public init(ranks: [[UInt8]: Int], pattern: String, descriptor: TokenCounterDescriptor) throws {
        for byte in 0...255 where ranks[[UInt8(byte)]] == nil {
            throw LabError.invalid("Encoding is incomplete: single byte \(byte) has no rank.")
        }
        do { regex = try NSRegularExpression(pattern: pattern) }
        catch { throw LabError.invalid("Tokenizer pattern could not be compiled: \(error.localizedDescription)") }
        self.ranks = ranks
        self.rankCount = ranks.count
        self.descriptor = descriptor
    }

    /// Parse `<base64 token> <rank>` lines.
    public static func parseRanks(_ data: Data) throws -> [[UInt8]: Int] {
        var ranks: [[UInt8]: Int] = [:]
        var seenRanks = Set<Int>()
        var lineNumber = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            lineNumber += 1
            guard let space = line.firstIndex(of: UInt8(ascii: " ")),
                  let token = Data(base64Encoded: Data(line[line.startIndex..<space])),
                  let rankText = String(data: Data(line[line.index(after: space)...]), encoding: .ascii),
                  let rank = Int(rankText.trimmingCharacters(in: .whitespacesAndNewlines)), rank >= 0,
                  !token.isEmpty else {
                throw LabError.malformed("Encoding line \(lineNumber) is not \"<base64> <rank>\".")
            }
            let bytes = [UInt8](token)
            guard ranks[bytes] == nil, seenRanks.insert(rank).inserted else {
                throw LabError.malformed("Encoding line \(lineNumber) duplicates an existing token or rank.")
            }
            ranks[bytes] = rank
        }
        guard !ranks.isEmpty else { throw LabError.malformed("The encoding file is empty.") }
        return ranks
    }

    // MARK: Counting

    public func count(_ text: String) -> Int {
        var total = 0
        forEachPiece(text) { piece in total += self.cachedCount(piece) }
        return total
    }

    /// Token ranks, as `encode_ordinary` would return them. Used to verify against reference output.
    public func encode(_ text: String) -> [Int] {
        var output: [Int] = []
        forEachPiece(text) { piece in
            let bytes = Array(piece.utf8)
            if let rank = self.ranks[bytes] { output.append(rank); return }
            let bounds = self.bytePairMerge(bytes)
            for i in 0..<(bounds.count - 1) {
                output.append(self.ranks[Array(bytes[bounds[i]..<bounds[i + 1]])]!)
            }
        }
        return output
    }

    private func forEachPiece(_ text: String, _ body: (String) -> Void) {
        guard !text.isEmpty else { return }
        let ns = NSString(string: text)
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
            body(ns.substring(with: match.range))
        }
    }

    private func cachedCount(_ piece: String) -> Int {
        let bytes = Array(piece.utf8)
        lock.lock()
        if let cached = pieceCache[bytes] { lock.unlock(); return cached }
        lock.unlock()
        let result = ranks[bytes] != nil ? 1 : bytePairMerge(bytes).count - 1
        lock.lock()
        if pieceCache.count >= Self.pieceCacheLimit { pieceCache.removeAll(keepingCapacity: true) }
        pieceCache[bytes] = result
        lock.unlock()
        return result
    }

    private func rank(_ piece: [UInt8], _ start: Int, _ end: Int) -> Int {
        ranks[Array(piece[start..<end])] ?? Int.max
    }

    /// Port of the reference merge loop: repeatedly merge the adjacent pair with the lowest rank,
    /// preferring the leftmost pair on ties. Returns token boundaries (count = tokens + 1).
    func bytePairMerge(_ piece: [UInt8]) -> [Int] {
        if piece.count < 2 { return [0, piece.count] }
        var starts: [Int] = []
        var pairRanks: [Int] = []
        starts.reserveCapacity(piece.count + 1); pairRanks.reserveCapacity(piece.count + 1)
        var minRank = Int.max, minIndex = Int.max
        for i in 0..<(piece.count - 1) {
            let r = rank(piece, i, i + 2)
            if r < minRank { minRank = r; minIndex = i }
            starts.append(i); pairRanks.append(r)
        }
        starts.append(piece.count - 1); pairRanks.append(Int.max)
        starts.append(piece.count); pairRanks.append(Int.max)

        while minRank != Int.max {
            let i = minIndex
            // Rank of the part that would result from merging i with the part after the one being removed.
            if i > 0 {
                let r = i + 2 < starts.count ? rank(piece, starts[i - 1], starts[i + 2]) : Int.max
                pairRanks[i - 1] = r
            }
            let r = i + 3 < starts.count ? rank(piece, starts[i], starts[i + 3]) : Int.max
            pairRanks[i] = r
            starts.remove(at: i + 1); pairRanks.remove(at: i + 1)

            minRank = Int.max; minIndex = Int.max
            for j in 0..<(pairRanks.count - 1) where pairRanks[j] < minRank {
                minRank = pairRanks[j]; minIndex = j
            }
        }
        return starts
    }
}
