/*
 * ve_shim.h: the only C interface Swift sees (SPEC 7.4).
 *
 * Every function runs its whole body inside fz_try/fz_catch, so MuPDF's
 * setjmp/longjmp error handling never unwinds through Swift frames. Errors are
 * returned as a code plus a message in a caller-provided ve_error.
 *
 * Objects are exchanged as PDF syntax strings (like PyMuPDF's xref_* API, which
 * the M0 spikes used), so the Swift side composes key-level edits without
 * touching MuPDF types. A ve_doc owns one fz_context and must be used from one
 * thread at a time. MuPDF's JavaScript engine is never enabled (and is compiled
 * out of the build, FZ_ENABLE_JS=0).
 */
#ifndef VE_SHIM_H
#define VE_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ve_doc ve_doc;

typedef struct ve_error {
    int code;            /* 0 = ok */
    char message[512];
} ve_error;

/* Open a PDF from bytes (copied). Returns NULL on error. */
ve_doc *ve_open_memory(const unsigned char *data, size_t len, ve_error *err);
void ve_close(ve_doc *doc);

/* Memory returned by the shim (strings, byte buffers) is freed with ve_free. */
void ve_free(void *p);

int ve_page_count(ve_doc *doc, ve_error *err);
/* Object number of page `index` (0-based); -1 on error. */
int ve_page_object_number(ve_doc *doc, int index, ve_error *err);
/* Object number of the catalog (/Root); -1 on error. */
int ve_catalog_object_number(ve_doc *doc, ve_error *err);
int ve_xref_length(ve_doc *doc, ve_error *err);
int ve_was_repaired(ve_doc *doc);
int ve_needs_password(ve_doc *doc);
int ve_is_encrypted(ve_doc *doc);
int ve_count_signatures(ve_doc *doc, ve_error *err);

/* The object `num` printed as PDF syntax (indirect refs stay "n g R").
   Returns NULL on error. Missing objects print as "null". */
char *ve_object_string(ve_doc *doc, int num, ve_error *err);
/* The trailer dictionary printed as PDF syntax. */
char *ve_trailer_string(ve_doc *doc, ve_error *err);

/* Value at a '/'-separated key path inside object `num` (e.g. "MK/IF/SW"),
   following indirect refs at intermediate steps; the final value is printed
   unresolved ("n g R" if it is a reference). Missing keys print as "null". */
char *ve_get_key(ve_doc *doc, int num, const char *path, ve_error *err);

/* Set the value at a key path (intermediate dictionaries must exist; indirect
   intermediate dictionaries are followed, so the edit lands in that object).
   value_src is PDF syntax; "null" deletes the key (pdf_dict_del). Returns 0 or -1. */
int ve_set_key(ve_doc *doc, int num, const char *path, const char *value_src, ve_error *err);

/* New indirect object from PDF syntax; returns its number or -1. */
int ve_new_object(ve_doc *doc, const char *src, ve_error *err);
/* Replace object `num` (non-stream) with PDF syntax. Returns 0 or -1. */
int ve_update_object(ve_doc *doc, int num, const char *src, ve_error *err);
/* New stream object: dict_src is its dictionary; data is the decoded content.
   compress != 0 applies FlateDecode. Returns the object number or -1. */
int ve_new_stream(ve_doc *doc, const char *dict_src, const unsigned char *data, size_t len,
                  int compress, ve_error *err);
/* New stream object whose data is already encoded (raw bytes written as-is with
   the dictionary's own /Filter). Returns the object number or -1. */
int ve_new_raw_stream(ve_doc *doc, const char *dict_src, const unsigned char *data, size_t len,
                      ve_error *err);
/* Stream data of object `num`: raw (encoded) if raw != 0, else decoded. */
unsigned char *ve_stream_data(ve_doc *doc, int num, int raw, size_t *out_len, ve_error *err);
int ve_is_stream(ve_doc *doc, int num, ve_error *err);

/* Write the document. incremental != 0: original bytes followed by an
   incremental update (the original is an exact prefix). Returns the whole file. */
unsigned char *ve_write(ve_doc *doc, int incremental, size_t *out_len, ve_error *err);
/* 1 if objects were changed since open/last write. */
int ve_has_unsaved_changes(ve_doc *doc);

#ifdef __cplusplus
}
#endif

#endif
