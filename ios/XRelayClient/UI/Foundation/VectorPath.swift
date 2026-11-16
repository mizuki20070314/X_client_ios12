import UIKit

/// Parser for the path data written by tools/build_icons.py: absolute M, L, C and Z,
/// separated by spaces. Extra spaces are fine; anything unknown is skipped.
enum VectorPath {
    static func bezierPath(_ data: String) -> UIBezierPath {
        let path = UIBezierPath()
        var command: Character = "M"
        var values: [CGFloat] = []
        let separators: Set<Character> = [" ", "\n", "\t", "\r"]
        for token in data.split(whereSeparator: { separators.contains($0) }) {
            guard let first = token.first else { continue }
            if first.isLetter {
                command = first
                values.removeAll()
                if first == "Z" || first == "z" {
                    path.close()
                }
                continue
            }
            guard let number = Double(String(token)) else { continue }
            values.append(CGFloat(number))
            switch command {
            case "M":
                if values.count == 2 {
                    path.move(to: CGPoint(x: values[0], y: values[1]))
                    values.removeAll()
                    command = "L"  // pairs after a moveto are linetos
                }
            case "L":
                if values.count == 2 {
                    path.addLine(to: CGPoint(x: values[0], y: values[1]))
                    values.removeAll()
                }
            case "C":
                if values.count == 6 {
                    path.addCurve(to: CGPoint(x: values[4], y: values[5]),
                                  controlPoint1: CGPoint(x: values[0], y: values[1]),
                                  controlPoint2: CGPoint(x: values[2], y: values[3]))
                    values.removeAll()
                }
            default:
                values.removeAll()
            }
        }
        return path
    }
}
