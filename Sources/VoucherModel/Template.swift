import Foundation

public enum FieldKind: String, Codable, Hashable, Sendable {
    case text
    case image
    /// Checkbox, radio, choice, signature, or anything else: shown read-only, preserved.
    case other
}

public enum TextAlignment: Int, Codable, Hashable, Sendable, CaseIterable {
    case left = 0, center = 1, right = 2
}

/// Field flag bits used by the app (ISO 32000 12.7.3.1, 12.7.4.3, 12.7.4.2).
public enum FieldFlags {
    public static let readOnly = 1 << 0
    public static let required = 1 << 1
    public static let multiline = 1 << 12
    public static let password = 1 << 13
    public static let pushButton = 1 << 16
    public static let fileSelect = 1 << 20
    public static let doNotScroll = 1 << 23
    public static let comb = 1 << 24

    /// Bits the inspector manages for text fields; all other bits are preserved as read.
    public static let textManaged = readOnly | required | multiline | doNotScroll | comb
    /// Bits the inspector manages for image fields (push-button bit is always set).
    public static let imageManaged = readOnly | required | pushButton
}

public struct TextProps: Codable, Hashable, Sendable {
    /// Resource name of the font in /AcroForm /DR /Font (plain ASCII, SPEC 6.1).
    public var fontName: String = "Helv"
    /// Font size in points; 0 = auto (allowed, but warned).
    public var fontSize: Double = 12
    public var color: RGBColor = .black
    public var alignment: TextAlignment = .left
    public var multiline = false
    public var doNotScroll = false
    public var maxLength: Int?
    public var comb = false
    /// Read from the file only; the app never sets these, but checks conflicts.
    public var password = false
    public var fileSelect = false
    /// Written as /V and /DV when non-empty.
    public var defaultValue = ""
    /// Preview only; never written as /V.
    public var sampleValue = ""
    public var borderColor: RGBColor? = RGBColor(gray: 0.45)
    public var backgroundColor: RGBColor? = .white
    public var borderWidth: Double = 1

    public init() {}
}

public enum ScaleWhen: String, Codable, Hashable, Sendable, CaseIterable {
    case always = "A", tooBig = "B", tooSmall = "S", never = "N"
}

public enum ScaleHow: String, Codable, Hashable, Sendable, CaseIterable {
    case proportional = "P", stretch = "A"
}

public struct ImageProps: Codable, Hashable, Sendable {
    public var scaleWhen: ScaleWhen = .always
    public var scaleHow: ScaleHow = .proportional
    /// /MK /IF /A, each 0...1 (0,0 = bottom-left).
    public var alignX: Double = 0.5
    public var alignY: Double = 0.5
    public var fitBounds = false
    public var backgroundColor: RGBColor? = RGBColor(gray: 0.92)
    public var borderColor: RGBColor? = RGBColor(gray: 0.5)
    /// /BS /W of the placeholder border (drawn dashed, /BS /S /D).
    public var borderWidth: Double = 1
    public var label = "Click to add image"
    /// Preview only (SPEC 3, 7.2): a local image file shown as /MK /I in the in-memory
    /// Preview build, placed with this field's /IF. Never written to the saved file.
    public var sampleImagePath = ""
    /// Acrobat click-to-insert action (`event.target.buttonImportIcon();`), default on.
    public var importAction = true

    public init() {}
}

/// What the reader found about a field that already exists in the file.
/// `nil` on a FieldDef means the field is new (created in this session).
public struct FieldOrigin: Codable, Hashable, Sendable {
    /// Object number of the merged field/widget dictionary (or of the widget for a kid).
    public var objectNumber: Int
    /// Fully qualified name as read (`a.b.c` for hierarchical fields).
    public var fullName: String
    public var isHierarchical: Bool
    /// Number of widgets the field has (1 for a merged field/widget).
    public var widgetCount: Int
    /// False for field types the app does not edit, linked fields, and hierarchical fields.
    public var editable: Bool
    public var readOnlyReason: String?
    /// Structure facts used by the save checks (SPEC 6.2).
    public var inPageAnnots: Bool
    public var hasPageRef: Bool
    public var inAcroFormFields: Bool
    /// /Ff exactly as read, so unmanaged bits survive.
    public var rawFlags: Int
    /// /DA exactly as read and whether it parsed.
    public var rawDA: String?
    public var daParsed: Bool
    /// The field has a non-JS or foreign /A action the app must not remove.
    public var hasForeignAction: Bool
    /// Field type name as read (/Tx, /Btn, /Ch, /Sig) for display.
    public var typeName: String

    // "Merge field and widget" (DECISIONS 29). Set by the reader for a terminal field whose
    // only widget is a separate /Kids object (Illustrator/InDesign exports).
    /// Object number of that separate widget; nil when field and widget are one dictionary.
    public var separateWidget: Int?
    /// Why the merge is refused (signed document, unexpected structure); nil = offered.
    public var widgetMergeBlocker: String?
    /// Keys that exist on both objects with different values, and which value the merge keeps.
    public var widgetMergeNotes: [String]
    /// Set by the merge command (undoable); the save performs the merge.
    public var mergeWidgetOnSave: Bool

    public init(objectNumber: Int, fullName: String, isHierarchical: Bool = false, widgetCount: Int = 1,
                editable: Bool = true, readOnlyReason: String? = nil, inPageAnnots: Bool = true,
                hasPageRef: Bool = true, inAcroFormFields: Bool = true, rawFlags: Int = 0,
                rawDA: String? = nil, daParsed: Bool = true, hasForeignAction: Bool = false,
                typeName: String = "Tx", separateWidget: Int? = nil, widgetMergeBlocker: String? = nil,
                widgetMergeNotes: [String] = [], mergeWidgetOnSave: Bool = false) {
        self.objectNumber = objectNumber
        self.fullName = fullName
        self.isHierarchical = isHierarchical
        self.widgetCount = widgetCount
        self.editable = editable
        self.readOnlyReason = readOnlyReason
        self.inPageAnnots = inPageAnnots
        self.hasPageRef = hasPageRef
        self.inAcroFormFields = inAcroFormFields
        self.rawFlags = rawFlags
        self.rawDA = rawDA
        self.daParsed = daParsed
        self.hasForeignAction = hasForeignAction
        self.typeName = typeName
        self.separateWidget = separateWidget
        self.widgetMergeBlocker = widgetMergeBlocker
        self.widgetMergeNotes = widgetMergeNotes
        self.mergeWidgetOnSave = mergeWidgetOnSave
    }
}

public struct FieldDef: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: FieldKind
    /// Partial name (/T). For hierarchical fields this is the leaf; `qualifiedName` is the full name.
    public var name: String
    /// 0-based page index.
    public var page: Int
    public var rect: PDFRect
    public var tooltip: String
    public var required: Bool
    public var readOnly: Bool
    public var text: TextProps
    public var image: ImageProps
    public var origin: FieldOrigin?

    public init(id: UUID = UUID(), kind: FieldKind, name: String, page: Int, rect: PDFRect,
                tooltip: String = "", required: Bool = false, readOnly: Bool = false,
                text: TextProps = TextProps(), image: ImageProps = ImageProps(), origin: FieldOrigin? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.page = page
        self.rect = rect
        self.tooltip = tooltip
        self.required = required
        self.readOnly = readOnly
        self.text = text
        self.image = image
        self.origin = origin
    }

    public var isNew: Bool { origin == nil }
    public var isEditable: Bool { origin?.editable ?? true }

    /// A text or image field read with its only widget as a separate /Kids object, not yet
    /// merged (the inspector offers "Merge field and widget"; it may still be blocked).
    public var hasSeparateWidget: Bool {
        guard let o = origin, kind != .other else { return false }
        return o.separateWidget != nil && !o.mergeWidgetOnSave
    }

    /// The merge can run: separate widget, nothing blocking it.
    public var canMergeWidget: Bool { hasSeparateWidget && origin?.widgetMergeBlocker == nil }

    /// Fully qualified name: the read prefix (for hierarchical fields) plus the current leaf.
    public var qualifiedName: String {
        guard let o = origin, o.isHierarchical, let dot = o.fullName.lastIndex(of: ".") else { return name }
        return String(o.fullName[..<dot]) + "." + name
    }

    /// /Ff as it should be written: managed bits from the properties, other bits as read.
    public var flags: Int {
        let raw = origin?.rawFlags ?? 0
        switch kind {
        case .text:
            var f = raw & ~FieldFlags.textManaged
            if readOnly { f |= FieldFlags.readOnly }
            if required { f |= FieldFlags.required }
            if text.multiline { f |= FieldFlags.multiline }
            if text.doNotScroll { f |= FieldFlags.doNotScroll }
            if text.comb { f |= FieldFlags.comb }
            return f
        case .image:
            var f = (raw & ~FieldFlags.imageManaged) | FieldFlags.pushButton
            if readOnly { f |= FieldFlags.readOnly }
            if required { f |= FieldFlags.required }
            return f
        case .other:
            return raw
        }
    }

    /// The field without its Preview-only values (sample text, sample image). The save
    /// diffs this form, so changing only a sample never rewrites the field (SPEC 6.1).
    public var persistentForm: FieldDef {
        var f = self
        f.text.sampleValue = ""
        f.image.sampleImagePath = ""
        return f
    }

    /// The minimal /DA SPEC 6.1 requires: `/<Font> <size> Tf <r> <g> <b> rg`.
    public var defaultAppearance: String {
        let size = kind == .image ? 0 : text.fontSize
        let c = kind == .image ? RGBColor.black : text.color
        return "/\(text.fontName) \(PDFNumber.format(size)) Tf \(PDFNumber.format(c.r)) \(PDFNumber.format(c.g)) \(PDFNumber.format(c.b)) rg"
    }
}

/// Number formatting shared by everything that writes PDF syntax.
public enum PDFNumber {
    /// Up to 4 decimals, trailing zeros stripped, never "-0".
    public static func format(_ v: Double) -> String {
        if !v.isFinite { return "0" }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" || s.isEmpty { return "0" }
        return s
    }
}

public struct PageInfo: Codable, Hashable, Sendable {
    public var mediaBox: PDFRect
    public var cropBox: PDFRect
    /// /Rotate, normalised to 0, 90, 180, 270.
    public var rotation: Int
    public init(mediaBox: PDFRect, cropBox: PDFRect? = nil, rotation: Int = 0) {
        self.mediaBox = mediaBox
        self.cropBox = cropBox ?? mediaBox
        self.rotation = rotation
    }
}

/// Facts about the document that drive warnings (SPEC 3 MVP, 7.7).
public struct DocumentFacts: Codable, Hashable, Sendable {
    public var signatureCount = 0
    public var hasCertification = false
    public var hasJavaScript = false
    public var hasXFA = false
    public var wasRepaired = false
    public var isEncrypted = false
    public init() {}
}

/// The editable template: the model the UI changes and the save pipeline diffs.
public struct Template: Codable, Hashable, Sendable {
    public var pages: [PageInfo]
    public var fields: [FieldDef]
    /// Outline per page index (SPEC 5.1: at most one per page).
    public var outlines: [Int: Outline]
    /// "Keep fields inside outline" (SPEC 5.3), on by default.
    public var keepFieldsInsideOutline: Bool
    /// "Crop fields to outline" (spike S10, DECISIONS 30): on a page with a cut, the
    /// appearance of every widget that crosses the outline is clipped to it, and a cover
    /// annotation hides whatever filling code draws outside the shape. Per document; stored
    /// as /CropFields in each cut's /PieceInfo. On by default for new cuts; a file whose cut
    /// was saved without it reads as off.
    public var cropFieldsToOutline: Bool

    public init(pages: [PageInfo], fields: [FieldDef] = [], outlines: [Int: Outline] = [:],
                keepFieldsInsideOutline: Bool = true, cropFieldsToOutline: Bool = true) {
        self.pages = pages
        self.fields = fields
        self.outlines = outlines
        self.keepFieldsInsideOutline = keepFieldsInsideOutline
        self.cropFieldsToOutline = cropFieldsToOutline
    }

    /// Whether the field's appearance is cropped to its page's outline when saved: cropping
    /// is on, the page has an outline, and the field is not fully inside it.
    public func isCropped(_ f: FieldDef, containment: (FieldDef, Outline) -> OutlineContainment) -> Bool {
        guard cropFieldsToOutline, let o = outlines[f.page] else { return false }
        return containment(f, o) != .inside
    }

    public func field(_ id: UUID) -> FieldDef? { fields.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { fields.firstIndex { $0.id == id } }
    public func fields(onPage page: Int) -> [FieldDef] { fields.filter { $0.page == page } }
}
