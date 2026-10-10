# PDF Voucher Editor: Product and Technical Spec

Status: draft 3.1, 2026-10-10. Standalone macOS tool. Draft 1 included a fill/export workflow, which is dropped; draft 3 adds a shape cutter; draft 3.1 records the owner's decisions, the main one being that templates are filled by code. Platform: macOS 27, Xcode 27, Swift 6.4.

## 1. Overview, goals, non-goals

This is a native Mac app for preparing a fillable PDF template, of the kind Acrobat Pro's "Prepare Form" produces, plus a shape cutter. The typical input is a landscape voucher (about 842 x 595 pt) with a few text slots and two image slots. The app does three things:
- adds and edits **AcroForm fields**: text fields, and real Acrobat image fields;
- lets the user define a **custom outline** (straight segments, arcs and curves, e.g. a stepped left edge and a semicircular right end) and **cuts the page** to it, so the saved PDF looks die-cut in any viewer. The outline can be drawn by hand, or imported from an SVG or traced from a PNG. "Cut" means clipping the page content: everything outside the outline becomes blank page. It is not a printer cut line and not a page-box change;
- shows a **Preview** of the layout with sample text and images.

The template is then **filled by code in other apps**, with libraries such as pdf-lib, PyMuPDF, pypdf or iText; it is not filled by hand, and not in this app. That makes the primary consumer of the saved PDF a form-filling library, so the template must be predictable for code (section 6).

Goals
- Author and edit text fields and image fields visually, with an inspector for every property that matters.
- **Code-fillable templates:** stable unique names, one widget per field, a flat hierarchy, parseable `/DA`, correct rects and pages. The app checks all of this on every save (section 6).
- Image fields are push-buttons that code can find by name and read the rect of. The Acrobat click-to-insert action (`event.target.buttonImportIcon();`) is a nice-to-have: written by default, with a toggle in the inspector.
- The shape cut renders the same in Preview, Chrome and Acrobat Reader, and survives filling and flattening by the common libraries. It stays re-editable and reversible, and the original page content is never rewritten.
- Text filled by code renders correctly with Romanian diacritics (ă â î ș ț), provided the filler uses the template's font or supplies a Unicode font (S2).
- Open any PDF robustly, and never damage what the app does not understand: existing JS actions, signatures, other fields, unknown objects.
- Mostly one template, edited occasionally: everything must be discoverable and safe, rather than fast for a power user.

Non-goals
- Filling and exporting vouchers, flattening, batch/CSV. Preview is a helper, not an output.
- General PDF editing: page content, text, page reordering.
- XFA editing, executing JavaScript (it is written and preserved, never run), signing, OCR, auto-detecting fields, Windows/iOS.

## 2. User and primary workflows

There is one user, the owner. They are technical and edit one main template now and then. They may not remember PDF form details between sessions, so the inspector explains what each setting does for filling libraries and viewers.

**W1. Prepare fields.** Open the PDF and draw text fields and image fields over the artwork. Name them and set font, size, colour, alignment, flags, and the image fit. Save. The result is the same PDF plus real AcroForm fields, appended as an incremental update.

**W2. Cut the shape.** Switch to the Outline tool. Draw the path, or import it with "Import Outline from SVG..." or "Trace Outline from PNG..." (section 5.6). Adjust the points, check the cut in Preview, and save. Later, reopen the file, change the outline and save again, or remove the cut entirely; the page content comes back exactly as before.

**W3. Preview.** Toggle Preview (Cmd-P) to see the page as a filled voucher: sample text in every text field and a sample image in every image field, using the field's own fit settings, with the cut applied. Nothing is written to the template.

**W4. Edit an existing template.** Open a PDF that already has fields, possibly made in Acrobat, and edit them in place. Fields the app does not support are shown read-only and preserved. Renaming a field warns that code filling the template by name will break, and the save sheet lists every rename since the last save.

**W5. Hand over to code.** The filling code addresses fields by name and page. The save checks (6.2) guarantee the structure; the suggested field-map export (v1) documents it.

## 3. Features

Field types
- **Text field** (MVP): `/FT /Tx`.
- **Image field** (MVP): `/FT /Btn` push-button (`/Ff` bit 17, value 65536), `/MK /TP 1` (icon only), with optional mouse-up JavaScript action `event.target.buttonImportIcon();`. The structure is copied from an Acrobat-made image field (spike S4).
- **Checkbox, dropdown, radio** (Later). Existing ones are shown read-only and preserved.

Inspector, text field
- Name (`/T`, unique, validated), tooltip (`/TU`).
- Required, read-only (`/Ff` bits 2 and 1).
- Font (embedded; bundled Noto Sans by default, see 7.6), size (a number; Auto = 0 is allowed but warned, because fillers handle it inconsistently), text colour (in `/DA`).
- Alignment left/center/right (`/Q`).
- Multiline (bit 13), do-not-scroll (bit 24), max length (`/MaxLen`), comb (bit 25, requires max length).
- Default value (`/V` and `/DV`); sample value (Preview only, never written as `/V`).
- Border colour and width, background colour (`/MK /BC /BG`, `/BS /W`).
- A hint line explains how fillers treat the setting, for example "Auto size: pdf-lib shrinks to fit; PyMuPDF and pypdf use a default size".

Inspector, image field
- Name, tooltip, required, read-only.
- Fit (`/MK /IF`):
  - scale when: always / image too big / image too small / never (`/SW /A /B /S /N`);
  - scale how: proportional / stretch (`/S /P /A`);
  - alignment: 9-point grid plus numeric x/y 0 to 1 (`/A [x y]`);
  - fit to bounds, ignoring the border (`/FB`).
- Placeholder appearance: background colour, border, label (default "Click to add image").
- Sample image for Preview only (not written).
- "Acrobat click-to-insert action" toggle (default on). It is harmless to code fillers, but some security scanners flag any JS, so it can be turned off.
- The fit settings are hints. Most filling libraries ignore `/IF` and place images themselves; the field map records the intended fit.

MVP
- Open PDF; page thumbnails; zoom/scroll; field list sidebar (type icon, name, warnings).
- Create, select, move, resize, delete, rename, duplicate fields. Arrow nudge; undo/redo; numeric rect entry.
- Read and edit existing AcroForm fields (text and push-button); others are read-only and preserved.
- Appearance streams for every widget the app adds or changes; no `/NeedAppearances`.
- Outline editor and page cut (section 5); cut stored re-editably in the PDF; remove cut.
- Outline import: SVG (5.6.1); PNG tracing from the alpha channel or a brightness threshold, with a tolerance control (5.6.2).
- Preview mode.
- Incremental (append) save. Programmatic-fill checks on save (6.2). Warnings: signed document, document contains JS, XFA present, file needed repair, field partly outside the outline.

v1
- Multi-select, align, distribute, match size, snapping guides for fields, optional grid.
- Tab order editor: sidebar list, writes the `/Annots` order and `/Tabs /S`.
- Linked fields (same name, several widgets).
- Import refinements:
  - PNG "drawn outline" mode (a stroked line drawing rather than a filled shape);
  - choosing among several shapes in one SVG or PNG;
  - SVG `<use>`/`<symbol>`.
- "Save As Compacted" (full rewrite) for unsigned files.
- **Suggested, for the owner to accept or drop: Export field map** (6.3).

Later
- Checkbox, radio, dropdown; outline presets library; tracing an outline from the page's own artwork; field auto-detection.
- Shapes with holes, or several shapes on one page.
- Print finishing extras (a `CutContour` die-line layer, TrimBox from the outline). These are deliberately not part of the cut.

## 4. UI layout and interactions

```
+----------------------------------------------------------------------------+
| [<] [>] voucher-template.pdf  [ Edit | Preview ]  [V] [T] [Img] [O]  100% v |
|                                [Align v] [Distribute v] [Cut: on]  [Save]  |
+-----------+----------------------------------------------+-----------------+
| PAGES     |    _______________________________________   | INSPECTOR       |
| +-------+ |   |__                                     \  | Image field     |
| |  1 ## | |      |  +-----------+   VOUCHER            | | Name [photo   ] |
| +-------+ |    __|  | photo     |   [recipient_name]   | | Scale  always v |
| +-------+ |   |__   | (click to |   [valid_until]      | | How    propor. v|
| |  2    | |      |  |  add)     |   [code] <selected>  | | Align  [9-grid] |
| +-------+ |    __|  +-----------+                     /  | [ ] Fit bounds  |
| FIELDS    |   |_____________________________________/    | Placeholder [#] |
| T code    |   (outside the outline dimmed)               | Sample [pick..] |
| I photo   |                                              | Rect x y w h    |
| OUTLINE   |                                              |                 |
+-----------+----------------------------------------------+-----------------+
| Page 1 of 2  5 fields  Cut on page 1  Saved (incremental)  ! contains JS   |
+----------------------------------------------------------------------------+
```

The left sidebar has page thumbnails, the field list (drag to reorder tab order in v1) and an Outline entry per cut page. On the right is the inspector for the selected field, outline point or segment. Warnings appear in the status bar and the field list; clicking one selects the item.

Interactions, fields
- **Draw:** pick a tool (T, Img) and drag; a click without dragging creates a default-size field. The tool reverts to Select unless Option is held.
- **Select:** click, Shift-click, or marquee (v1). Tab / Shift-Tab cycles fields in tab order.
- **Move and nudge:** drag; arrows nudge 1 pt, Shift-arrows 10 pt.
- **Resize:** 8 handles; Shift keeps the aspect ratio (default on for image fields), Option resizes from the centre.
- **Duplicate:** Cmd-D (offset 10 pt, name suffixed `_2`); Option-drag duplicates in place.
- **Snapping (v1):** to other fields' edges and centres, the page centre and the outline, with guide lines; Cmd disables it.

Interactions, outline (O tool)
- **Create:** click points to place them; Shift constrains to 0/45/90 degrees; clicking the first point closes the path. "New from rectangle" is a quick start.
- **Edit:** drag points; Option-click a segment to insert a point; Delete removes a point. The context menu or the inspector switches a segment between line, arc and curve.
  - An arc has a centre handle. Dragging an end point keeps the arc valid by moving the centre along the perpendicular bisector.
  - A curve (cubic Bézier, mostly from imports) has two control handles.
  - "Simplify segments" re-runs the primitive fitting (5.6.3) on the selected segments.
- **Numeric:** the inspector edits point x/y, and an arc's centre, radius and direction. A table lists all points.
- **Snapping:** to the 1 pt grid, to the x/y of other points (essential for the steps), to page edges and to field edges, with guide lines; Cmd disables it.
- **Display:** the outside of the outline is dimmed in Edit mode and shown as it will render in Preview.

Undo/redo: every model command (field create/move/resize/property change/delete, outline point edit, cut on/off) is one step on the document's single undo stack. Continuous drags coalesce into one step. Saving does not clear undo.

Shortcuts: V select, T text field, I image field, O outline, Cmd-P preview, Cmd-D duplicate, Delete, Cmd-Z / Shift-Cmd-Z, Cmd-A select all on page, Cmd-S save, Cmd-+ / Cmd-- / Cmd-0 zoom, Cmd-9 zoom to fit.

## 5. Shape cut

### 5.1 Geometry

An outline is one closed path per page, in PDF user space (points). It starts at a point and has a list of segments. Each segment is one of:
- a **line** to a point;
- a circular **arc** to a point, around a centre, clockwise or counterclockwise;
- a cubic Bézier **curve** with two control points.

Arcs are written to PDF as cubic Béziers of at most 90 degrees each (error under 0.03 percent of the radius). Lines and arcs are preferred, because they are exact and easy to edit numerically; curves exist for imported shapes that are neither. The path must be closed and must not self-intersect; the app enforces both. One outline per page; any page can have one, and the usual case is page 1 only.

### 5.2 How the cut is applied: real clip, original content untouched

The page's `/Contents` (a stream or an array) becomes:

`[ cutStart, <original content streams, unchanged>, cutEnd ]`

- `cutStart` is a new stream with `q <outline path> W n q`.
- `cutEnd` is a new stream with `Q Q`.

The original stream objects are not modified, so a cut can always be removed without loss. The inner `q ... Q` keeps the original's own graphics state from leaking.

**Guard:** the original content is parsed with MuPDF to check that `q/Q` is balanced. An extra `Q` in the original would pop the clip. If the content is unbalanced (rare, but real PDFs do it), the app falls back to wrapping the original content in a Form XObject: a new page content of `q <path> W n /OrigContent Do Q`, with the original streams referenced as the XObject's data where possible. The page dictionary's original `/Contents` and `/Resources` refs are stored for reversal.

Other approaches were considered:
- **Only a visible cut line, or a white mask drawn on top:** this is not a cut. The artwork stays under the mask, a white mask is wrong on coloured backgrounds, and copy-paste or selection still exposes the content. Rejected.
- **Shrinking CropBox or TrimBox:** this is rectangular only, so it cannot make the shape. Rejected, and page boxes are left unchanged.
- **Rewriting the content to remove what lies outside:** this destroys the original and is not reversible. Rejected.
- **A transparency soft mask:** heavier, renders inconsistently across viewers, and offers nothing over a hard clip for a vector outline. Rejected.

Outside the outline, nothing is painted, so viewers show the page background: white in Preview, Chrome and Acrobat. The app makes no attempt at a "transparent" page, because PDF pages have none.

### 5.3 Form widgets and the cut

Annotations are drawn on top of the page content and are **not** affected by the content clip. The same is true of anything a filler appends to the page after the cut's end stream: flattened widget appearances (pdf-lib `form.flatten`, PyMuPDF, pypdf) and images drawn at a slot's rect (PyMuPDF `insert_image`, pdf-lib `drawImage`). Because the cut ends with its own `Q Q`, appended content starts from a clean graphics state, so nothing breaks; it is simply not clipped. A field that crosses the outline therefore shows outside the shape.
- **Decided:** a warning on every field not fully inside the outline, shown in the field list and as a red edge on the canvas. "Keep fields inside outline" (on by default) constrains move and resize.
- **Option, for image fields that should bleed to the shaped edge:** add a **cover annotation**. This is a non-interactive annotation (flags Print and ReadOnly, with no interaction) placed after the widgets in `/Annots`. Its appearance fills the page rect minus the outline (even-odd) with the page background colour, so it hides any widget overflow. It cannot make a background transparent, so it is offered only when the area outside is white. Flattened content lands in the page content, which is always below annotations, so it stays covered, unless the filler also flattens every annotation. It is spike S5's question whether all three viewers draw it above widgets. Off by default, v1.

### 5.4 Storage and reversal

Everything about the cut lives in the page's private dictionary, so the cut is re-editable without a sidecar:

`/PieceInfo /VoucherEditor << /LastModified (date) /Private << /Cut << /Version 1 /Start [x y] /Segments [[/L x y] [/A x y cx cy /CW] [/C x1 y1 x2 y2 x y] ...] /StartRef r /EndRef r /Mode /Wrap|/XObject /OrigContents r /CoverAnnot r /Source << /Kind /SVG|/PNG|/Drawn /File (name) /Tolerance t >> >> >> >>`

- **Edit:** replace `cutStart` (a new stream object in the next incremental update) and update `/Segments`.
- **Remove:** restore `/Contents` (or `/OrigContents`) and `/Annots`, then drop `/Cut`.
- `/Source` is informational only, so the inspector can say where an outline came from. The imported file itself is not embedded.
- **Missing PieceInfo** (for example, the file was re-saved by another tool that drops it): the app recognises its own `cutStart` and `cutEnd` streams by a marker comment (`% VoucherEditor cut v1`) and offers to rebuild the outline from the clip path.

### 5.5 Placing an imported shape

An import produces an outline in the source's coordinates, which is then mapped to the page.
- **Fit to page (default when the source's aspect ratio matches the page within 1 percent):** the SVG viewBox, or the PNG's full pixel area, maps onto the page MediaBox. This is the normal case for a page-sized artboard or a full-page mask.
- **Actual size:** SVG user units at 96 per inch (1 px = 0.75 pt) after its `width`/`height` units; PNG at its stored DPI, or 72 if none. The shape is centred on the page.
- After placement the outline can be moved and scaled as a whole (bounding-box handles; Shift keeps proportions) before point editing.
- The y-axis is flipped, since SVG and images run y-down and PDF runs y-up.
- The import is one undo step.

### 5.6 Import

#### 5.6.1 SVG (MVP)

A Swift-native parser built on Foundation's `XMLParser`, about 600 lines and no dependency. Supported:
- **Elements:**
  - `path`, with all `d` commands, absolute and relative: M L H V C S Q T A Z;
  - `rect` (including `rx`/`ry`), `circle`, `ellipse`, `polygon`, `polyline`;
  - nested `g`.
- **Transforms:** `transform` on any element or group (`matrix`, `translate`, `scale`, `rotate` with an optional centre, `skewX`, `skewY`), composed down the tree. The root `viewBox`, `width`/`height` (px, pt, mm, cm, in) and `preserveAspectRatio` are honoured.
- **Geometry conversion, keeping primitives exact where possible:**
  - L/H/V become lines;
  - C/S become curves;
  - Q/T are raised to cubics;
  - A becomes a circular **arc** when rx = ry and the accumulated transform is a similarity (uniform scale, rotation, translation); otherwise it is converted to curves (at most 90 degrees each);
  - `circle` becomes two arcs; `rect` with radii becomes lines plus quarter arcs; a non-uniformly scaled circle becomes curves.
  - A "Detect lines and arcs" pass (5.6.3) runs afterwards, because many editors export everything as cubics.
- **Choosing the shape:** the first closed subpath with the largest area is chosen. If there are several closed shapes, a list lets him pick one; that picker is v1, and MVP takes the largest. Open subpaths are ignored with a note.
- **Not supported, reported in the import sheet:** CSS stylesheets and `style` attributes that change geometry, `<use>`/`<symbol>` (v1), `clipPath`, `mask`, text, and holes (inner subpaths are dropped with a warning). Stroke width is ignored: a stroked line imports as its centre line, and the sheet says so.

Rejected alternatives: **nanosvg** (a single-header C parser) flattens everything to cubic Béziers, losing which segments were lines and arcs; it is kept only as a test oracle for path parsing. **SVGKit** and **WebKit**-based parsing are far heavier than needed, built for rendering rather than geometry.

#### 5.6.2 PNG tracing (MVP, "drawn outline" mode v1)

Pipeline, with a live preview of the traced path over the image in the import sheet:
1. **Load** with ImageIO (PNG, and also JPEG/TIFF/HEIC for free) and pick a channel: **alpha** (default when the image has transparency; the shape is the opaque or the transparent region, with a toggle) or **brightness threshold** (slider 0 to 255, with an invert toggle).
2. **Clean up:** remove specks smaller than N px (slider), and fill pinholes.
3. **Region:** the largest connected region; its outer boundary is traced.
4. **Trace** with **potrace**, which gives a corner-aware vector path of cubic curves and straight corners.
5. **Fit primitives** (5.6.3) to the potrace output.
6. **Place** (5.5), then the points are editable like any outline.

Controls:
- **Tolerance** in pt on the page, default 0.5 pt. It drives potrace's `opttolerance` and the fitting error.
- **Corner threshold** (potrace `alphamax`).
- A readout of the segment count and the maximum deviation from the pixel boundary.

"Drawn outline" mode (v1) handles a line drawing on paper or a stroked shape. It flood-fills from the image border, takes the enclosed region, and offers inner edge, outer edge or centre line of the stroke.

**Library choice: potrace** (C, about 10 kLOC, no dependencies, no longjmp). It is the reference tracer for bitmap-to-vector. It outputs smooth cubics with real corners and has a tolerance parameter that maps directly onto the UI control; it is built into the same xcframework as MuPDF, with a tiny wrapper. Its licence is GPL v2 or later, which is compatible with the AGPL v3 combination; this is personal use, noted alongside MuPDF.

The Swift-native alternative is **Vision `VNDetectContoursRequest`**, which returns pixel contours with `polygonApproximation(epsilon:)` (Douglas-Peucker). It is free and native, but its output is polygons, so the semicircle becomes dozens of tiny lines unless the app writes its own curve fitter. Spike S8 compares the two on the same inputs; Vision is the fallback if potrace's build or quality disappoints.

#### 5.6.3 Primitive fitting and simplification

This runs after both imports and on demand ("Simplify segments"), within the tolerance:
1. Merge runs of nearly collinear segments into **lines**.
2. Snap lines within 0.5 degrees of horizontal or vertical to exact orthogonals; this matters for the steps.
3. Replace runs of curves that fit a circle (least-squares, maximum deviation under the tolerance) with one **arc**.
4. Keep the rest as **curves**, merging adjacent ones where a single cubic fits.
5. Snap end points to shared x/y within the tolerance.

For the reference shape (stepped left edge with 3 steps, semicircular right end), the target is about 8 lines plus 1 arc.

## 6. Programmatic-fill friendliness

The saved PDF is read by code far more often than it is opened in a viewer, so the structure is part of the product.

### 6.1 Rules the app follows when writing

- **Names:** unique, non-empty, stable. The suggested pattern is `[a-z][a-z0-9_]*` (snake_case). Dots are not allowed in new names, because they create hierarchy (`a.b`), and new fields are top-level entries in `/AcroForm /Fields`. Existing hierarchical names are preserved but flagged.
- **One widget per field:** field and widget are a single merged dictionary, so `widgets[0]` (pdf-lib), `page.widgets()` (PyMuPDF) and `/Annots` lookups (pypdf) all find exactly one rect. Linked fields (v1) are the only exception, and are shown as such.
- **Placement:** `/Rect` is normalised (x1 < x2, y1 < y2), in unrotated user space, inside the page MediaBox; `/P` points to the page; the widget is listed in that page's `/Annots`; `/F 4` (print).
- **`/DA`:** always the minimal, parseable form `/<FontName> <size> Tf <r> <g> <b> rg`. The font name is plain ASCII (for example `/NotoSans`) and present in `/AcroForm /DR /Font`, with a matching `/AcroForm /DA` default. No extra operators, and no `g`/`k` colour variants.
- **`/Ff`:** only the bits set in the inspector. The app refuses conflicting combinations (comb without `/MaxLen`; comb with multiline, password or file select).
- **Values:** `/V` and `/DV` are written only when a default value is set. Sample values are never written. Stored appearances for empty fields contain only the background and border, never sample text.
- **Image fields:** push-buttons (`/Ff` 65536), each with a unique name and one widget, so code can do `getButton(name)` and read its rect, then either set an image appearance (pdf-lib `setImage`) or draw at the rect (PyMuPDF `insert_image`).

### 6.2 Checks on save

These run on every save and are listed in the save sheet. Errors need an explicit "Save anyway"; warnings are listed only.

Errors
- Empty name, or a duplicate fully qualified name.
- A field with more than one widget (not marked as linked).
- A widget not in its page's `/Annots`, missing `/P`, or a field missing from `/AcroForm /Fields`.
- `/Rect` with zero or negative size, or outside the page.
- `/DA` not parseable, or its font missing from `/DR`.
- Conflicting `/Ff` bits.

Warnings
- A field on an unexpected page: anything other than page 1, or the page that has the outline.
- Names that differ only in case; names with spaces, dots or non-ASCII characters; a hierarchical name.
- Auto font size (0); comb or max length (filler support varies).
- A non-empty `/V` (the filler's output will show it if code does not overwrite it).
- A field partly outside the outline; two fields overlapping.
- A page with `/Rotate` (code that uses raw rects may place content rotated).
- Fields renamed since the last save (listed by old and new name).

### 6.3 Export field map (suggested v1, for the owner to accept or drop)

"File > Export Field Map..." writes JSON (and optionally CSV), so developers can see the template's contract without opening a PDF tool. For each field it records:
- name, type (text / image);
- page (1-based), rect (x, y, w, h in pt, origin bottom-left);
- font name, size, colour, alignment, flags (multiline, comb, max length, required, read-only), default value;
- for image fields, the intended fit (scale when, scale how, alignment).

It also records the page size and each page's outline path (start point, and segments as line, arc and curve with their coordinates).

The export is generated from the saved file, not from the model, so it describes exactly what code will see. Estimated at 1 day.

## 7. Architecture

### 7.1 Stack (decided)

**Swift 6 app, with a SwiftUI shell and an AppKit canvas. PDFKit for display. MuPDF (C, AGPL, acceptable for personal use) as the only reader and writer, through a small C wrapper.**

MuPDF provides the object API to build any dictionary, incremental save, content parsing (for the q/Q balance check), rendering for Preview cross-checks, and font embedding. Its JavaScript engine is never enabled (`pdf_enable_js` is never called).

### 7.2 Display vs writing

- **One writer.** PDFKit never writes the file; MuPDF owns the document. PDFKit displays a read-only `PDFDocument` loaded from the bytes MuPDF last wrote, or from the original on open.
- **What PDFKit shows.** It renders page content only: widget annotations (and the app's own cover annotation) are hidden with `shouldDisplay = false`. Fields, the outline and the dimmed outside are drawn by the app's overlay from the model. During editing the two engines therefore never need to be kept in sync, and only one thing (the model) changes on screen.
- **When PDFKit reloads.** Only on save, and when entering Preview.
- **Preview.** MuPDF builds a temporary in-memory copy: sample values as `/V` with regenerated appearances, sample images as `/MK /I` plus appearance using the field's `/IF`, and the cut applied. It is written to memory and shown by PDFKit with annotations visible. A debug toggle shows the MuPDF render of the same bytes side by side, so differences between viewers are visible early.

### 7.3 Modules

```
App          SwiftUI DocumentGroup, menus/commands, Edit/Preview, settings
Canvas       AppKit: PDFView host + OverlayView (fields, outline, handles, guides, dim mask),
             tools, hit testing, snapping
Inspector    SwiftUI views for text field, image field, outline point/segment, page cut
Model        Pure Swift, Codable, no PDF types: Template, FieldDef, Widget, TextProps,
             ImageProps, Outline(start, segments), PageCut. Commands with NSUndoManager.
TextLayout   Line breaking, auto size, alignment, comb from the embedded font's metrics;
             used by Appearance so canvas, Preview and the stored AP agree
Appearance   /AP /N streams: text, image placeholder, image with icon (honouring /IF),
             cover annotation
Geometry     Outline validation (closed, simple), arc -> Bézier, rect-inside-outline, bbox,
             primitive fitting (lines, orthogonal snap, circle fit, curve merge)
Import       SVGImporter (XMLParser, transforms, viewBox), PNGTracer (ImageIO, threshold,
             cleanup, potrace via its C wrapper), placement onto the page
PDFEngine    Swift protocol: open, readFields, readCut, applyChanges, saveIncremental,
             saveFull, renderPreview
MuPDFEngine  Implementation via the C shim
```

### 7.4 C shim and MuPDF build

MuPDF errors use `fz_try`/`fz_catch` (setjmp/longjmp), which must never unwind through Swift frames. Every shim function is plain C, runs its whole body inside `fz_try`, and returns an error code plus a message; Swift sees only those functions. Each `fz_context` is used on one thread (a serial engine queue). MuPDF is built from a pinned stable release by a script into a static xcframework with a module map exposing only the shim header. potrace (pinned release) goes into the same xcframework. It has no longjmp, so its wrapper is a plain function: a bitmap and parameters in, a path out.

### 7.5 Overlay alignment

The overlay works in each page's user space and converts with `PDFView.convert(_:from:)` / `convert(_:to:)`. This handles zoom, scroll, `/Rotate` and a non-zero CropBox origin; the app never changes page boxes. Handles are drawn at a constant screen size; hit testing uses screen-space tolerances (4 px). Spike S6 verifies alignment within 0.5 pt.

### 7.6 Data model and fonts

The **PDF is the source of truth**; there is no sidecar.
- Standard keys hold everything standard: field `/FT /T /TU /Ff /V /DV /MaxLen /Q /DA`; widget `/Rect /MK /BS /F /P /AA`; `/AcroForm /Fields /DR /DA`.
- App-only data goes in page `/PieceInfo /VoucherEditor`: sample values, sample image paths, the cut (5.4), the "keep inside outline" setting.
- The app works without PieceInfo. Any push-button with an icon or an import action is offered as an image field.
- Hierarchical names are read, displayed fully qualified, preserved, and renamable at the leaf. Values outside PDFDocEncoding (ă, ș, ț) are written as UTF-16BE with a BOM.

Fonts: the field font is embedded **fully** (not subset) in `/DR`, so fillers that build appearances from the template's own font (iText, pypdf, Acrobat) have every glyph. The default is **Noto Sans** (decided; bundled, OFL, verified to have comma-below ș ț and their capitals). Any installed embeddable font can be chosen per field. Some fillers ignore the `/DR` font by default: pdf-lib uses its own Helvetica unless the code passes a font to `updateFieldAppearances`, and PyMuPDF maps to its built-in fonts. For those, diacritics need the filling code to supply a Unicode font, which the field map (6.3) and S2 document per library. Spike S2 chooses between two encodings, judged by how code fillers handle them:
- **A.** Simple TrueType, WinAnsi base plus `/Differences` mapping spare codes to `/abreve /Abreve /scommaaccent /Scommaaccent /tcommaaccent /Tcommaaccent` (â î are already in WinAnsi). Most libraries' appearance generators assume a simple font, so this is expected to be the safer choice.
- **B.** Type0 / Identity-H with ToUnicode. Full coverage, but several libraries' appearance generators do not handle composite fonts in `/DA`.

Input: cedilla ş ţ (U+015F, U+0163) is converted to comma-below ș ț on entry (a setting can turn this off). The app writes text appearances from TextLayout rather than MuPDF's own synthesis, so the canvas, the Preview and the stored AP use one layout.

### 7.7 Save pipeline

1. Diff the model against what was read; build a change set (fields added, changed or deleted; cut added, changed or removed).
2. With MuPDF's object API, modify keys in place and never replace whole dictionaries, so existing `/AA`, JS and unknown keys survive. Deleting a field removes it from `/Fields` and `/Annots`.
3. Ensure the font and default `/DA` are in `/AcroForm /DR`.
4. Generate `/AP /N` for every added or changed widget. For text fields this shows the default value or nothing, so the unfilled template looks right everywhere. Do not set `/NeedAppearances` (deprecated in PDF 2.0, makes Acrobat ask to save, ignored by Preview).
   - **Priority:** the stored appearance matters only until code fills the field. After that, the filler either regenerates the appearance from `/DA`, `/DR`, `/Q`, `/Rect` and `/Ff` (pdf-lib `updateFieldAppearances`, PyMuPDF `widget.update()`, iText), or sets `/NeedAppearances` and leaves rendering to the viewer (pypdf's default).
   - Either way, what must be right is the **field definition**, not the app's appearance stream. That is why 6.1 keeps `/DA` minimal and the font in `/DR`, and why S2 and S9 test filled output rather than the template.
5. Apply the cut change (5.2 to 5.4) and write PieceInfo.
6. **Save incrementally (append) by default.** Reasons:
   - The original bytes stay an exact prefix, so everything not understood (JS, signatures, unknown objects, content streams) is untouched by construction, not by care.
   - Signatures stay valid.
   - Saving is fast.
   - The pre-edit file is always recoverable: "Revert to version..." truncates at an earlier `%%EOF`, after confirmation.
   - The cost is file growth on each save; "Save As Compacted" (full rewrite with garbage collection) is offered for unsigned files.
7. If MuPDF had to repair the file on open, an incremental save is impossible: warn and offer Save As (full rewrite).

Signatures: the app warns that adding fields after a certification signature (DocMDP P=1/2) shows as an invalid change in Acrobat even though the bytes are preserved. Signature fields are never touched. **A shape cut changes page content, so it is refused on signed pages.** XFA: a hybrid form is opened, with a warning that Acrobat may show the XFA layer rather than the edited AcroForm; editing pure XFA is refused.

## 8. Technical risks and spikes

Do these in order, before building UI. S1 to S5 can be written in Python with PyMuPDF (the same C library) plus `pypdfium2` and `pyHanko`, then ported to the shim. S2 and S9 also need Node for pdf-lib. Viewers: Preview, Chrome, Acrobat Reader (install Reader first).

**S1. Writer: MuPDF vs PDFKit control (1 day).** On the real voucher template, add 3 text fields and 2 image fields with PDFKit (`PDFAnnotation` widgets + `write`) and with MuPDF (object API + incremental save).
- Pass: the MuPDF output shows editable fields in all three viewers; `/MK /IF` and the JS action are present; the original bytes are an exact prefix.
- The PDFKit result is recorded as the control. Fail: fields missing in any viewer.

**S2. Romanian text filled by code (1.5-2 days).** Text fields in encodings A and B, filled with "Țară Ștefan ăâî ĂÂÎ șț ȘȚ".
- Fillers: pdf-lib (with the template font, and with a code-supplied Noto Sans), PyMuPDF (`widget.update()`), pypdf (with `auto_regenerate`, and with `/NeedAppearances` left to the viewer), and iText if time allows.
- Pass:
  - (a) for each library, the filled output renders the string correctly in Preview, Chrome and Acrobat, in the right rect, size and alignment, both unflattened and flattened;
  - (b) copy-paste or text extraction returns the right characters;
  - (c) lower priority: the template's own default value renders in all three viewers, and typing in Acrobat Reader works.
- Pick the encoding that passes (a) for the most libraries. Record, per library, whether the filler must supply its own font; this goes into the field map notes.
- Fail: no encoding passes (a) for at least two libraries even with a code-supplied font.

**S3. Preservation (1 day).** Inputs: an Acrobat form with document JS and calculate/format/keystroke actions; a PDF with an approval signature; one with a certification signature (made with pyHanko).
- Pass: after adding a field and saving, the extracted JS strings are byte-identical and still work in Acrobat; the approval signature verifies in pyHanko and Acrobat; `qpdf --check` is clean.
- The certification result is documented.

**S4. Image fields (0.5-1 day).** Compare the app's field dictionary with an image field made by Acrobat's "Add Image" tool.
- Pass: the placeholder appearance shows in all three viewers; with the action toggled on, clicking the field in Acrobat Reader opens the image chooser and the inserted image follows `/IF`; with it off, no JS remains in the field.
- The code side is covered by S9.
- Fail: the field is not recognised as an image field by Acrobat.

**S5. Shape cut: store, re-edit, reverse (1.5-2 days).** Apply a stepped-left / semicircle-right outline to the real template.
- Pass, part 1, rendering: render in Preview, Chrome, Acrobat, MuPDF and PDFium; outside the outline is blank in all; the edges agree within 1 px at 150 DPI; Print to PDF from Preview keeps the cut.
- Pass, part 2, re-editing: reopen, change the outline, save; the new clip is used and the old cut streams are no longer referenced.
- Pass, part 3, reversal: remove the cut; the page renders pixel-identical to the original, and the original content stream objects are byte-identical.
- Also test:
  - a fixture with unbalanced `q/Q`, which must take the XObject fallback and still pass the checks above;
  - an outline with a curve segment;
  - the cover annotation in all three viewers: drawn above widgets, clicks inside the outline still reach the image field.
- Fail: any viewer ignores the clip, or reversal is not exact. If only the cover annotation fails, that option is dropped and widgets must stay inside the outline.

**S6. Swift integration (1-2 days).** Build MuPDF as an xcframework with the C shim, then open, render and save from a Swift test target. Overlay a draggable rectangle and an outline on `PDFView`, and check them through zoom, scroll, a `/Rotate 90` page and a non-zero CropBox origin.
- Pass: a deliberately malformed PDF produces Swift errors, not crashes; the overlay stays aligned within 0.5 pt from 50 to 400 percent zoom.
- Fail: misalignment, or longjmp crashes.

**S7. SVG import (1 day).** Inputs:
- the voucher shape exported from Illustrator, Figma, Inkscape and Affinity (page-sized artboards);
- a hand-written SVG with nested groups using every transform type, relative commands, `A` arcs, and `rect` with radii;
- a file scaled non-uniformly.

Pass:
- every point lands within 0.1 pt of the reference geometry after Fit to page;
- the y-flip and viewBox offsets are correct;
- circular arcs survive as arcs, and the non-uniform case becomes curves;
- after "Detect lines and arcs", the cubic-only exports reduce to the expected line and arc count;
- path parsing agrees with nanosvg on all inputs.

Fail: any deviation over 0.1 pt, or a wrong orientation.

**S8. PNG tracing: potrace vs Vision (1-1.5 days).** Inputs:
- a full-page alpha PNG of the shape at 1x and 2x;
- a JPEG photo of a black outline on white paper (for the v1 drawn mode);
- a noisy, anti-aliased variant.

Pass:
- at the default 0.5 pt tolerance, the 2x alpha PNG yields at most 12 segments (target: 8 lines and 1 arc) with a maximum deviation of 0.5 pt from the reference outline (1 pt at 1x);
- the steps come out exactly orthogonal;
- tracing takes under 300 ms for a 2x full page.

Pick the library that meets this with fewer segments and less code. Fail for both: ship SVG import only in the MVP, and move tracing to v1.

**S9. Fill a saved template with common libraries (1-1.5 days).** Take a template saved by the app (fields, image fields, cut on page 1) and fill it with scripts in **PyMuPDF**, **pdf-lib** and **pypdf**: text in every field (including diacritics with the S2 font setup), and an image in each image field (pdf-lib `getButton().setImage()`, PyMuPDF `insert_image` at the widget rect, pypdf by drawing at the rect from a merged page). Save each output unflattened and flattened, then render with MuPDF and PDFium and open in Preview, Chrome and Acrobat.
- Pass:
  - every library finds every field by name, with exactly one widget and the expected rect and page;
  - no library errors or warnings;
  - text lands in the right rect, font size and alignment;
  - images fill their slots as the library places them;
  - the clip is intact: outside the outline is blank, and fields kept inside the outline are fully visible;
  - flattened output renders like unflattened output;
  - the field map export (if accepted) matches what each library reports.
- These scripts become regression tests (section 9).
- Fail: any library cannot find a field or misplaces one, or flattening breaks the cut.

Other risks, no spike needed: the AGPL licence (personal use, noted); repair forcing a full rewrite (warned); encrypted PDFs (open if permitted and save with the same encryption, otherwise refuse to save); file growth from many incremental saves (Compacted save).

## 9. Test plan

Corpus (`Tests/Fixtures`):
- the owner's real voucher template (private, not in the repo), plus an Acrobat-made image field;
- an Acrobat form with JS;
- approval-signed and certified PDFs;
- a rotated page with an offset CropBox;
- unbalanced `q/Q` content;
- hierarchical field names;
- PDF 1.7 with object streams, and PDF 2.0;
- an owner-password encrypted file, and a file that needs repair.

Automated (XCTest, every build)
- Model: commands, undo/redo coalescing, naming rules, PieceInfo round-trip.
- Geometry: closure, self-intersection, arc consistency, arc-to-Bézier error bound, rect-inside-outline, primitive fitting (known inputs give known line, arc and curve counts).
- Import: SVG fixtures (the S7 set) against reference point lists; PNG fixtures (the S8 set) against the reference outline, with maximum deviation and segment count as the assertions.
- TextLayout: line breaking, auto size, comb, alignment, diacritics measurement.
- Round-trip: open, author fields and cut, save, reopen; the model reads back equal.
- Integrity: the original bytes are an exact prefix; JS strings are identical before and after; `qpdf --check` is clean; pyHanko validates the signed fixtures.
- Cut: apply, edit, remove; renders match golden PNGs. After removal, the render is pixel-identical to the original and the original content streams are byte-identical.
- Rendering: each output page is rendered with MuPDF and PDFium at 150 DPI and compared with approved goldens (1 percent tolerance); the two engines must also agree with each other.
- Programmatic fill: the S9 scripts (PyMuPDF, pdf-lib, pypdf) run against every saved fixture template; fields resolve by name, and the filled renders match goldens with the clip intact.
- Save checks: one fixture per check in 6.2 (duplicate names, multiple widgets, field on page 2, empty name, bad `/DA`, conflicting `/Ff`).

Manual matrix (before each milestone, about 20 minutes): open the template in Preview, Chrome and Acrobat Reader. Check:
- fields visible, with borders and defaults;
- the S9 filled outputs, with diacritics;
- image field click-to-insert in Reader, when the action is on;
- the cut shape;
- an SVG and a PNG import of the reference shape;
- printing to PDF;
- the cover annotation, if used.

## 10. Milestones (one developer, full-time days)

- **M0 Spikes S1 to S9:** 10.5-13.5 days. Exit: font encoding chosen, image field structure confirmed, cut mechanism confirmed, tracing library chosen.
- **M1 Skeleton:** document app, MuPDF xcframework and shim, open/display, thumbnails, read fields and the cut into the model, Edit/Preview switch: 4-5 days.
- **M2 Field editing MVP:** draw/select/move/resize/delete/rename/duplicate, both inspectors, undo/redo, TextLayout and Appearance, incremental save, programmatic-fill checks and the save sheet, warnings: 9-11.5 days.
- **M3 Outline and cut:** outline model and editor (points, arcs, snapping, numeric entry), apply/edit/remove the cut with the XObject fallback, "keep inside outline", warnings: 5-6 days.
- **M4 Outline import:** SVG importer, PNG tracer with the import sheet (channel, threshold, cleanup, tolerance, live preview), primitive fitting, placement, curve segment editing: 5-6 days.
- **M5 Preview mode:** sample values and images, `/IF`-correct image placement, cut applied, MuPDF comparison toggle: 2-3 days.
- **M6 Hardening:** fixture corpus, golden renders, import fixtures, manual matrix, fixes, polish: 4-5 days.
- **MVP total:** about 39.5-50 days (8-10 weeks).
- **M7 v1:** multi-select, align/distribute, field snapping, tab order, linked fields, cover annotation, Compacted save, PNG drawn-outline mode, multi-shape picker, SVG `<use>`: 10-13 days, plus 1 day for the field map export if accepted.

## 11. Decisions

The owner answered the draft 3 open questions on 2026-10-10:
1. **Templates are filled by code in other apps, not by hand.** The primary consumer is a form-filling library. This led to section 6, S2's new priority, S9, and the click-to-insert action being demoted to a default-on toggle.
2. **Default font: Noto Sans**, bundled and embedded fully. Any installed embeddable font can be chosen per field.
3. **SVG and PNG sources are page-sized** and placed with Fit to page by default. Actual size remains available.
4. **Fields crossing the outline:** warn, and keep fields inside the outline while editing (on by default). The cover annotation stays an optional v1 item, only if S5 passes.
5. **One outline per page**, allowed on any page, normally page 1. Several shapes on one page are Later.

Still open: whether to keep the suggested field map export (6.3) in v1.
