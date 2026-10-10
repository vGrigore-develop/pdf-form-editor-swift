import Foundation
import PDFEngine
import VoucherModel

/// `PDFEngine` implemented with MuPDF through the C shim (SPEC 7.3, 7.4).
///
/// Each save works on a fresh MuPDF document opened from the current bytes, applies
/// the model diff with key-level edits, and writes an incremental update (or a full
/// rewrite when asked). The engine then represents the new bytes.
public final class MuPDFEngine: PDFEngine {
    public private(set) var currentData: Data
    private var doc: MuPDFDocument
    /// Field id -> object number for every field present in `currentData`.
    public private(set) var objectNumbers: [UUID: Int] = [:]
    private var facts = DocumentFacts()

    public init(data: Data) throws {
        currentData = data
        doc = try MuPDFDocument(data: data)
        if doc.needsPassword { throw EngineError("The PDF is password-protected; opening encrypted files that need a password is not supported yet.") }
    }

    public var wasRepaired: Bool { doc.wasRepaired }

    public func readTemplate() throws -> ReadResult {
        let out = try TemplateReader(doc: doc).read()
        objectNumbers = out.objectNumbers
        facts = out.facts
        return ReadResult(template: out.template, facts: out.facts, notes: out.notes)
    }

    public func save(baseline: Template, edited: Template, incremental: Bool = true) throws -> SaveResult {
        if incremental && doc.wasRepaired {
            throw EngineError("MuPDF had to repair this file when opening it, so an incremental save is impossible. Use Save As (full rewrite).")
        }
        let work = try MuPDFDocument(data: currentData)
        var writer = TemplateWriter(doc: work, objectNumbers: objectNumbers)
        try writer.apply(baseline: baseline, edited: edited, signatureCount: facts.signatureCount)
        let out = try work.write(incremental: incremental)
        if incremental {
            guard out.count >= currentData.count, out.prefix(currentData.count) == currentData else {
                throw EngineError("Internal check failed: the incremental save did not keep the original bytes as a prefix. Nothing was written.")
            }
        }
        // Re-open the written bytes to make sure they parse before handing them out.
        let reopened = try MuPDFDocument(data: out)
        if reopened.wasRepaired {
            throw EngineError("Internal check failed: the saved file needed repair when re-opened. Nothing was written.")
        }
        let appended = incremental ? out.count - currentData.count : 0
        currentData = out
        doc = reopened
        objectNumbers = writer.objectNumbers
        return SaveResult(data: out, appendedBytes: appended, wasIncremental: incremental, summary: writer.summary)
    }

    /// The bytes a save would produce, without committing anything (Preview, SPEC 7.2).
    /// Works on a throwaway document; the engine's state is unchanged.
    public func previewData(baseline: Template, edited: Template) throws -> Data {
        let work = try MuPDFDocument(data: currentData)
        var writer = TemplateWriter(doc: work, objectNumbers: objectNumbers)
        writer.preview = true // sample images become /MK /I in this throwaway copy only
        // Signed documents refuse cuts on save; the preview still shows them.
        try writer.apply(baseline: baseline, edited: edited, signatureCount: 0)
        return try work.write(incremental: !work.wasRepaired)
    }
}
