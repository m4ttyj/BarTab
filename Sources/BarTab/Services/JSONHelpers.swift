import Foundation

/// Tiny read-only wrapper over `JSONSerialization` output.
///
/// brew's JSON is loosely typed (`caveats` is a string or null, cask `name` is an
/// array, `artifacts` is a heterogeneous array of single-key objects), so digging
/// through `Any` is less friction here than a pile of custom `Decodable` inits.
struct JSONValue {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    subscript(key: String) -> JSONValue {
        JSONValue((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSONValue {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSONValue(nil) }
        return JSONValue(array[index])
    }

    var array: [JSONValue] { (raw as? [Any])?.map(JSONValue.init) ?? [] }
    var string: String? {
        if let s = raw as? String { return s }
        return nil
    }
    var nonEmptyString: String? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
    var stringArray: [String] { (raw as? [Any])?.compactMap { $0 as? String } ?? [] }
    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s.replacingOccurrences(of: ",", with: "")) }
        return nil
    }
    var double: Double? { (raw as? NSNumber)?.doubleValue }
    var bool: Bool { (raw as? NSNumber)?.boolValue ?? false }
    var isNull: Bool { raw == nil || raw is NSNull }

    static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(try JSONSerialization.jsonObject(with: data, options: []))
    }
}
