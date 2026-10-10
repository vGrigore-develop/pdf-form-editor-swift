# M0 spikes

Python prototypes of the risky parts of SPEC.md section 8, written against PyMuPDF (the same C library as MuPDF) so the logic can be ported to the C shim and Swift. Results and findings are in `RESULTS.md`.

## Setup (once)

From the repo root. The venv lives in `.venv/` and is gitignored; nothing is installed globally.

```
python3 -m venv .venv
.venv/bin/pip install -r spikes/requirements.txt
```

`qpdf` (the CLI) is not installed. The structural check uses libqpdf through pikepdf (`Pdf.check_pdf_syntax()` plus open warnings) as a stand-in for `qpdf --check`.

## Run

Run from `spikes/`, since the scripts import each other by module name:

```
cd spikes
../.venv/bin/python make_fixtures.py       # Tests/Fixtures/*.pdf (deterministic)
../.venv/bin/python make_svg_fixtures.py   # Tests/Fixtures/svg/cubic_only.svg, nonuniform.svg
../.venv/bin/python s1_fields.py           # S1: 3 text + 2 image fields, incremental save
../.venv/bin/python s5_cut.py              # S5: cut apply / re-edit / remove, MuPDF + PDFium renders (~40 s)
../.venv/bin/python s7_svg.py              # S7: SVG parsing, placement, primitive fitting
../.venv/bin/python s3_preservation.py     # S3: JS strings and signatures after adding fields
../.venv/bin/python s9_fill.py             # S9: fill the S5f template with PyMuPDF, pypdf, pdf-lib
../.venv/bin/python s10_crop.py            # S10: crop fields to the outline (needs `swift test` output and the PDFKit renderer)
```

`s10_crop.py` renders with PDFKit too, through a small Swift tool: build it once with `swiftc -O pdfkit_render.swift -o out/pdfkit_render`. Without an argument it fills and measures the Swift engine's `out/swift/swift_crossing_cut.pdf`; with a template path it builds the candidate variants (appearance clip, open clip, cover annotation) and compares them.

`s9_fill.py` needs pdf-lib, installed locally: `(cd node && npm ci)`. Set `S9_TEMPLATE=path.pdf` to run the S9 checks on another template, for example the Swift app's output in `out/swift/` (written by `swift test`).

Or run all of them with `./run_all.sh`.

Each spike prints one PASS/FAIL line per check and exits non-zero if any check fails, so they can later run as regression tests. Output PDFs and PNG renders go to `spikes/out/` (gitignored).

`s1_fields.py` takes an optional input path. Run it on a copy of your own voucher template (no real template is included in the repo): `../.venv/bin/python s1_fields.py /path/to/voucher.pdf`.

## Files

| File | What it is |
|---|---|
| `common.py` | Key-level PDF object helpers, incremental save, prefix check, libqpdf check, MuPDF and PDFium renderers at the same exact scale, mask morphology |
| `make_fixtures.py` | Synthetic 842 x 595 voucher (several content streams, no white pixels) and two unbalanced q/Q fixtures |
| `s1_fields.py` | S1, MuPDF side: AcroForm text and image fields through the object API |
| `outline.py` | Outline model (line / arc / curve), arc to Bézier, PDF path ops, `/Segments` read and write, reference shapes, analytic rasterising, Hausdorff distance |
| `cut.py` | The shape cut: q/Q tokenizer, Wrap and XObject modes, PieceInfo storage, edit, remove, marker recovery |
| `s5_cut.py` | S5 test driver (scenarios a-f) |
| `svg_import.py` | SVG importer: path parser, shapes, transforms, viewBox / preserveAspectRatio, arc preservation, Fit to page / Actual size |
| `fitting.py` | Primitive fitting (5.6.3): lines, orthogonal snap, circle fit, shared-coordinate snap |
| `make_svg_fixtures.py` | SVG fixtures that imitate editor exports |
| `s7_svg.py` | S7 test driver |
| `s3_preservation.py` | S3: builds JS-form and signed fixtures, adds fields via the S1 path, checks JS bytes and signatures |
| `s9_fill.py` | S9: fills a template with PyMuPDF, pypdf and pdf-lib, unflattened and flattened; checks names, rects, text placement, images, clip; basic S2 diacritics |
| `s10_crop.py` | S10: crop form fields to the cut outline; builds the variants, fills each with the S9 fillers, measures pixels outside the outline in MuPDF, PDFium and PDFKit |
| `pdfkit_render.swift` | PDFKit page renderer (annotations included, exact scale) used by S10 |
| `node/` | Local npm package with pdf-lib 1.17.1 and @pdf-lib/fontkit; `fill_pdflib.mjs` is the pdf-lib filler |

## Not runnable here (pending)

S2 (beyond the basic diacritics check in S9), S4, S6 and S8, plus the viewer halves of S1, S3, S5 and S9. `RESULTS.md` lists what each one needs.
