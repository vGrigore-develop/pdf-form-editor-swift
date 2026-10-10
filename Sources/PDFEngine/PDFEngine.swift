import Foundation
import VoucherModel

/// The engine boundary (SPEC 7.3). MuPDF implements it today; the app only talks
/// to this protocol, so the engine can be swapped or mocked.
///
/// Single-writer design (SPEC 7.2): the engine owns the document and is the only
/// thing that produces bytes. PDFKit only ever displays bytes the engine wrote
/// (or the original on open).
public protocol PDFEngine: AnyObject {
    /// The bytes the engine currently represents (the original on open, the last save afterwards).
    var currentData: Data { get }

    /// Fields, pages, outlines and document facts read from the file.
    func readTemplate() throws -> ReadResult

    /// Apply the difference between `baseline` (what was read) and `edited` with
    /// key-level edits, then write. `incremental` appends an update so the
    /// previous bytes stay an exact prefix (SPEC 7.7 step 6).
    /// Returns the complete new file; the engine then represents those bytes.
    func save(baseline: Template, edited: Template, incremental: Bool) throws -> SaveResult
}

public struct ReadResult: Sendable {
    public var template: Template
    public var facts: DocumentFacts
    /// Human-readable notes from reading (unsupported fields, recovered cuts, ...).
    public var notes: [String]

    public init(template: Template, facts: DocumentFacts, notes: [String] = []) {
        self.template = template
        self.facts = facts
        self.notes = notes
    }
}

public struct SaveResult: Sendable {
    public var data: Data
    /// Bytes appended by this save (0 for a full rewrite).
    public var appendedBytes: Int
    public var wasIncremental: Bool
    public var summary: [String]

    public init(data: Data, appendedBytes: Int, wasIncremental: Bool, summary: [String]) {
        self.data = data
        self.appendedBytes = appendedBytes
        self.wasIncremental = wasIncremental
        self.summary = summary
    }
}

public struct EngineError: Error, LocalizedError, Sendable {
    public var message: String
    public var code: Int
    public init(_ message: String, code: Int = 1) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}
