"""S3 (automatable part): preservation of JavaScript and signatures when fields
are added through the S1 path (key-level object edits + incremental save).

Fixtures built here (deterministically except for signature timestamps), in Tests/Fixtures/:
  js_form.pdf            synthetic_voucher.pdf plus an AcroForm with document-level
                         JavaScript (/Names /JavaScript), a text field with
                         keystroke/format/validate/calculate actions (/AA /K /F /V /C),
                         a second calculated field and a push-button with a mouse-up JS
                         action. Stands in for "an Acrobat form with JS" (no Acrobat Pro here).
  signed_approval.pdf    synthetic_voucher.pdf with one approval signature (pyHanko,
                         self-signed RSA key generated on the fly).
  signed_certified.pdf   the same with a certification signature, DocMDP P=2 (fill forms).

Checks:
  - adding the S1 fields keeps every pre-existing JS string byte-identical
    (compared as raw decoded bytes, including stream-valued /JS);
  - the original bytes are an exact prefix; libqpdf is clean;
  - the approval signature still validates (intact + valid) in pyHanko after the
    field addition; the modification level pyHanko assigns is recorded;
  - the certification result is documented (not a pass criterion).

Run:  ../.venv/bin/python s3_preservation.py
"""

from __future__ import annotations

import datetime
from pathlib import Path

import pikepdf

import common
import s1_fields
from common import Report

FIX = common.FIXTURES
KEYDIR = common.OUT / "s3_keys"

DOC_JS = {
    "init": "var VE_TAX = 0.19;\nfunction veTotal(a, b) { return (a || 0) + (b || 0); }\n",
    "helpers": "function veFormat(v) { return util.printf(\"%.2f RON\", v); } // ăâî șț\n",
}
FIELD_JS = {
    "K": "AFNumber_Keystroke(2, 0, 0, 0, \"\", true);",
    "F": "AFNumber_Format(2, 0, 0, 0, \" RON\", true);",
    "V": "if (event.value < 0) { app.alert(\"Must be positive\"); event.rc = false; }",
    "C": "AFSimple_Calculate(\"SUM\", new Array (\"amount\"));",
}
BUTTON_JS = "this.resetForm();"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
def make_js_form(dst: Path) -> None:
    with pikepdf.open(FIX / "synthetic_voucher.pdf") as pdf:
        page = pdf.pages[0].obj

        def js_action(code: str, as_stream: bool = False):
            if as_stream:
                return pikepdf.Dictionary(S=pikepdf.Name.JavaScript, JS=pikepdf.Stream(pdf, code.encode()))
            return pikepdf.Dictionary(S=pikepdf.Name.JavaScript, JS=pikepdf.String(code))

        helv = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1,
                                                    BaseFont=pikepdf.Name.Helvetica,
                                                    Encoding=pikepdf.Name.WinAnsiEncoding))
        amount = pdf.make_indirect(pikepdf.Dictionary(
            Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Widget, FT=pikepdf.Name.Tx,
            T=pikepdf.String("amount"), Rect=[60, 520, 260, 550], P=page, F=4,
            DA=pikepdf.String("/Helv 12 Tf 0 g"),
            AA=pikepdf.Dictionary(K=js_action(FIELD_JS["K"]), F=js_action(FIELD_JS["F"]),
                                  V=js_action(FIELD_JS["V"])),
        ))
        total = pdf.make_indirect(pikepdf.Dictionary(
            Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Widget, FT=pikepdf.Name.Tx,
            T=pikepdf.String("total"), Rect=[300, 520, 500, 550], P=page, F=4, Ff=1,
            DA=pikepdf.String("/Helv 12 Tf 0 g"),
            AA=pikepdf.Dictionary(C=js_action(FIELD_JS["C"], as_stream=True), F=js_action(FIELD_JS["F"])),
        ))
        reset = pdf.make_indirect(pikepdf.Dictionary(
            Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Widget, FT=pikepdf.Name.Btn, Ff=65536,
            T=pikepdf.String("reset"), Rect=[540, 520, 620, 550], P=page, F=4,
            A=js_action(BUTTON_JS),
        ))
        page.Annots = pdf.make_indirect(pikepdf.Array([amount, total, reset]))
        pdf.Root.AcroForm = pdf.make_indirect(pikepdf.Dictionary(
            Fields=[amount, total, reset], CO=[total],
            DR=pikepdf.Dictionary(Font=pikepdf.Dictionary(Helv=helv)), DA=pikepdf.String("/Helv 0 Tf 0 g"),
        ))
        names = []
        for k, code in DOC_JS.items():
            names += [pikepdf.String(k), pdf.make_indirect(js_action(code, as_stream=(k == "helpers")))]
        pdf.Root.Names = pikepdf.Dictionary(JavaScript=pikepdf.Dictionary(Names=names))
        pdf.save(dst, deterministic_id=True, static_id=True, object_stream_mode=pikepdf.ObjectStreamMode.preserve)


def make_key() -> tuple[Path, Path]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    KEYDIR.mkdir(parents=True, exist_ok=True)
    key_p, cert_p = KEYDIR / "key.pem", KEYDIR / "cert.pem"
    if key_p.exists() and cert_p.exists():
        return key_p, cert_p
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Voucher Editor S3 Test")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=True, key_encipherment=False,
                                     data_encipherment=False, key_agreement=False, key_cert_sign=True,
                                     crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_p.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption()))
    cert_p.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return key_p, cert_p


def sign(src: Path, dst: Path, certify: bool, key_p: Path, cert_p: Path) -> None:
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.sign import fields, signers

    signer = signers.SimpleSigner.load(str(key_p), str(cert_p))
    meta = signers.PdfSignatureMetadata(
        field_name="Signature1", certify=certify,
        docmdp_permissions=fields.MDPPerm.FILL_FORMS if certify else None,
        subfilter=fields.SigSeedSubFilter.ADOBE_PKCS7_DETACHED,
    )
    with open(src, "rb") as inf:
        w = IncrementalPdfFileWriter(inf)
        spec = fields.SigFieldSpec("Signature1", box=(650, 20, 830, 60), on_page=0) if not certify else \
            fields.SigFieldSpec("Signature1")
        fields.append_signature_field(w, spec)
        with open(dst, "wb") as outf:
            signers.sign_pdf(w, meta, signer=signer, output=outf)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
def js_strings(path: Path) -> dict[str, bytes]:
    """Every /JS value in the file, keyed by object number + key path, as raw bytes."""
    found: dict[str, bytes] = {}

    def walk(obj, where: str, seen: set):
        if isinstance(obj, pikepdf.Dictionary) or isinstance(obj, pikepdf.Stream):
            if obj.is_indirect:
                if obj.objgen in seen:
                    return
                seen.add(obj.objgen)
                where = f"{obj.objgen[0]}"
            for k in obj.keys():
                v = obj[k]
                if k == "/JS":
                    found[f"{where}{k}"] = v.read_bytes() if isinstance(v, pikepdf.Stream) else bytes(v)
                else:
                    walk(v, f"{where}{k}", seen)
        elif isinstance(obj, pikepdf.Array):
            for i, v in enumerate(obj):
                walk(v, f"{where}[{i}]", seen)

    with pikepdf.open(path) as pdf:
        seen: set = set()
        walk(pdf.Root, "Root", seen)
        for p in pdf.pages:
            walk(p.obj, "page", seen)
    return found


def validate(path: Path, cert_p: Path):
    from pyhanko.keys import load_cert_from_pemder
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.sign.validation import validate_pdf_signature
    from pyhanko_certvalidator import ValidationContext

    vc = ValidationContext(trust_roots=[load_cert_from_pemder(str(cert_p))])
    with open(path, "rb") as f:
        r = PdfFileReader(f)
        sig = r.embedded_signatures[0]
        return validate_pdf_signature(sig, vc)


def main() -> None:
    r = Report("S3 preservation: JS strings and signatures after adding fields (S1 path)")
    common.ensure_out()

    # --- JS form
    js_src = FIX / "js_form.pdf"
    make_js_form(js_src)
    before = js_strings(js_src)
    r.check(len(before) == 2 + 3 + 2 + 1, "fixture: JS form has the expected /JS entries", str(len(before)))
    js_out = common.fresh_copy(js_src, common.OUT / "s3_js_form_fields.pdf")
    s1_fields.add_fields(js_out)
    after = js_strings(js_out)
    r.check(common.is_prefix(js_src, js_out), "JS form: original bytes are an exact prefix")
    ok, issues = common.qpdf_check(js_out)
    r.check(ok, "JS form: libqpdf clean", "; ".join(issues[:3]))
    before_vals = sorted(before.values())
    after_vals = sorted(after.values())
    missing = [v for v in before_vals if v not in after_vals]
    r.check(not missing, "JS form: every original JS string is byte-identical after the save",
            f"{len(before)} before, {len(after)} after (+1 buttonImportIcon)")
    r.check(len(after) == len(before) + 1 and s1_fields.IMPORT_ICON_JS.encode() in after_vals,
            "JS form: only the new image field's buttonImportIcon action was added")
    import pymupdf
    with pymupdf.open(js_out) as doc:
        names = sorted(w.field_name for w in doc[0].widgets())
    r.check(names == sorted(["amount", "total", "reset"] + [f["name"] for f in s1_fields.TEXT_FIELDS + s1_fields.IMAGE_FIELDS]),
            "JS form: existing fields kept and new fields added (existing /AcroForm reused)", str(names))
    with pikepdf.open(js_out) as pdf:
        co = [bytes(x.T) for x in pdf.Root.AcroForm.CO]
        r.check(co == [b"total"], "JS form: /AcroForm /CO (calculation order) untouched")
        r.check("/JavaScript" in pdf.Root.Names, "JS form: /Names /JavaScript tree still present")

    # --- Signatures
    key_p, cert_p = make_key()
    for certify, name in [(False, "signed_approval.pdf"), (True, "signed_certified.pdf")]:
        signed = FIX / name
        sign(FIX / "synthetic_voucher.pdf", signed, certify, key_p, cert_p)
        st0 = validate(signed, cert_p)
        r.check(st0.intact and st0.valid, f"{name}: signature valid before edit", st0.summary())
        out = common.fresh_copy(signed, common.OUT / name.replace(".pdf", "_fields.pdf"))
        s1_fields.add_fields(out)
        r.check(common.is_prefix(signed, out), f"{name}: original bytes are an exact prefix after adding fields")
        ok, issues = common.qpdf_check(out)
        r.check(ok, f"{name}: libqpdf clean after adding fields", "; ".join(issues[:3]))
        st = validate(out, cert_p)
        lvl = getattr(st, "modification_level", None)
        detail = f"intact={st.intact} valid={st.valid} coverage={st.coverage} modification_level={lvl} " \
                 f"docmdp_ok={getattr(st, 'docmdp_ok', None)} bottom_line={st.bottom_line}"
        if not certify:
            r.check(st.intact and st.valid, "approval signature: cryptographically intact and valid after adding fields",
                    detail)
            r.note(f"approval: pyHanko verdict after adding fields: {detail}")
        else:
            r.check(st.intact and st.valid, "certification signature: signed bytes still intact (documented, see note)",
                    detail)
            r.note(f"certification (DocMDP P=2): pyHanko verdict after adding fields: {detail}")

    r.note("Not verified: Acrobat's view of either signature; JS behaviour in Acrobat; a real Acrobat-made JS form.")
    r.finish()


if __name__ == "__main__":
    main()
