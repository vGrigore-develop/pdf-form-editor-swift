// swift-tools-version: 6.0
// PDF Voucher Editor. Build MuPDF first: scripts/build-mupdf.sh (once).
// Then: swift build / swift test, or scripts/build-app.sh for the .app bundle.
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let mupdfLib = "\(root)/vendor/mupdf/lib"

let package = Package(
    name: "PDFVoucherEditor",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PDFVoucherEditor", targets: ["VoucherEditorApp"]),
    ],
    targets: [
        // Pure Swift, no PDF types (SPEC 7.3).
        .target(name: "VoucherModel"),
        .target(name: "VoucherGeometry", dependencies: ["VoucherModel"]),
        // Smart outline: page raster edge map, live-wire tracing, line/arc fitting.
        // Optimised in debug builds too: its pixel loops are ~50x slower unoptimised.
        .target(name: "VoucherTrace", dependencies: ["VoucherModel", "VoucherGeometry"],
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // PDF object syntax, content tokenizer and the engine protocol; no MuPDF types.
        .target(name: "PDFEngine", dependencies: ["VoucherModel", "VoucherGeometry"]),
        // /AP /N streams for the widgets the app writes.
        .target(name: "Appearance", dependencies: ["VoucherModel", "PDFEngine"]),
        // C shim over the MuPDF static libraries (built by scripts/build-mupdf.sh).
        .target(
            name: "CMuPDFShim",
            cSettings: [
                .headerSearchPath("../../vendor/mupdf/include"),
                .unsafeFlags(["-Wno-unused-parameter"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(mupdfLib)"]),
                .linkedLibrary("mupdf"),
                .linkedLibrary("mupdf-third"),
            ]
        ),
        .target(
            name: "MuPDFEngine",
            dependencies: ["CMuPDFShim", "PDFEngine", "Appearance", "VoucherModel", "VoucherGeometry"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VoucherEditorApp",
            dependencies: ["VoucherModel", "VoucherGeometry", "PDFEngine", "MuPDFEngine", "VoucherTrace"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VoucherTraceTests", dependencies: ["VoucherTrace", "VoucherGeometry", "VoucherModel"]),
        .testTarget(name: "VoucherModelTests", dependencies: ["VoucherModel"]),
        .testTarget(name: "VoucherGeometryTests", dependencies: ["VoucherGeometry", "VoucherModel"]),
        .testTarget(name: "PDFEngineTests", dependencies: ["PDFEngine", "VoucherModel"]),
        .testTarget(
            name: "VoucherEditorAppTests",
            dependencies: ["VoucherEditorApp", "VoucherModel", "VoucherGeometry", "MuPDFEngine", "VoucherTrace"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MuPDFEngineTests",
            dependencies: ["MuPDFEngine", "PDFEngine", "VoucherModel", "VoucherGeometry"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
