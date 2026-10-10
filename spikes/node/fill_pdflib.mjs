// S9 pdf-lib filler. Usage:
//   node fill_pdflib.mjs <template.pdf> <out-prefix> <font.ttf|-> <image.png> <values.json>
// Writes <out-prefix>_unflat.pdf and <out-prefix>_flat.pdf, prints a JSON report on stdout.
// values.json: {"text": {name: value}, "image": [name, ...]}
import fs from 'node:fs';
import { PDFDocument } from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';

const [, , tpl, prefix, fontPath, imgPath, valuesPath] = process.argv;
const values = JSON.parse(fs.readFileSync(valuesPath, 'utf8'));
const report = { fields: {}, errors: [], warnings: [] };
const origWarn = console.warn;
console.warn = (...a) => { report.warnings.push(a.join(' ')); };

async function fill(flatten) {
  const doc = await PDFDocument.load(fs.readFileSync(tpl));
  doc.registerFontkit(fontkit);
  const font = fontPath !== '-' ? await doc.embedFont(fs.readFileSync(fontPath), { subset: false }) : null;
  const form = doc.getForm();
  const pages = doc.getPages();
  for (const f of form.getFields()) {
    const ws = f.acroField.getWidgets();
    const pageIdx = ws.map(w => pages.findIndex(p => p.ref === w.P()));
    report.fields[f.getName()] = {
      type: f.constructor.name, widgets: ws.length,
      rect: ws.map(w => { const r = w.getRectangle(); return [r.x, r.y, r.x + r.width, r.y + r.height]; }),
      page: pageIdx,
    };
  }
  for (const [name, v] of Object.entries(values.text)) {
    try { form.getTextField(name).setText(v); }
    catch (e) { report.errors.push(`setText ${name}: ${e.message}`); }
  }
  const png = await doc.embedPng(fs.readFileSync(imgPath));
  for (const name of values.image) {
    try { form.getButton(name).setImage(png); }
    catch (e) { report.errors.push(`setImage ${name}: ${e.message}`); }
  }
  try { if (font) form.updateFieldAppearances(font); }
  catch (e) { report.errors.push(`updateFieldAppearances: ${e.message}`); }
  if (flatten) form.flatten();
  const out = `${prefix}_${flatten ? 'flat' : 'unflat'}.pdf`;
  fs.writeFileSync(out, await doc.save());
  return out;
}

try {
  report.outputs = [await fill(false), await fill(true)];
} catch (e) {
  report.errors.push(`fatal: ${e.stack || e.message}`);
}
console.warn = origWarn;
process.stdout.write(JSON.stringify(report));
