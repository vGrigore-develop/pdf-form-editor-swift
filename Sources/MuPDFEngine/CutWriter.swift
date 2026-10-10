import Foundation
import PDFEngine
import VoucherModel

/// The shape cut (SPEC 5.2-5.4), ported from spikes/cut.py with the S5 findings:
/// `/OrigContents` is always stored (exact reversal), XObject mode also stores
/// `/OrigResources` and `/XObjectRef`, the page gets `/LastModified`, and removal
/// deletes keys with pdf_dict_del rather than writing null.
///
/// Wrap mode:    /Contents := [cutStart, <original streams>, cutEnd]
/// XObject mode: /Contents := cutStart ("q path W n /VEOrig Do Q"),
///               /Resources := << /XObject << /VEOrig form >> >>, the form holding a copy
///               of the original content (raw bytes when there is one stream).
/// Original content stream objects are never modified.
struct CutWriter {
    let doc: MuPDFDocument

    static let cutPath = "PieceInfo/VoucherEditor/Private/Cut"

    enum Mode: String { case wrap = "Wrap", xobject = "XObject" }

    func hasCut(pageNum: Int) throws -> Bool {
        !(try doc.get(pageNum, Self.cutPath)).isNull
    }

    private func pdfDate() -> PDFValue {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "'D:'yyyyMMddHHmmss'Z'"
        return .text(f.string(from: Date()))
    }

    /// Content stream object numbers of the page, in order.
    func contentStreams(pageNum: Int) throws -> [Int] {
        let v = try doc.get(pageNum, "Contents")
        if let n = v.refNumber {
            if try doc.isStream(n) { return [n] }
            return (try doc.object(n)).array?.compactMap(\.refNumber) ?? []
        }
        return v.array?.compactMap(\.refNumber) ?? []
    }

    private func inherited(_ pageNum: Int, _ key: String) throws -> PDFValue {
        var n = pageNum
        for _ in 0..<32 {
            let v = try doc.get(n, key)
            if !v.isNull { return v }
            guard let p = try doc.get(n, "Parent").refNumber else { break }
            n = p
        }
        return .null
    }

    private func writeCutDict(pageNum: Int, _ entries: [String: PDFValue]) throws {
        let date = pdfDate()
        if try doc.get(pageNum, "PieceInfo").isNull { try doc.set(pageNum, "PieceInfo", .dict([:])) }
        try doc.set(pageNum, "PieceInfo/VoucherEditor",
                    .dict(["LastModified": date, "Private": .dict(["Cut": .dict(entries)])]))
        // ISO 32000: a page with /PieceInfo must carry /LastModified.
        try doc.set(pageNum, "LastModified", date)
    }

    private func commonEntries(_ o: Outline, mode: Mode) -> [String: PDFValue] {
        ["Version": .int(1), "Start": CutCodec.startValue(o), "Segments": CutCodec.segmentsValue(o),
         "Mode": .name(mode.rawValue), "Source": .dict(["Kind": .name("Drawn")])]
    }

    @discardableResult
    mutating func apply(pageNum: Int, outline o: Outline, forceMode: Mode? = nil) throws -> Mode {
        if try hasCut(pageNum: pageNum) { throw EngineError("page already has a cut") }
        let contentsValue = try doc.get(pageNum, "Contents")
        let streams = try contentStreams(pageNum: pageNum)
        let original = try streams.map { try doc.streamData($0) }.reduce(into: Data()) { acc, d in
            if !acc.isEmpty { acc.append(0x0A) }
            acc.append(d)
        }
        let mode = forceMode ?? (ContentScanner.isBalanced(original) ? .wrap : .xobject)
        var entries = commonEntries(o, mode: mode)
        entries["OrigContents"] = contentsValue

        switch mode {
        case .wrap:
            let start = try doc.newStream(dict: .dict([:]), data: CutCodec.wrapStartStream(o))
            let end = try doc.newStream(dict: .dict([:]), data: CutCodec.endStream)
            try doc.set(pageNum, "Contents", .array(([start] + streams + [end]).map { .ref($0, 0) }))
            entries["StartRef"] = .ref(start, 0)
            entries["EndRef"] = .ref(end, 0)
        case .xobject:
            let ownResources = try doc.get(pageNum, "Resources")
            let resources = try inherited(pageNum, "Resources")
            let bbox = try inherited(pageNum, "MediaBox")
            var formDict: [String: PDFValue] = [
                "Type": .name("XObject"), "Subtype": .name("Form"),
                "BBox": bbox, "Resources": resources.isNull ? .dict([:]) : resources,
            ]
            let form: Int
            if streams.count == 1 {
                // Copy the encoded bytes as they are, with the same filter keys (no re-encode).
                for key in ["Filter", "DecodeParms"] {
                    let v = try doc.get(streams[0], key)
                    if !v.isNull { formDict[key] = v }
                }
                form = try doc.newRawStream(dict: .dict(formDict), data: try doc.streamData(streams[0], raw: true))
            } else {
                form = try doc.newStream(dict: .dict(formDict), data: original)
            }
            let start = try doc.newStream(dict: .dict([:]), data: CutCodec.xobjectStartStream(o))
            try doc.set(pageNum, "Contents", .ref(start, 0))
            try doc.set(pageNum, "Resources", .dict(["XObject": .dict([CutCodec.xobjectName: .ref(form, 0)])]))
            entries["StartRef"] = .ref(start, 0)
            entries["XObjectRef"] = .ref(form, 0)
            entries["OrigResources"] = ownResources // null when the page inherited its resources
        }
        try writeCutDict(pageNum: pageNum, entries)
        return mode
    }

    /// Replace cutStart with a new stream object and update the stored outline.
    mutating func edit(pageNum: Int, outline o: Outline) throws {
        let cut = try doc.resolve(try doc.get(pageNum, Self.cutPath))
        guard let d = cut.dict else { throw EngineError("no cut on this page") }
        let mode = Mode(rawValue: d["Mode"]?.name ?? "Wrap") ?? .wrap
        var entries = commonEntries(o, mode: mode)
        for k in ["OrigContents", "EndRef", "OrigResources", "XObjectRef", "Source", "CropFields", "CoverAnnot"] {
            if let v = d[k], !v.isNull { entries[k] = v }
        }
        switch mode {
        case .wrap:
            let start = try doc.newStream(dict: .dict([:]), data: CutCodec.wrapStartStream(o))
            var refs = try contentStreams(pageNum: pageNum)
            guard let old = d["StartRef"]?.refNumber, refs.first == old else {
                throw EngineError("the cut's start stream is no longer first in /Contents; the page was changed by another tool")
            }
            refs[0] = start
            try doc.set(pageNum, "Contents", .array(refs.map { .ref($0, 0) }))
            entries["StartRef"] = .ref(start, 0)
        case .xobject:
            let start = try doc.newStream(dict: .dict([:]), data: CutCodec.xobjectStartStream(o))
            try doc.set(pageNum, "Contents", .ref(start, 0))
            entries["StartRef"] = .ref(start, 0)
        }
        try writeCutDict(pageNum: pageNum, entries)
    }

    /// Restore the exact original /Contents (and /Resources in XObject mode), then drop the cut.
    mutating func remove(pageNum: Int) throws {
        let cut = try doc.resolve(try doc.get(pageNum, Self.cutPath))
        guard let d = cut.dict, let orig = d["OrigContents"] else { throw EngineError("no cut on this page") }
        try doc.set(pageNum, "Contents", orig)
        if d["Mode"]?.name == "XObject" {
            try doc.set(pageNum, "Resources", d["OrigResources"] ?? .null)
        }
        try doc.set(pageNum, "PieceInfo/VoucherEditor", .null)
        let pieceInfo = try doc.resolve(try doc.get(pageNum, "PieceInfo"))
        if pieceInfo.dict?.isEmpty ?? false { try doc.set(pageNum, "PieceInfo", .null) }
        try doc.set(pageNum, "LastModified", pdfDate())
    }
}
