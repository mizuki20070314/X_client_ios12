import Foundation

/// X's post length rules: a post is at most 280 weighted characters, and every URL counts 23 whatever its length.
enum TwitterText {
    static let limit = 280
    static let urlLength = 23

    static func weightedLength(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        var total = 0
        var index = 0
        while index < scalars.count {
            if let end = urlEnd(in: scalars, from: index) {
                total += urlLength
                index = end
                continue
            }
            total += weight(of: scalars[index])
            index += 1
        }
        return total
    }

    /// One for the ranges X counts as a single character (Latin, punctuation, some symbols), two for the rest.
    private static func weight(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value <= 0x10FF { return 1 }
        if (0x2000...0x200D).contains(value) { return 1 }
        if (0x2010...0x201F).contains(value) { return 1 }
        if (0x2032...0x2037).contains(value) { return 1 }
        return 2
    }

    /// The end (exclusive) of a URL starting at `start`: up to the next whitespace. nil when no URL starts there.
    private static func urlEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let scheme: String
        if hasPrefix(scalars, at: start, "https://") {
            scheme = "https://"
        } else if hasPrefix(scalars, at: start, "http://") {
            scheme = "http://"
        } else {
            return nil
        }
        var index = start + scheme.unicodeScalars.count
        while index < scalars.count && !CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
            index += 1
        }
        return index
    }

    private static func hasPrefix(_ scalars: [Unicode.Scalar], at start: Int, _ prefix: String) -> Bool {
        var index = start
        for expected in prefix.unicodeScalars {
            guard index < scalars.count, scalars[index] == expected else { return false }
            index += 1
        }
        return true
    }
}
