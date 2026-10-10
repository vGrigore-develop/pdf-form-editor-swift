import SwiftUI
import VoucherTrace

/// Smart outline preferences (the outline tool following the page's own artwork),
/// persisted in UserDefaults like `SnapPrefs`; the inspector binds with @AppStorage and
/// the canvas reads them on every click.
enum TracePrefs {
    enum Mode: String, CaseIterable, Identifiable {
        case points, detect
        var id: String { rawValue }
        var label: String { self == .points ? "Click anchors" : "Auto-detect shape" }
    }

    static let smartKey = "traceSmart"
    static let modeKey = "traceMode"
    static let sensitivityKey = "traceSensitivity"
    static let snapRadiusKey = "traceSnapRadius"
    static let toleranceKey = "traceTolerance"
    static let thresholdKey = "traceRegionThreshold"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            smartKey: true, modeKey: Mode.points.rawValue, sensitivityKey: TraceDefaults.sensitivity,
            snapRadiusKey: TraceDefaults.snapRadius, toleranceKey: TraceDefaults.tolerance, thresholdKey: TraceDefaults.regionThreshold,
        ])
    }

    private static var d: UserDefaults { registerDefaults(); return .standard }
    static var smart: Bool { d.bool(forKey: smartKey) }
    static var mode: Mode { Mode(rawValue: d.string(forKey: modeKey) ?? "") ?? .points }
    static var sensitivity: Double { min(max(d.double(forKey: sensitivityKey), 0), 1) }
    /// Anchor snap radius in screen points.
    static var snapRadius: Double { max(0, d.double(forKey: snapRadiusKey)) }
    /// Fitting tolerance in page points.
    static var tolerance: Double { min(max(d.double(forKey: toleranceKey), 0.05), 5) }
    static var regionThreshold: Double { max(1, d.double(forKey: thresholdKey)) }

    static let allKeys = [smartKey, modeKey, sensitivityKey, snapRadiusKey, toleranceKey, thresholdKey]
}

/// Inspector controls for the smart outline, shown while no outline exists on the page.
struct SmartOutlineSettings: View {
    @AppStorage(TracePrefs.smartKey) private var smart = true
    @AppStorage(TracePrefs.modeKey) private var mode = TracePrefs.Mode.points.rawValue
    @AppStorage(TracePrefs.sensitivityKey) private var sensitivity = TraceDefaults.sensitivity
    @AppStorage(TracePrefs.snapRadiusKey) private var snapRadius = TraceDefaults.snapRadius
    @AppStorage(TracePrefs.toleranceKey) private var tolerance = TraceDefaults.tolerance
    @AppStorage(TracePrefs.thresholdKey) private var threshold = TraceDefaults.regionThreshold

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Smart (follow artwork)", isOn: $smart)
                .help("The outline snaps to and follows the edges and lines of the page's own artwork.")
            if smart {
                Picker("", selection: $mode) {
                    ForEach(TracePrefs.Mode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if mode == TracePrefs.Mode.detect.rawValue {
                    slider("Colour threshold", value: $threshold, in: 5...150, format: "%.0f")
                    Hint("Click inside a shape to outline the region of similar colour, or on the plain background around it to outline the shape it surrounds.")
                } else {
                    slider("Edge sensitivity", value: $sensitivity, in: 0...1, format: "%.2f")
                    slider("Edge snap radius", value: $snapRadius, in: 0...24, format: "%.0f px")
                    Hint("Click anchors at corners; between them the outline follows the artwork (blue preview). Shift: straight segment. Cmd or Option: place without snapping. Click the first anchor or press Return to close; Delete removes the last anchor.")
                }
                slider("Tolerance", value: $tolerance, in: 0.1...2, format: "%.2f pt")
                    .help("How far the fitted lines and arcs may stray from the traced edge. Smaller keeps more detail, larger gives fewer segments.")
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
        }
    }
}
