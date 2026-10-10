/* ve_shim.c: plain-C wrapper over MuPDF. See include/ve_shim.h for the contract.
 *
 * Rule: every exported function does all MuPDF work inside fz_try, and never
 * returns from inside the fz_try block (MuPDF requires leaving via the end of the
 * block). Results are passed out through locals declared with fz_var.
 */
#include "ve_shim.h"

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct ve_doc {
    fz_context *ctx;
    pdf_document *pdf;
};

static void set_ok(ve_error *err) {
    if (err) { err->code = 0; err->message[0] = 0; }
}

static void set_err(ve_error *err, fz_context *ctx, const char *fallback) {
    if (!err) return;
    err->code = ctx ? fz_caught(ctx) : 1;
    if (err->code == 0) err->code = 1;
    const char *msg = ctx ? fz_caught_message(ctx) : fallback;
    snprintf(err->message, sizeof err->message, "%s", (msg && *msg) ? msg : fallback);
}

static void set_err_msg(ve_error *err, const char *msg) {
    if (!err) return;
    err->code = 1;
    snprintf(err->message, sizeof err->message, "%s", msg);
}

void ve_free(void *p) { free(p); }

/* Copy a MuPDF-allocated string into malloc'd memory owned by the caller. */
static char *dup_out(const char *s, size_t len) {
    char *r = malloc(len + 1);
    if (!r) return NULL;
    memcpy(r, s, len);
    r[len] = 0;
    return r;
}

/* Parse PDF syntax into an object. A bare "n g R" becomes an indirect ref
   (pdf_parse_stm_obj does not look ahead for R at the top level). */
static pdf_obj *parse_obj(fz_context *ctx, pdf_document *doc, const char *src) {
    int num = 0, gen = 0;
    char r = 0, tail = 0;
    if (sscanf(src, " %d %d %c %c", &num, &gen, &r, &tail) == 3 && r == 'R')
        return pdf_new_indirect(ctx, doc, num, gen);

    fz_stream *stm = NULL;
    pdf_lexbuf lb;
    pdf_obj *obj = NULL;
    pdf_lexbuf_init(ctx, &lb, PDF_LEXBUF_SMALL);
    fz_var(stm);
    fz_var(obj);
    fz_try(ctx) {
        stm = fz_open_memory(ctx, (const unsigned char *)src, strlen(src));
        obj = pdf_parse_stm_obj(ctx, doc, stm, &lb);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
        pdf_lexbuf_fin(ctx, &lb);
    }
    fz_catch(ctx) {
        fz_rethrow(ctx);
    }
    return obj;
}

static char *print_obj(fz_context *ctx, pdf_obj *obj) {
    size_t len = 0;
    char *s = NULL;
    char *out = NULL;
    fz_var(s);
    fz_try(ctx) {
        s = pdf_sprint_obj(ctx, NULL, 0, &len, obj, 1, 1);
        out = dup_out(s, len);
    }
    fz_always(ctx) fz_free(ctx, s);
    fz_catch(ctx) fz_rethrow(ctx);
    if (!out) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory");
    return out;
}

/* Walk all but the last component of a '/'-separated path; returns the holder
   (possibly an indirect ref; MuPDF accessors resolve it) and the last key. */
static pdf_obj *walk_path(fz_context *ctx, pdf_obj *root, const char *path, char *last, size_t lastcap) {
    char buf[512];
    snprintf(buf, sizeof buf, "%s", path);
    char *parts[32];
    int n = 0;
    char *save = NULL;
    for (char *t = strtok_r(buf, "/", &save); t && n < 32; t = strtok_r(NULL, "/", &save))
        parts[n++] = t;
    if (n == 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "empty key path");
    pdf_obj *cur = root;
    for (int i = 0; i < n - 1; i++) {
        cur = pdf_dict_gets(ctx, cur, parts[i]);
        if (!pdf_is_dict(ctx, cur))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "key path component '%s' is not a dictionary", parts[i]);
    }
    snprintf(last, lastcap, "%s", parts[n - 1]);
    return cur;
}

ve_doc *ve_open_memory(const unsigned char *data, size_t len, ve_error *err) {
    set_ok(err);
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) { set_err_msg(err, "cannot create MuPDF context"); return NULL; }
    ve_doc *d = calloc(1, sizeof *d);
    if (!d) { fz_drop_context(ctx); set_err_msg(err, "out of memory"); return NULL; }
    d->ctx = ctx;
    fz_buffer *buf = NULL;
    fz_stream *stm = NULL;
    fz_var(buf);
    fz_var(stm);
    fz_try(ctx) {
        buf = fz_new_buffer_from_copied_data(ctx, data, len);
        stm = fz_open_buffer(ctx, buf);
        d->pdf = pdf_open_document_with_stream(ctx, stm);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx) {
        set_err(err, ctx, "cannot open PDF");
        fz_drop_context(ctx);
        free(d);
        return NULL;
    }
    return d;
}

void ve_close(ve_doc *d) {
    if (!d) return;
    fz_try(d->ctx) pdf_drop_document(d->ctx, d->pdf);
    fz_catch(d->ctx) { /* ignore */ }
    fz_drop_context(d->ctx);
    free(d);
}

int ve_page_count(ve_doc *d, ve_error *err) {
    set_ok(err);
    int n = -1;
    fz_try(d->ctx) n = pdf_count_pages(d->ctx, d->pdf);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot count pages"); n = -1; }
    return n;
}

int ve_page_object_number(ve_doc *d, int index, ve_error *err) {
    set_ok(err);
    int n = -1;
    fz_try(d->ctx) {
        pdf_obj *p = pdf_lookup_page_obj(d->ctx, d->pdf, index);
        n = pdf_to_num(d->ctx, p);
        if (n <= 0) fz_throw(d->ctx, FZ_ERROR_FORMAT, "page %d is not an indirect object", index);
    }
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot find page"); n = -1; }
    return n;
}

int ve_catalog_object_number(ve_doc *d, ve_error *err) {
    set_ok(err);
    int n = -1;
    fz_try(d->ctx) {
        pdf_obj *root = pdf_dict_get(d->ctx, pdf_trailer(d->ctx, d->pdf), PDF_NAME(Root));
        n = pdf_to_num(d->ctx, root);
        if (n <= 0) fz_throw(d->ctx, FZ_ERROR_FORMAT, "catalog is not an indirect object");
    }
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot find catalog"); n = -1; }
    return n;
}

int ve_xref_length(ve_doc *d, ve_error *err) {
    set_ok(err);
    int n = -1;
    fz_try(d->ctx) n = pdf_xref_len(d->ctx, d->pdf);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot read xref"); n = -1; }
    return n;
}

int ve_was_repaired(ve_doc *d) {
    int r = 0;
    fz_try(d->ctx) r = pdf_was_repaired(d->ctx, d->pdf);
    fz_catch(d->ctx) r = 1;
    return r;
}

int ve_needs_password(ve_doc *d) {
    int r = 0;
    fz_try(d->ctx) r = pdf_needs_password(d->ctx, d->pdf);
    fz_catch(d->ctx) r = 1;
    return r;
}

int ve_is_encrypted(ve_doc *d) {
    int r = 0;
    fz_try(d->ctx) r = pdf_dict_get(d->ctx, pdf_trailer(d->ctx, d->pdf), PDF_NAME(Encrypt)) != NULL;
    fz_catch(d->ctx) r = 1;
    return r;
}

int ve_count_signatures(ve_doc *d, ve_error *err) {
    set_ok(err);
    int n = -1;
    fz_try(d->ctx) n = pdf_count_signatures(d->ctx, d->pdf);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot count signatures"); n = -1; }
    return n;
}

char *ve_object_string(ve_doc *d, int num, ve_error *err) {
    set_ok(err);
    char *out = NULL;
    pdf_obj *obj = NULL;
    fz_var(obj);
    fz_var(out);
    fz_try(d->ctx) {
        if (num <= 0 || num >= pdf_xref_len(d->ctx, d->pdf))
            fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "object %d out of range", num);
        obj = pdf_load_object(d->ctx, d->pdf, num);
        out = print_obj(d->ctx, obj);
    }
    fz_always(d->ctx) pdf_drop_obj(d->ctx, obj);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot read object"); free(out); out = NULL; }
    return out;
}

char *ve_trailer_string(ve_doc *d, ve_error *err) {
    set_ok(err);
    char *out = NULL;
    fz_var(out);
    fz_try(d->ctx) out = print_obj(d->ctx, pdf_trailer(d->ctx, d->pdf));
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot read trailer"); out = NULL; }
    return out;
}

char *ve_get_key(ve_doc *d, int num, const char *path, ve_error *err) {
    set_ok(err);
    char *out = NULL;
    pdf_obj *obj = NULL;
    fz_var(obj);
    fz_var(out);
    fz_try(d->ctx) {
        char last[256];
        obj = pdf_load_object(d->ctx, d->pdf, num);
        pdf_obj *holder = NULL;
        fz_try(d->ctx) holder = walk_path(d->ctx, obj, path, last, sizeof last);
        fz_catch(d->ctx) holder = NULL;   /* missing intermediate -> null */
        pdf_obj *val = holder ? pdf_dict_gets(d->ctx, holder, last) : NULL;
        out = print_obj(d->ctx, val ? val : PDF_NULL);
    }
    fz_always(d->ctx) pdf_drop_obj(d->ctx, obj);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot read key"); free(out); out = NULL; }
    return out;
}

int ve_set_key(ve_doc *d, int num, const char *path, const char *value_src, ve_error *err) {
    set_ok(err);
    int rc = 0;
    pdf_obj *obj = NULL, *val = NULL;
    fz_var(obj);
    fz_var(val);
    fz_try(d->ctx) {
        char last[256];
        obj = pdf_load_object(d->ctx, d->pdf, num);
        pdf_obj *holder = walk_path(d->ctx, obj, path, last, sizeof last);
        val = parse_obj(d->ctx, d->pdf, value_src);
        if (val == NULL || pdf_is_null(d->ctx, val))
            pdf_dict_dels(d->ctx, holder, last);
        else
            pdf_dict_puts(d->ctx, holder, last, val);
    }
    fz_always(d->ctx) {
        pdf_drop_obj(d->ctx, val);
        pdf_drop_obj(d->ctx, obj);
    }
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot set key"); rc = -1; }
    return rc;
}

int ve_new_object(ve_doc *d, const char *src, ve_error *err) {
    set_ok(err);
    int num = -1;
    pdf_obj *val = NULL;
    fz_var(val);
    fz_var(num);
    fz_try(d->ctx) {
        val = parse_obj(d->ctx, d->pdf, src);
        num = pdf_create_object(d->ctx, d->pdf);
        pdf_update_object(d->ctx, d->pdf, num, val);
    }
    fz_always(d->ctx) pdf_drop_obj(d->ctx, val);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot create object"); num = -1; }
    return num;
}

int ve_update_object(ve_doc *d, int num, const char *src, ve_error *err) {
    set_ok(err);
    int rc = 0;
    pdf_obj *val = NULL;
    fz_var(val);
    fz_try(d->ctx) {
        val = parse_obj(d->ctx, d->pdf, src);
        pdf_update_object(d->ctx, d->pdf, num, val);
    }
    fz_always(d->ctx) pdf_drop_obj(d->ctx, val);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot update object"); rc = -1; }
    return rc;
}

static int new_stream_impl(ve_doc *d, const char *dict_src, const unsigned char *data, size_t len,
                           int compress, int raw, ve_error *err) {
    set_ok(err);
    int num = -1;
    pdf_obj *dict = NULL, *ref = NULL;
    fz_buffer *buf = NULL;
    unsigned char *z = NULL;
    fz_var(dict);
    fz_var(ref);
    fz_var(buf);
    fz_var(z);
    fz_var(num);
    fz_try(d->ctx) {
        dict = parse_obj(d->ctx, d->pdf, dict_src);
        if (!pdf_is_dict(d->ctx, dict)) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "stream dictionary expected");
        if (raw) {
            buf = fz_new_buffer_from_copied_data(d->ctx, data, len);
        } else if (compress) {
            size_t zlen = 0;
            z = fz_new_deflated_data(d->ctx, &zlen, data, len, FZ_DEFLATE_DEFAULT);
            buf = fz_new_buffer_from_copied_data(d->ctx, z, zlen);
            pdf_dict_put(d->ctx, dict, PDF_NAME(Filter), PDF_NAME(FlateDecode));
            pdf_dict_del(d->ctx, dict, PDF_NAME(DecodeParms));
        } else {
            buf = fz_new_buffer_from_copied_data(d->ctx, data, len);
            pdf_dict_del(d->ctx, dict, PDF_NAME(Filter));
            pdf_dict_del(d->ctx, dict, PDF_NAME(DecodeParms));
        }
        /* compressed=1: the buffer is stored as-is and /Filter is kept. */
        ref = pdf_add_stream(d->ctx, d->pdf, buf, dict, 1);
        num = pdf_to_num(d->ctx, ref);
    }
    fz_always(d->ctx) {
        pdf_drop_obj(d->ctx, ref);
        pdf_drop_obj(d->ctx, dict);
        fz_drop_buffer(d->ctx, buf);
        fz_free(d->ctx, z);
    }
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot create stream"); num = -1; }
    return num;
}

int ve_new_stream(ve_doc *d, const char *dict_src, const unsigned char *data, size_t len, int compress, ve_error *err) {
    return new_stream_impl(d, dict_src, data, len, compress, 0, err);
}

int ve_new_raw_stream(ve_doc *d, const char *dict_src, const unsigned char *data, size_t len, ve_error *err) {
    return new_stream_impl(d, dict_src, data, len, 0, 1, err);
}

int ve_is_stream(ve_doc *d, int num, ve_error *err) {
    set_ok(err);
    int r = 0;
    pdf_obj *ref = NULL;
    fz_var(ref);
    fz_try(d->ctx) {
        ref = pdf_new_indirect(d->ctx, d->pdf, num, 0);
        r = pdf_is_stream(d->ctx, ref);
    }
    fz_always(d->ctx) pdf_drop_obj(d->ctx, ref);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot inspect object"); r = -1; }
    return r;
}

unsigned char *ve_stream_data(ve_doc *d, int num, int raw, size_t *out_len, ve_error *err) {
    set_ok(err);
    unsigned char *out = NULL;
    fz_buffer *buf = NULL;
    fz_var(buf);
    fz_var(out);
    *out_len = 0;
    fz_try(d->ctx) {
        buf = raw ? pdf_load_raw_stream_number(d->ctx, d->pdf, num) : pdf_load_stream_number(d->ctx, d->pdf, num);
        unsigned char *p = NULL;
        size_t n = fz_buffer_storage(d->ctx, buf, &p);
        out = malloc(n ? n : 1);
        if (!out) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "out of memory");
        if (n) memcpy(out, p, n);
        *out_len = n;
    }
    fz_always(d->ctx) fz_drop_buffer(d->ctx, buf);
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot read stream"); free(out); out = NULL; *out_len = 0; }
    return out;
}

unsigned char *ve_write(ve_doc *d, int incremental, size_t *out_len, ve_error *err) {
    set_ok(err);
    unsigned char *out = NULL;
    fz_buffer *buf = NULL;
    fz_output *o = NULL;
    fz_var(buf);
    fz_var(o);
    fz_var(out);
    *out_len = 0;
    fz_try(d->ctx) {
        pdf_write_options opts = pdf_default_write_options;
        opts.do_incremental = incremental ? 1 : 0;
        if (!incremental) {
            opts.do_garbage = 1;
            opts.do_compress = 1;
        }
        buf = fz_new_buffer(d->ctx, 64 * 1024);
        o = fz_new_output_with_buffer(d->ctx, buf);
        pdf_write_document(d->ctx, d->pdf, o, &opts);
        fz_close_output(d->ctx, o);
        unsigned char *p = NULL;
        size_t n = fz_buffer_storage(d->ctx, buf, &p);
        out = malloc(n ? n : 1);
        if (!out) fz_throw(d->ctx, FZ_ERROR_SYSTEM, "out of memory");
        if (n) memcpy(out, p, n);
        *out_len = n;
    }
    fz_always(d->ctx) {
        fz_drop_output(d->ctx, o);
        fz_drop_buffer(d->ctx, buf);
    }
    fz_catch(d->ctx) { set_err(err, d->ctx, "cannot write PDF"); free(out); out = NULL; *out_len = 0; }
    return out;
}

int ve_has_unsaved_changes(ve_doc *d) {
    int r = 0;
    fz_try(d->ctx) r = pdf_has_unsaved_changes(d->ctx, d->pdf);
    fz_catch(d->ctx) r = 0;
    return r;
}
