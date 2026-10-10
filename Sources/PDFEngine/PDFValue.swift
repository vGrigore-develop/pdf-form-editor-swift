import Foundation

/// A PDF object value as exchanged with the engine (PDF syntax in, PDF syntax out).
public indirect enum PDFValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)
    case string(Data)
    case array([PDFValue])
    case dict([String: PDFValue])
    case ref(Int, Int)

    // MARK: Accessors

    public subscript(key: String) -> PDFValue {
        if case .dict(let d) = self { return d[key] ?? .null }
        return .null
    }

    public var isNull: Bool { self == .null }
    public var dict: [String: PDFValue]? { if case .dict(let d) = self { return d }; return nil }
    public var array: [PDFValue]? { if case .array(let a) = self { return a }; return nil }
    public var name: String? { if case .name(let n) = self { return n }; return nil }
    public var refNumber: Int? { if case .ref(let n, _) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var stringData: Data? { if case .string(let d) = self { return d }; return nil }

    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .real(let r): return Int(r)
        default: return nil
        }
    }

    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .real(let r): return r
        default: return nil
        }
    }

    public var numbers: [Double]? {
        guard let a = array else { return nil }
        let n = a.compactMap(\.number)
        return n.count == a.count ? n : nil
    }

    /// Text string decoding (ISO 32000 7.9.2.2): UTF-16BE with BOM, UTF-8 with BOM, else PDFDocEncoding.
    public var text: String? {
        guard let d = stringData else { return nil }
        return PDFText.decode(d)
    }

    // MARK: Serialisation

    public var syntax: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .real(let r): return PDFSyntax.number(r)
        case .name(let n): return "/" + PDFSyntax.escapeName(n)
        case .string(let d): return PDFSyntax.stringLiteral(d)
        case .array(let a): return "[" + a.map(\.syntax).joined(separator: " ") + "]"
        case .dict(let d):
            return "<<" + d.keys.sorted().map { "/\(PDFSyntax.escapeName($0)) \(d[$0]!.syntax)" }.joined(separator: " ") + ">>"
        case .ref(let n, let g): return "\(n) \(g) R"
        }
    }

    public static func text(_ s: String) -> PDFValue { .string(PDFText.encode(s)) }
    public static func numbers(_ v: [Double]) -> PDFValue { .array(v.map { .real($0) }) }
}

public enum PDFText {
    /// ASCII stays single-byte; anything else is written as UTF-16BE with a BOM (SPEC 7.6).
    public static func encode(_ s: String) -> Data {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return Data(s.utf8) }
        var d = Data([0xFE, 0xFF])
        for u in s.utf16 { d.append(UInt8(u >> 8)); d.append(UInt8(u & 0xFF)) }
        return d
    }

    public static func decode(_ d: Data) -> String {
        let b = [UInt8](d)
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF {
            var units: [UInt16] = []
            var i = 2
            while i + 1 < b.count { units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
            return String(decoding: b.dropFirst(3), as: UTF8.self)
        }
        return String(String.UnicodeScalarView(b.map { pdfDocEncoding($0) }))
    }

    private static let high: [UInt32] = [
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203A, 0x2212, 0x2030,
        0x201E, 0x201C, 0x201D, 0x2018, 0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160,
        0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0xFFFD,
    ]

    private static func pdfDocEncoding(_ c: UInt8) -> Unicode.Scalar {
        if c >= 0x80 && c <= 0x9F { return Unicode.Scalar(high[Int(c - 0x80)])! }
        if c == 0xA0 { return Unicode.Scalar(0x20AC)! }
        return Unicode.Scalar(c)
    }
}

public enum PDFSyntax {
    public static func number(_ v: Double) -> String {
        if !v.isFinite { return "0" }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return (s == "-0" || s.isEmpty) ? "0" : s
    }

    static let delimiters: Set<UInt8> = Set("()<>[]{}/%#".utf8)

    public static func escapeName(_ n: String) -> String {
        var out = ""
        for b in n.utf8 {
            if b < 0x21 || b > 0x7E || delimiters.contains(b) {
                out += String(format: "#%02X", b)
            } else {
                out.append(Character(Unicode.Scalar(b)))
            }
        }
        return out
    }

    /// Literal string for printable ASCII, hex string otherwise.
    public static func stringLiteral(_ d: Data) -> String {
        let printable = d.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) }
        if printable {
            var s = "("
            for b in d {
                switch b {
                case 0x28: s += "\\("
                case 0x29: s += "\\)"
                case 0x5C: s += "\\\\"
                default: s.append(Character(Unicode.Scalar(b)))
                }
            }
            return s + ")"
        }
        return "<" + d.map { String(format: "%02X", $0) }.joined() + ">"
    }
}

// MARK: - Parser

public struct PDFParseError: Error, CustomStringConvertible {
    public var description: String
}

/// Parser for PDF object syntax as printed by MuPDF (`pdf_sprint_obj`, tight).
public struct PDFParser {
    private let b: [UInt8]
    private var i = 0

    public static func parse(_ s: String) throws -> PDFValue {
        var p = PDFParser(bytes: Array(s.utf8))
        let v = try p.value()
        return v
    }

    init(bytes: [UInt8]) { b = bytes }

    private static let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x00]

    private mutating func skipWS() {
        while i < b.count {
            if PDFParser.ws.contains(b[i]) { i += 1 }
            else if b[i] == 0x25 { while i < b.count && b[i] != 0x0A && b[i] != 0x0D { i += 1 } } // comment
            else { break }
        }
    }

    private func isRegular(_ c: UInt8) -> Bool { !PDFParser.ws.contains(c) && !PDFSyntax.delimiters.contains(c) }

    private mutating func token() -> String {
        let s = i
        while i < b.count && isRegular(b[i]) { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }

    mutating func value() throws -> PDFValue {
        skipWS()
        guard i < b.count else { throw PDFParseError(description: "unexpected end") }
        let c = b[i]
        switch c {
        case UInt8(ascii: "/"):
            i += 1
            let s = i
            while i < b.count && isRegular(b[i]) || (i < b.count && b[i] == UInt8(ascii: "#")) { i += 1 }
            return .name(PDFParser.unescapeName(Array(b[s..<i])))
        case UInt8(ascii: "("):
            return .string(try literalString())
        case UInt8(ascii: "<"):
            if i + 1 < b.count && b[i + 1] == UInt8(ascii: "<") {
                i += 2
                var d: [String: PDFValue] = [:]
                while true {
                    skipWS()
                    guard i < b.count else { throw PDFParseError(description: "unterminated dict") }
                    if b[i] == UInt8(ascii: ">") { i += 2; break }
                    guard case .name(let k) = try value() else { throw PDFParseError(description: "dict key is not a name") }
                    d[k] = try value()
                }
                return .dict(d)
            }
            i += 1
            var hex: [UInt8] = []
            while i < b.count && b[i] != UInt8(ascii: ">") {
                if !PDFParser.ws.contains(b[i]) { hex.append(b[i]) }
                i += 1
            }
            i += 1
            if hex.count % 2 == 1 { hex.append(UInt8(ascii: "0")) }
            var out = Data()
            var j = 0
            while j < hex.count {
                out.append(UInt8(String(decoding: hex[j..<j + 2], as: UTF8.self), radix: 16) ?? 0)
                j += 2
            }
            return .string(out)
        case UInt8(ascii: "["):
            i += 1
            var a: [PDFValue] = []
            while true {
                skipWS()
                guard i < b.count else { throw PDFParseError(description: "unterminated array") }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                a.append(try value())
            }
            return .array(a)
        default:
            let t = token()
            if t.isEmpty { i += 1; throw PDFParseError(description: "unexpected character \(Character(Unicode.Scalar(c)))") }
            switch t {
            case "null": return .null
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            if let n = Int(t) {
                // Look ahead for "gen R".
                let save = i
                skipWS()
                let g = token()
                if let gen = Int(g) {
                    skipWS()
                    if i < b.count && b[i] == UInt8(ascii: "R") && (i + 1 == b.count || !isRegular(b[i + 1])) {
                        i += 1
                        return .ref(n, gen)
                    }
                }
                i = save
                return .int(n)
            }
            if let r = Double(t) { return .real(r) }
            if t.hasPrefix(".") || t.hasPrefix("-.") , let r = Double(t.replacingOccurrences(of: ".", with: "0.", options: .anchored)) { return .real(r) }
            throw PDFParseError(description: "unknown token \(t)")
        }
    }

    private mutating func literalString() throws -> Data {
        i += 1
        var out = Data()
        var depth = 1
        while i < b.count {
            let c = b[i]
            if c == 0x5C {
                i += 1
                guard i < b.count else { break }
                let e = b[i]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A); i += 1
                case UInt8(ascii: "r"): out.append(0x0D); i += 1
                case UInt8(ascii: "t"): out.append(0x09); i += 1
                case UInt8(ascii: "b"): out.append(0x08); i += 1
                case UInt8(ascii: "f"): out.append(0x0C); i += 1
                case UInt8(ascii: "("), UInt8(ascii: ")"), 0x5C: out.append(e); i += 1
                case 0x0D:
                    i += 1
                    if i < b.count && b[i] == 0x0A { i += 1 }
                case 0x0A: i += 1
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var v = 0, n = 0
                    while n < 3 && i < b.count && (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(b[i]) {
                        v = v * 8 + Int(b[i] - UInt8(ascii: "0")); i += 1; n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                default: out.append(e); i += 1
                }
                continue
            }
            if c == UInt8(ascii: "(") { depth += 1 }
            if c == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { i += 1; return out }
            }
            out.append(c)
            i += 1
        }
        throw PDFParseError(description: "unterminated string")
    }

    static func unescapeName(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var j = 0
        while j < bytes.count {
            if bytes[j] == UInt8(ascii: "#"), j + 2 < bytes.count,
               let v = UInt8(String(decoding: bytes[(j + 1)...(j + 2)], as: UTF8.self), radix: 16) {
                out.append(v); j += 3
            } else {
                out.append(bytes[j]); j += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
