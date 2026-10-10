# Implementation decisions and deviations from SPEC.md

SPEC.md (draft 3.1) is unchanged. This file records the choices made while building the first testable app (M1 + M2, most of M3) and where the code departs from the spec, with the reason. Spike findings come from `spikes/RESULTS.md`.

Date: 2026-10-10. Toolchain: Xcode 27.0 (27A5252f), Swift 6.4, macOS 27, arm64.

## Build and project shape

1. **A Swift package, not an Xcode project.** `swift build` / `swift test` work from the command line with no Xcode GUI. `scripts/build-app.sh` assembles `build/PDF Voucher Editor.app` (Info.plist from `Resources/`, ad-hoc signed). The deployment target is macOS 15. The spec names macOS 27 as the platform, and nothing here needs 27-only APIs.
2. **MuPDF 1.28.2 is built from source** by `scripts/build-mupdf.sh`. The tarball is pinned by URL and SHA-256 (the same version as the spikes' PyMuPDF), and the build takes about a minute with `make libs`.
   - **Deviation from 7.4:** the output is two static libraries (`vendor/mupdf/lib/libmupdf.a`, `libmupdf-third.a`) plus headers, linked through SwiftPM linker flags, not an xcframework. Same effect for a single-arch local build, and one fewer packaging step. Making an xcframework later is mechanical (`xcodebuild -create-xcframework`).
   - **Build flags:**
     - `FZ_ENABLE_JS=0`: the JS engine is compiled out, which is stronger than "never call `pdf_enable_js`";
     - `TOFU_CJK TOFU_NOTO`: no fallback fonts, so the libraries are 17 MB instead of about 60 MB;
     - arm64 only.
   - **potrace is not built yet.** It is only needed for PNG tracing (M4).
3. `vendor/`, `.build/` and `build/` are gitignored. `spikes/node/node_modules/` is too: pdf-lib is installed locally by `npm install` inside `spikes/node`, with nothing global.

## Engine and the single-writer design

4. **The C shim exchanges objects as PDF syntax strings** (`Sources/CMuPDFShim/include/ve_shim.h`, 25 functions). Examples are `ve_get_key(doc, num, "MK/IF/SW")`, `ve_set_key(..., "null")` (which deletes with `pdf_dict_del`, S5 finding 9) and `ve_new_object(doc, "<<...>>")`.
   - This mirrors PyMuPDF's `xref_*` API, which the spikes were written against, so `s1_fields.py` and `cut.py` ported nearly line for line.
   - Every function runs inside `fz_try` and returns an error code and message, as 7.4 requires. MuPDF types never reach Swift.
   - On the Swift side, `PDFEngine/PDFValue.swift` parses and serialises the syntax.
   - Errors stay inside the shim: malformed and empty input produce Swift errors, not crashes (tested).
5. **`PDFEngine` is a Swift protocol** (7.3), with `readTemplate()` and `save(baseline:edited:incremental:)`. `MuPDFEngine` implements it. The app talks to the protocol plus the concrete type for preview builds.
6. **Single writer, kept.** MuPDF produces every byte. Each save opens a fresh MuPDF document from the current bytes, applies key-level edits, and writes an incremental update with `pdf_write_document` to memory. It then checks two things before handing the bytes to NSDocument: the previous bytes are an exact prefix, and the result re-opens without repair. PDFKit only displays.
7. **Deviation from 7.2 wording:** in Edit mode, widget annotations are **removed from PDFKit's in-memory copy** rather than set to `shouldDisplay = false`. PDFKit never writes, so this is safe, and it guarantees that a moved field never leaves its old stored appearance on screen. Preview reloads with the widgets visible.
8. **Identity across saves:** the engine keeps a map from field UUID to object number. The baseline after a save is the saved model itself; the file is not re-read. So undo keeps working across saves (7.7: "Saving does not clear undo"):
   - undoing a creation deletes the object on the next save;
   - undoing a deletion re-creates the field as a new object.
9. **Key-level edits:** only changed keys are written, and changed objects are re-emitted whole with all other keys intact (S1 finding 1). `/AP /N` is replaced; `/AP /D` and `/AP /R` are kept. Deleting a field removes it from `/Annots` and from `/Fields` (or from the parent's `/Kids`).

## Document model and UI

10. **NSDocument (AppKit) hosting SwiftUI views, instead of SwiftUI `DocumentGroup`.** The save flow needs a check sheet with "Save Anyway" before the bytes are produced, and full control over which bytes are written. NSDocument gives Open, Save, Save As, Revert, Open Recent, the dirty dot and the undo manager. Autosave is fully disabled, because producing bytes advances the engine's baseline.
11. **Undo** works on whole-`Template` snapshots (`VoucherModel/TemplateEditor.swift`):
    - drags coalesce into one step (begin, update, end gesture);
    - inspector typing coalesces per property until another command runs;
    - selection is not part of undo.
12. **The save sheet** appears when there are errors, or warnings not yet acknowledged in this session. It does not appear on every Cmd-S; a sheet listing the same "document contains JS" warning on every save would train him to click through it. Errors always need "Save Anyway". The full list is always visible in the inspector when nothing is selected, and as counts in the status bar.
13. **Shift keeps the aspect ratio for every field type.** The spec's "default on for image fields" is not implemented. Option resizes from the centre, Option-drag duplicates in place, and Cmd-D duplicates with `_2` suffixing.
14. **"Keep fields inside outline"** (on by default) constrains drags. A drag step that would take a field from inside to outside is refused, so the field stops at the last valid position.
15. **Field detection on read:**
    - text fields are `/FT /Tx`;
    - image fields are push-buttons with `/MK /TP 1`, `/MK /IF`, `/MK /I` or the `buttonImportIcon` action (7.6);
    - other push-buttons, checkboxes, radios, choices and signatures are shown read-only and preserved.

    Only merged field/widget dictionaries are editable. Fields with several widgets are shown read-only. Hierarchical names are editable at the leaf.
    The reader resolves indirect values down to single numbers (Illustrator/InDesign write `/Rect 291 0 R` pointing at an array of references), so rects, `/DA`, colours and `/A` actions read correctly. A parent field with exactly one `/Kids` widget is read-only with its own message, not reported as linked, and offers "Merge field and widget" (29).
16. **The image placeholder label is stored as `/MK /CA`,** the standard caption key, which viewers do not draw with `/TP 1`. It round-trips without `/PieceInfo`. Sample values and sample images (7.6, "app-only data in PieceInfo") are not persisted yet. Both live in the model only (the sample image as a file path), are excluded from the save diff (`FieldDef.persistentForm`), and only the in-memory Preview build uses them: sample text as `/V`, the sample image as `/MK /I` drawn with the field's `/IF`.

## Fonts and appearances

17. **Base-14 Helvetica (`/Helv`, WinAnsi) instead of the embedded Noto Sans** (7.6). S2's encoding choice (A or B) is not settled, and embedding Noto Sans before then risks picking the wrong encoding.
    - Field values are written as UTF-16BE text strings, so fillers receive the right characters.
    - The stored appearance draws characters outside WinAnsi as `?`.
    - The inspector says that Romanian diacritics need a font supplied by the filling code. S9 shows that this works with pdf-lib (`updateFieldAppearances(noto)`) and with PyMuPDF (`insert_textbox` with a font file).
    - The Noto Sans TTF is available as `Tests/Fixtures/NotoSans-Regular.ttf`, for S2.
18. **No separate TextLayout module yet.** `Appearance/AppearanceBuilder.swift` measures with CoreText's Helvetica, which shares the base-14 metrics, and handles single-line alignment, multiline word wrap and comb. The canvas draws the default value with AppKit. So canvas, Preview and stored appearance agree closely but do not share one layout engine as 7.6 intends.
19. **Cedilla to comma-below conversion on input** (7.6) is not implemented.

## Shape cut (M3)

20. **`CutWriter.swift` is a port of `spikes/cut.py`, with the S5 spec changes applied:**
    - `/OrigContents` is always stored;
    - XObject mode adds `/OrigResources` (null when the resources were inherited) and `/XObjectRef`;
    - the page gets `/LastModified`;
    - keys are removed with `pdf_dict_del`;
    - arcs are written as cubics of at most 90 degrees.

    On removal, the app's `/PieceInfo /VoucherEditor` entry is deleted, along with `/PieceInfo` itself when it becomes empty (S5 finding 8, mostly addressed). `/LastModified` is updated, not removed.
21. **Cuts are refused on signed documents as a whole,** not per signed page. The save checks flag it, and the engine throws.
22. **The outline editor covers the following:**
    - placing points by click, with Shift for 0/45/90 degrees; clicking the first point or pressing Return closes the path;
    - "New from Rectangle" and "New Voucher Shape" presets;
    - dragging points, with snapping to the 1 pt grid and to other points' x/y;
    - Option-click on a segment to insert a point, and Delete to remove one;
    - line/arc per segment, a CW/CCW toggle, and dragging an arc's centre along the chord bisector;
    - numeric point x/y.

    Not built:
    - snapping to page and field edges;
    - control-handle editing for curve segments (they are kept and drawn);
    - moving or scaling the whole outline;
    - the table of all points.
23. **Recovering a missing `/PieceInfo` from the marker** is detected and reported as a note, but not rebuilt automatically yet. `CutCodec.outline(fromStartStream:)` exists and is tested.

## Spike-driven changes (from RESULTS.md) applied in code

24. **Approval signatures:** the save check warns for any signature, not only certification (S3 finding 1). pyHanko's diff policy rejects added fields after an approval signature, even though the signed bytes stay intact.
25. **Image fields that code draws into:** the inspector hint documents "draw, then delete the widget" for PyMuPDF and pypdf (S9 finding 1). The placeholder keeps its opaque background for now; making it transparent needs S4 in Acrobat.
26. **The pypdf clone warning** on cut templates (S9 finding 2) is accepted. The `/PieceInfo` refs stay indirect, so tools that rewrite the file renumber them correctly.

## Verification approach

27. **The Swift engine's output was checked with the Python spike tooling.** `swift test` writes `spikes/out/swift/swift_fields_and_cut.pdf`. Then `S9_TEMPLATE=out/swift/swift_fields_and_cut.pdf ../.venv/bin/python s9_fill.py` passes all 104 checks, and libqpdf is clean on it.
28. **The UI was checked by rendering the window to PNG from inside the app** (`VE_SNAPSHOT_DIR`, see README). `screencapture` fails in this environment ("could not create image from display"). Interaction is covered by `VoucherEditorAppTests`, which sends synthesized mouse and key events to the real overlay in an off-screen window. It was not clicked by a person.

## Merge field and widget

29. **"Merge field and widget" turns an Illustrator/InDesign field + single `/Kids` widget into one merged dictionary** (`MuPDFEngine/WidgetMerger.swift`). Inspector button next to the read-only reason, and the field list's context menu.
    - **Detection:** a terminal text or image field (it has `/FT` or inherits it) whose `/Kids` holds exactly one widget annotation (`/Subtype /Widget`, no `/T`, no `/Kids`, `/Parent` back to the field), listed in a page's `/Annots`. The reader runs the same plan the save runs, so refusals and conflicts are shown before the button is pressed.
    - **Refused:** signed documents (the merge rewrites the field after the signature; validators report it), more than one kid, a kid with its own `/T` (a real hierarchy), a field that is not terminal, signature fields. The button is disabled with the reason; the engine throws if it is reached anyway.
    - **Which object survives:** the field object. `/AcroForm /Fields`, a higher parent's `/Kids` and `/CO` already point at it and stay unchanged; the fully qualified name cannot change. The field drops `/Kids` and gains the widget's keys. Every reference to the widget anywhere in the file (page `/Annots`, `/OBJR /Obj` in the structure tree, other annotations' `/Parent`/`/IRT`, form-action `/Fields` lists) is pointed at the field, found by scanning every object; an array that already lists the field drops the widget entry instead (no duplicates). The old widget object is replaced by `null` in the update.
    - **Inherited values** (`/FT /Ff /V /DV /DA /Q /DS /RV /MaxLen`) missing on the field are copied down from the nearest ancestor. The field keeps its own `/Parent`, so a hierarchical field stays hierarchical (the existing hierarchical-name warning applies).
    - **Conflicts** (a key on both with different values): field-semantic keys (`/T /TU /TM /FT /Ff /V /DV /MaxLen /Q /DA /DS /RV /Opt /TI /I /Lock /SV`) keep the field's value (inherited values count as the field's); every other key is an annotation key and keeps the widget's (`/Rect /P /F /MK /BS /AP /AS /A /Border /OC /StructParent /Type`...). `/AA` is merged per trigger: `K F V C` from the field, the rest from the widget. `/P` is set to the page whose `/Annots` lists the widget. Nothing is dropped silently: each conflict is listed in the inspector before merging and in the save summary.
    - **Key-level and lossless:** values are copied as MuPDF prints them (`getSyntax`/`setSyntax`), not through `PDFValue`, so numbers keep their precision. The appearance is not regenerated by the merge, so it looks identical (pixel-identical renders in MuPDF and PDFium on the real template).
    - **Undo:** the command is one model step (`origin.mergeWidgetOnSave`, field becomes editable at once); the next save applies it. Undo before saving is exact. Undoing past a save shows the field read-only again but the file stays merged; merging again is then a no-op (the plan sees an already merged dictionary). Going back to the unmerged file needs the earlier bytes (the original prefix is intact; "Revert to version" is not built yet).

## Crop fields to the outline

30. **"Crop fields to outline" (outline inspector, per document, on by default) crops fields that cross the cut, chosen from spike S10** (`spikes/s10_crop.py`, RESULTS.md S10). The cut clips page content only; widgets and whatever filling code appends to the page are outside it (SPEC 5.3). Code: `MuPDFEngine/FieldCropper.swift`, run by `TemplateWriter` after the field and cut edits on every page that has or had a cut.
    - **Appearance clip:** each appearance stream (/N, /R, /D, or each state) of a widget not fully inside the outline is replaced by a wrapper form `q <outline in the form's space> W n /VEAP Do Q` that references the original stream, plus the widget's /MK /BC border stroked along the outline inside the rect. The original stream is never modified; unwrapping sets /AP /N back to the reference. A field moved fully inside, a regenerated appearance, an edited outline, the setting turned off and a removed cut are all handled by one idempotent pass that writes only differences.
    - **Cover annotation:** a /Watermark annotation (Print, ReadOnly, Locked, LockedContents; `/NM (VoucherEditor cover)`), kept last in /Annots, whose appearance fills the page box minus the outline with white. It hides what fillers draw or flatten into the page outside the shape. Outside the cut the page is blank, which viewers show as white, so it is invisible on the template. The Edit canvas hides it like the widgets.
    - **Storage:** `/CropFields true|false` and `/CoverAnnot` in the page's cut dictionary. A cut saved before this (no `/CropFields`) reads as off, so opening an old file never changes its widgets.
    - **Known limit, shown in the inspector help and the save-check note:** an appearance the filling code rebuilds without flattening (pdf-lib `setImage`/`setText`) is not cropped in MuPDF or PDFium (Chrome), which draw widgets above every other annotation. "Fit to Outline" (field inspector, shown for a crossing field) shrinks the field to the largest rectangle inside the outline (`Geometry.largestRect`), which avoids it.
    - **Rejected:** leaving the clip open after the page content (spike option B). PyMuPDF rebalances q/Q before drawing, so it does not crop `insert_image`; it never reaches widgets; and it breaks the q/Q balance that ISO 32000 requires and the S5 guard protects.
    - **Checks:** with cropping on, a field crossing the outline is information (new `SaveIssue.Severity.info`: listed, never opens the save sheet, not counted as a warning), not a red edge on the canvas; a field fully outside stays a warning (cropped, it is invisible). With cropping off the old warnings apply. "Keep fields inside outline" is unchanged.
    - **Canvas and Preview:** the overlay draws a cropped field's background, border, value and label only inside the outline, with its border along the outline and a faint dashed edge for the full /Rect; Preview is built by the same writer, so sample text and sample images are cropped.

## Smart outline (tracing the page's own artwork)

Requested after M3; the spec lists it as Later. Code: `Sources/VoucherTrace` (pure algorithms, tested on synthetic rasters), `OverlayView.swift`, `TraceProvider.swift`, `SmartOutlineSettings.swift`.

- **Raster:** CoreGraphics renders the page (content only, no widgets) at 150 dpi in user space, ignoring /Rotate, so raster and outline share coordinates and the PDFView conversions handle rotation and the CropBox origin. Not MuPDF: the shim has no render call and MuPDFEngine was being edited in parallel. If the saved bytes carry a cut on the page, the engine's in-memory preview build removes it first, so the clip never hides artwork.
- **Edges:** luminance, a light blur, gradient magnitude plus a thin-line (ridge) response, so a 1-2 px stroke is one band centred on the line. Robust scale and noise floor come from percentiles; "Edge sensitivity" moves the knee.
- **Magnetic segments:** a live wire (Dijkstra with a bucket queue, 8-connected) from the last anchor, expanded lazily and capped per mouse move. Anchors snap to the strongest corner (structure tensor) or the nearest strong edge within "Edge snap radius" (screen px). Shift gives a straight segment; Cmd or Option places a click without snapping. A path that mostly crosses empty page becomes a straight segment.
- **Fitting (5.6.3, a Swift port and extension of `spikes/fitting.py`):** sub-pixel refinement onto the edge ridge, corners detected on the polyline, then greedy lines (total least squares) and circle arcs between corners within the tolerance. Vertices are the intersections of neighbouring primitives, which re-sharpens the corners the trace rounds off. After that come the fitting.py passes (merge collinear lines, orthogonal snap, merge co-circular arcs, shared x/y snap) and an arc refit through its end points. Curves are never produced; freeform art becomes short lines and arcs.
- **Auto-detect shape:** flood fill of similar colour at the click. A click on the background that reaches the page border takes the largest region it surrounds. The outer boundary goes through the same fitting.
- **Validity:** the result must pass `Geometry.validate`. A crossing trace is retried at half the tolerance, then refused with a message, and the anchors are kept so Delete can remove the last one.
- **Undo:** one step per finished outline ("Trace Outline" / "Detect Outline"), as for the click-drawn outline. Anchors placed before closing are not undo steps; Delete or Cmd-Z removes the last one, as before.
- **Defaults:** smart on, tolerance 0.5 pt, sensitivity 0.5, snap radius 8 px, colour threshold 40. They are stored in UserDefaults (`TracePrefs`). With smart off, the outline tool behaves exactly as before.
- **Known limits:** a stroke wider than about 2.5 px at 150 dpi (over about 1.2 pt) has two edges, and the trace may follow either side (up to half the stroke width off). Soft gradients and photos give weak or noisy edges, so anchors are needed closer together. Where the artwork has two near-parallel edges (a fill and a slightly offset die line), the trace can switch between them.

## Not done (MVP list gaps)

- SVG import and PNG tracing (M4). The Python importer in `spikes/svg_import.py` is ready to port.
- Noto Sans embedding and S2's encoding choice. TextLayout as a shared module. Cedilla conversion.
- Preview is basic:
  - sample text, or the field name when no sample is set, in an in-memory build shown by PDFKit with widgets visible;
  - no MuPDF side-by-side toggle.
- S6 alignment checks on `/Rotate 90` pages and offset CropBoxes. The overlay uses PDFView's convert functions as the spec says, but only unrotated pages with a zero-origin MediaBox were exercised.
- Multi-select, align, distribute, tab order, linked fields, Save As Compacted, field map export, and Revert to an earlier `%%EOF` (all v1 or later).
- Encrypted files that need a password are refused on open.
