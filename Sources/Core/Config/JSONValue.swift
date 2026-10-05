import Foundation

/// A whole JSON document as a tree, with no schema attached.
///
/// The config file is edited BY HAND as much as by the app, so the app must not
/// be the arbiter of what may appear in it. A typed `Codable` struct would be:
/// decoding drops every key it has not heard of, and the next save writes the
/// file back without them — so a key written by a newer build, or by the user in
/// anticipation of one, would be silently deleted by an older build. Holding the
/// document as a tree and only ever touching the paths we know about means
/// anything else survives untouched, by construction rather than by care.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    var boolValue: Bool? {
        switch self {
        case .bool(let b):   return b
        // A hand-written file may well say 1 or "true"; refusing those would be
        // pedantry against the person the file is for.
        case .number(let n): return n != 0
        case .string(let s): return ["true", "yes", "1", "on"].contains(s.lowercased()) ? true
                                  : ["false", "no", "0", "off"].contains(s.lowercased()) ? false : nil
        default:             return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b):   return b ? 1 : 0
        case .string(let s): return Double(s)
        default:             return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        // The same guard `encode` uses. `Int(n)` TRAPS on a value past Int.max or
        // on infinity, and both are one keystroke away in a file someone types.
        case .number(let n): return (n.isFinite && n == n.rounded() && abs(n) < 1e15)
                                    ? String(Int(n)) : String(n)
        case .bool(let b):   return b ? "true" : "false"
        default:             return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }

    /// Look up a dotted path, e.g. `"popup.enabled"`. Missing or wrongly-typed
    /// intermediates return nil rather than throwing — an absent setting is a
    /// normal state, not an error.
    subscript(path path: String) -> JSONValue? {
        var current = self
        for key in path.split(separator: ".") {
            guard let object = current.objectValue, let next = object[String(key)] else { return nil }
            current = next
        }
        return current
    }

    /// Write a dotted path, creating intermediate objects as needed. An
    /// intermediate that exists but is NOT an object is replaced — the
    /// alternative is failing silently, which in a hand-edited file means the
    /// setting you just changed in the UI appears not to stick.
    mutating func set(path: String, to value: JSONValue) {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty else { return }
        self = Self.setting(self, keys: keys[...], to: value)
    }

    /// Delete a dotted path. Used ONLY for a key the app knows it has retired:
    /// an unrecognized key is preserved on purpose, so removing one has to be a
    /// decision someone wrote down, never a side effect.
    @discardableResult
    mutating func remove(path: String) -> Bool {
        let keys = path.split(separator: ".").map(String.init)
        guard let last = keys.last else { return false }
        let parentPath = keys.dropLast().joined(separator: ".")
        let parent = parentPath.isEmpty ? self : self[path: parentPath]
        guard var object = parent?.objectValue, object[last] != nil else { return false }
        object[last] = nil
        if parentPath.isEmpty { self = .object(object) }
        else { set(path: parentPath, to: .object(object)) }
        return true
    }

    private static func setting(_ node: JSONValue, keys: ArraySlice<String>, to value: JSONValue) -> JSONValue {
        guard let key = keys.first else { return value }
        var object = node.objectValue ?? [:]
        let child = object[key] ?? .object([:])
        object[key] = setting(child, keys: keys.dropFirst(), to: value)
        return .object(object)
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:          try container.encodeNil()
        case .bool(let b):   try container.encode(b)
        // Whole numbers encode as integers: a config file that reads `"radius": 116`
        // rather than `116.0` is the one a person would have written.
        case .number(let n): if n == n.rounded() && abs(n) < 1e15 { try container.encode(Int(n)) }
                             else { try container.encode(n) }
        case .string(let s): try container.encode(s)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Literals (so call sites read like the JSON they produce)

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

// MARK: - Any key

/// A `CodingKey` that accepts whatever string it is given.
///
/// This is how a type reads the keys it has never heard of: ask for a container
/// keyed by this, subtract the keys the type knows, and keep the rest. Without it
/// a `Codable` type can only ever see its own fields, and everything else in the
/// object is gone the moment it is re-encoded.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) { stringValue = string; intValue = nil }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
