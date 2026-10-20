import Foundation

/// On speakers, the mic hears the other side, so my lines repeat theirs. This
/// removes from one of my lines every run of words that repeats, in order, a
/// line of theirs from around the same time, and drops the line if hardly
/// anything of mine is left. It works on text only: no model, no audio
/// processing, no volume cost.
public struct EchoFilter: Sendable {
    /// How far apart (seconds) their line and mine can be and still count.
    public var window: TimeInterval = 10
    /// The fewest matching words in a row that count as an echo.
    public var minimumRun = 3
    /// Below this many of my own words, the whole line is dropped.
    public var minimumWordsLeft = 2

    public init() {}

    /// My line with the echoed words removed (same id and times), the line
    /// unchanged if nothing was echoed, or nil if nothing of mine is left.
    public func clean(_ mine: Utterance, against others: [Utterance]) -> Utterance? {
        let tokens = mine.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = tokens.map(Self.normalize)
        var echoed = Array(repeating: false, count: tokens.count)

        for theirs in others where theirs.speaker == .them
            && theirs.start <= mine.end + window
            && theirs.end >= mine.start - window {
            let theirWords = theirs.text.split(whereSeparator: \.isWhitespace)
                .map { Self.normalize(String($0)) }
                .filter { !$0.isEmpty }
            for run in Self.matchingRuns(words, theirWords, minimumLength: minimumRun) {
                for i in run { echoed[i] = true }
            }
        }

        guard echoed.contains(true) else { return mine }
        let kept = tokens.indices.filter { !echoed[$0] }
        let wordsLeft = kept.filter { !words[$0].isEmpty }.count
        guard wordsLeft >= minimumWordsLeft else { return nil }
        return Utterance(
            id: mine.id,
            speaker: mine.speaker,
            text: kept.map { tokens[$0] }.joined(separator: " "),
            start: mine.start,
            end: mine.end
        )
    }

    /// Lowercased letters and digits only ("Invalidation?" → "invalidation").
    static func normalize(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Recognition of the same word differs a little between the two channels
    /// ("cashing" / "caching"), so longer words may differ by an edit or two.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        let allowed = max(a.count, b.count) >= 7 ? 2 : 1
        return editDistance(a, b) <= allowed
    }

    /// Ranges of indices into `mine` that repeat `theirs` in order: the longest
    /// common word sequence, split into runs where neither side skips more
    /// than one word, keeping runs of at least `minimumLength` matches. A
    /// skipped word inside a run ("two" against "2") counts as part of it.
    static func matchingRuns(_ mine: [String], _ theirs: [String], minimumLength: Int) -> [ClosedRange<Int>] {
        let n = mine.count, m = theirs.count
        guard n > 0, m > 0 else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = !mine[i].isEmpty && similar(mine[i], theirs[j])
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(i: Int, j: Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if !mine[i].isEmpty && similar(mine[i], theirs[j]) && lengths[i][j] == lengths[i + 1][j + 1] + 1 {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var runs: [ClosedRange<Int>] = []
        var runStart = 0
        for k in pairs.indices {
            let continues = k > 0 && pairs[k].i - pairs[k - 1].i <= 2 && pairs[k].j - pairs[k - 1].j <= 2
            if !continues { runStart = k }
            let endsHere = k == pairs.count - 1
                || pairs[k + 1].i - pairs[k].i > 2 || pairs[k + 1].j - pairs[k].j > 2
            if endsHere && k - runStart + 1 >= minimumLength {
                runs.append(pairs[runStart].i...pairs[k].i)
            }
        }
        return runs
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
