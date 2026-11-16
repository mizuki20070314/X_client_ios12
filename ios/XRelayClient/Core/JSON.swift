import Foundation

/// Tolerant reader over JSONSerialization output. Missing keys, nulls and wrong types give nil or empty
/// values instead of errors, so one unexpected field cannot lose a whole timeline.
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw
    }

    /// raw is nil when the data is not JSON.
    init(data: Data) {
        self.raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    subscript(key: String) -> JSON {
        guard let dictionary = raw as? [String: Any] else { return JSON(nil) }
        return JSON(dictionary[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    /// Keys documented as nullable are always present with null; that is "does not exist" here.
    var exists: Bool {
        guard let raw = raw else { return false }
        return !(raw is NSNull)
    }

    var string: String? {
        return raw as? String
    }

    /// Accepts a numeric string too, because some counts arrive as strings.
    var int: Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    var double: Double? {
        if let value = raw as? Double { return value }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    var bool: Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    var array: [JSON] {
        guard let array = raw as? [Any] else { return [] }
        return array.map { JSON($0) }
    }

    var dictionary: [String: Any]? {
        return raw as? [String: Any]
    }
}
