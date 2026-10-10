import Foundation

/// Field naming rules (SPEC 6.1): unique, non-empty, stable; suggested pattern
/// `[a-z][a-z0-9_]*`; no dots in new names (dots create hierarchy).
public enum Naming {
    public enum Problem: Equatable, Sendable {
        case empty
        case containsDot
        case containsSpace
        case nonASCII
        case notSnakeCase

        public var isError: Bool { self == .empty || self == .containsDot }

        public var message: String {
            switch self {
            case .empty: return "Name is empty."
            case .containsDot: return "Dots create a field hierarchy (a.b); new names cannot contain dots."
            case .containsSpace: return "Name contains spaces; code that addresses fields by name is easier with snake_case."
            case .nonASCII: return "Name contains non-ASCII characters; some filling libraries mangle them."
            case .notSnakeCase: return "Suggested pattern is snake_case: [a-z][a-z0-9_]*."
            }
        }
    }

    public static func problems(for name: String, isNew: Bool = true) -> [Problem] {
        if name.isEmpty { return [.empty] }
        var out: [Problem] = []
        if name.contains(".") && isNew { out.append(.containsDot) }
        if name.contains(" ") { out.append(.containsSpace) }
        if name.unicodeScalars.contains(where: { !$0.isASCII }) { out.append(.nonASCII) }
        if !isSnakeCase(name) && !out.contains(.containsSpace) && !out.contains(.nonASCII) { out.append(.notSnakeCase) }
        return out
    }

    public static func isSnakeCase(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// First free name `base_1`, `base_2`, ... (or `base` itself if free).
    public static func uniqueName(base: String, existing: Set<String>, startAtOne: Bool = true) -> String {
        if !startAtOne && !existing.contains(base) { return base }
        var i = 1
        while existing.contains("\(base)_\(i)") { i += 1 }
        return "\(base)_\(i)"
    }

    /// Name for a duplicate (SPEC 4: suffixed `_2`, then `_3`, ...).
    public static func duplicateName(of name: String, existing: Set<String>) -> String {
        var stem = name
        // foo_2 duplicates to foo_3, not foo_2_2
        if let r = name.range(of: #"_(\d+)$"#, options: .regularExpression), let n = Int(name[r].dropFirst()), n >= 2 {
            stem = String(name[..<r.lowerBound])
        }
        var i = 2
        while existing.contains("\(stem)_\(i)") { i += 1 }
        return "\(stem)_\(i)"
    }
}
