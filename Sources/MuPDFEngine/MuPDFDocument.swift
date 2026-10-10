import Foundation
import CMuPDFShim
import PDFEngine

/// Thin Swift wrapper over the C shim. Every call returns or throws; MuPDF's
/// longjmp-based errors never reach Swift (they are caught inside the shim).
/// Not thread-safe: one instance is used from one thread at a time (SPEC 7.4).
final class MuPDFDocument {
    private let handle: OpaquePointer

    init(data: Data) throws {
        var err = ve_error()
        let h: OpaquePointer? = data.withUnsafeBytes { raw in
            ve_open_memory(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &err)
        }
        guard let h else { throw EngineError("Cannot open PDF: \(Self.message(&err))", code: Int(err.code)) }
        handle = h
    }

    deinit { ve_close(handle) }

    private static func message(_ e: inout ve_error) -> String {
        withUnsafeBytes(of: &e.message) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func call<T>(_ what: String, _ body: (UnsafeMutablePointer<ve_error>) -> T, failed: (T) -> Bool) throws -> T {
        var err = ve_error()
        let r = body(&err)
        if err.code != 0 || failed(r) {
            throw EngineError("\(what): \(Self.message(&err))", code: Int(err.code))
        }
        return r
    }

    private func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "null" }
        defer { ve_free(p) }
        return String(cString: p)
    }

    private func takeData(_ p: UnsafeMutablePointer<UInt8>?, _ len: Int) -> Data {
        guard let p else { return Data() }
        defer { ve_free(p) }
        return Data(bytes: p, count: len)
    }

    // MARK: Document

    var pageCount: Int { get throws { Int(try call("page count", { ve_page_count(handle, $0) }, failed: { $0 < 0 })) } }

    func pageObjectNumber(_ index: Int) throws -> Int {
        Int(try call("page \(index + 1)", { ve_page_object_number(handle, Int32(index), $0) }, failed: { $0 < 0 }))
    }

    func catalogObjectNumber() throws -> Int {
        Int(try call("catalog", { ve_catalog_object_number(handle, $0) }, failed: { $0 < 0 }))
    }

    /// Number of entries in the cross-reference table (object numbers are 1..<xrefLength).
    var xrefLength: Int { get throws { Int(try call("xref length", { ve_xref_length(handle, $0) }, failed: { $0 < 0 })) } }

    var wasRepaired: Bool { ve_was_repaired(handle) != 0 }
    var needsPassword: Bool { ve_needs_password(handle) != 0 }
    var isEncrypted: Bool { ve_is_encrypted(handle) != 0 }
    var hasUnsavedChanges: Bool { ve_has_unsaved_changes(handle) != 0 }

    func signatureCount() throws -> Int {
        Int(try call("signatures", { ve_count_signatures(handle, $0) }, failed: { $0 < 0 }))
    }

    // MARK: Objects

    func objectSyntax(_ num: Int) throws -> String {
        takeString(try call("object \(num)", { ve_object_string(handle, Int32(num), $0) }, failed: { $0 == nil }))
    }

    func object(_ num: Int) throws -> PDFValue { try PDFParser.parse(try objectSyntax(num)) }

    func trailer() throws -> PDFValue {
        try PDFParser.parse(takeString(try call("trailer", { ve_trailer_string(handle, $0) }, failed: { $0 == nil })))
    }

    /// Value at a key path (e.g. "MK/IF/SW"); references stay unresolved.
    func get(_ num: Int, _ path: String) throws -> PDFValue {
        let s = takeString(try call("get \(num) \(path)", { ve_get_key(handle, Int32(num), path, $0) }, failed: { $0 == nil }))
        return try PDFParser.parse(s)
    }

    /// The value at a key path exactly as MuPDF prints it. Copying a value with
    /// `getSyntax` + `setSyntax` never goes through `PDFValue`, so numbers keep MuPDF's
    /// own precision (PDFValue writes reals with at most 4 decimals).
    func getSyntax(_ num: Int, _ path: String) throws -> String {
        takeString(try call("get \(num) \(path)", { ve_get_key(handle, Int32(num), path, $0) }, failed: { $0 == nil }))
    }

    /// Resolve a value: follow a reference to its object, otherwise return it as is.
    func resolve(_ v: PDFValue) throws -> PDFValue {
        if case .ref(let n, _) = v { return try object(n) }
        return v
    }

    /// Set a key (".null" deletes it). Key-level: only this key of this object changes.
    func set(_ num: Int, _ path: String, _ value: PDFValue) throws {
        try setSyntax(num, path, value.syntax)
    }

    func setSyntax(_ num: Int, _ path: String, _ src: String) throws {
        _ = try call("set \(num) \(path)", { ve_set_key(handle, Int32(num), path, src, $0) }, failed: { $0 != 0 })
    }

    func newObject(_ value: PDFValue) throws -> Int {
        Int(try call("new object", { ve_new_object(handle, value.syntax, $0) }, failed: { $0 < 0 }))
    }

    func update(_ num: Int, _ value: PDFValue) throws {
        _ = try call("update \(num)", { ve_update_object(handle, Int32(num), value.syntax, $0) }, failed: { $0 != 0 })
    }

    func newStream(dict: PDFValue, data: Data, compress: Bool = true) throws -> Int {
        let syntax = dict.syntax
        return Int(try call("new stream", { err in
            data.withUnsafeBytes { raw in
                ve_new_stream(handle, syntax, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, compress ? 1 : 0, err)
            }
        }, failed: { $0 < 0 }))
    }

    /// Stream with already-encoded bytes (its dictionary carries the /Filter).
    func newRawStream(dict: PDFValue, data: Data) throws -> Int {
        let syntax = dict.syntax
        return Int(try call("new raw stream", { err in
            data.withUnsafeBytes { raw in
                ve_new_raw_stream(handle, syntax, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, err)
            }
        }, failed: { $0 < 0 }))
    }

    func isStream(_ num: Int) throws -> Bool {
        try call("is stream \(num)", { ve_is_stream(handle, Int32(num), $0) }, failed: { $0 < 0 }) == 1
    }

    func streamData(_ num: Int, raw: Bool = false) throws -> Data {
        var len = 0
        let p = try call("stream \(num)", { ve_stream_data(handle, Int32(num), raw ? 1 : 0, &len, $0) }, failed: { $0 == nil })
        return takeData(p, len)
    }

    /// The whole file: original bytes plus an incremental update, or a full rewrite.
    func write(incremental: Bool) throws -> Data {
        var len = 0
        let p = try call("write", { ve_write(handle, incremental ? 1 : 0, &len, $0) }, failed: { $0 == nil })
        return takeData(p, len)
    }
}
