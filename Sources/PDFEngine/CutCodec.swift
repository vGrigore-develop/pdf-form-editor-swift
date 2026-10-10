import Foundation
import VoucherModel
import VoucherGeometry

/// PDF encodings of an outline: the clip path operators (SPEC 5.2) and the
/// re-editable `/Segments` form stored in `/PieceInfo` (SPEC 5.4).
public enum CutCodec {
    public static let marker = "% VoucherEditor cut v1"
    public static let xobjectName = "VEOrig"

    private static func f(_ v: Double) -> String { PDFSyntax.number(v) }

    /// `x y m ... l/c ... h`, arcs as cubics of at most 90 degrees. `map` takes every point
    /// to another coordinate space (a widget's form space for the field crop); it must be
    /// affine, which keeps the Béziers exact.
    public static func pathOperators(_ o: Outline, map: (PDFPoint) -> PDFPoint = { $0 }) -> String {
        func pt(_ p: PDFPoint) -> String { let q = map(p); return "\(f(q.x)) \(f(q.y))" }
        var ops = ["\(pt(o.start)) m"]
        var cur = o.start
        for s in o.segments {
            switch s {
            case .line(let p):
                ops.append("\(pt(p)) l")
            case .curve(let c1, let c2, let p):
                ops.append("\(pt(c1)) \(pt(c2)) \(pt(p)) c")
            case .arc(let p, let c, let cw):
                for b in Geometry.arcToBeziers(from: cur, to: p, center: c, clockwise: cw) {
                    ops.append("\(pt(b.c1)) \(pt(b.c2)) \(pt(b.to)) c")
                }
            }
            cur = s.end
        }
        ops.append("h")
        return ops.joined(separator: "\n")
    }

    public static func wrapStartStream(_ o: Outline) -> Data {
        Data((marker + "\nq\n" + pathOperators(o) + "\nW n\nq\n").utf8)
    }

    public static func xobjectStartStream(_ o: Outline) -> Data {
        Data((marker + "\nq\n" + pathOperators(o) + "\nW n\n/\(xobjectName) Do\nQ\n").utf8)
    }

    public static var endStream: Data { Data((marker + "\nQ\nQ\n").utf8) }

    public static func startValue(_ o: Outline) -> PDFValue { .array([.real(o.start.x), .real(o.start.y)]) }

    public static func segmentsValue(_ o: Outline) -> PDFValue {
        .array(o.segments.map { s in
            switch s {
            case .line(let p): return .array([.name("L"), .real(p.x), .real(p.y)])
            case .arc(let p, let c, let cw): return .array([.name("A"), .real(p.x), .real(p.y), .real(c.x), .real(c.y), .name(cw ? "CW" : "CCW")])
            case .curve(let a, let b, let p): return .array([.name("C"), .real(a.x), .real(a.y), .real(b.x), .real(b.y), .real(p.x), .real(p.y)])
            }
        })
    }

    public static func outline(start: PDFValue, segments: PDFValue) -> Outline? {
        guard let s = start.numbers, s.count == 2, let items = segments.array else { return nil }
        var segs: [Segment] = []
        for item in items {
            guard let a = item.array, let kind = a.first?.name else { return nil }
            let nums = a.dropFirst().compactMap(\.number)
            switch kind {
            case "L" where nums.count >= 2: segs.append(.line(to: PDFPoint(nums[0], nums[1])))
            case "C" where nums.count >= 6:
                segs.append(.curve(c1: PDFPoint(nums[0], nums[1]), c2: PDFPoint(nums[2], nums[3]), to: PDFPoint(nums[4], nums[5])))
            case "A" where nums.count >= 4:
                let cw = a.last?.name == "CW"
                segs.append(.arc(to: PDFPoint(nums[0], nums[1]), center: PDFPoint(nums[2], nums[3]), clockwise: cw))
            default: return nil
            }
        }
        return Outline(start: PDFPoint(s[0], s[1]), segments: segs)
    }

    /// Rebuild an outline (lines and curves) from a cutStart stream when /PieceInfo is missing (SPEC 5.4).
    public static func outline(fromStartStream data: Data) -> Outline? {
        guard let text = String(data: data, encoding: .isoLatin1), text.hasPrefix(marker) else { return nil }
        var nums: [Double] = []
        var start: PDFPoint?
        var segs: [Segment] = []
        for t in text.dropFirst(marker.count).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }) {
            switch t {
            case "m": if nums.count >= 2 { start = PDFPoint(nums[0], nums[1]) }; nums = []
            case "l": if nums.count >= 2 { segs.append(.line(to: PDFPoint(nums[0], nums[1]))) }; nums = []
            case "c":
                if nums.count >= 6 { segs.append(.curve(c1: PDFPoint(nums[0], nums[1]), c2: PDFPoint(nums[2], nums[3]), to: PDFPoint(nums[4], nums[5]))) }
                nums = []
            case "h": return start.map { Outline(start: $0, segments: segs) }
            default:
                if let v = Double(t) { nums.append(v) } else { nums = [] }
            }
        }
        return nil
    }
}
