// at_model.h — the offline NLLB-200 engine: model files, language codes, inference.
//
// Kept apart from at_online.c because the two halves have nothing in common: this
// one never touches the network, and it owns the CTranslate2/SentencePiece side.
//
// Implemented in at_model.cpp: those two are C++ libraries with no C API, so the
// file is compiled as C++ and exposes a plain C surface.
#ifndef AT_MODEL_H
#define AT_MODEL_H

#include "at_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// Inspects a model directory. Returns the number of present files (4 = complete).
// `out_missing` receives a comma separated list of what is absent (may be NULL).
AT_API int at_model_check_dir(const char* dir_utf8, char* out_missing, int cap);

// Total size in bytes of the files found, or 0 when the directory is unusable.
AT_API long long at_model_dir_size(const char* dir_utf8);

// FLORES-200 code for one of our internal language codes: "en" -> "eng_Latn",
// "zh-cn" -> "zho_Hans", "pt-br" -> "por_Latn". Returns 1 on success.
//
// NLLB is a many-to-many model steered by these tokens, so a wrong code does not
// fail loudly - it translates into the wrong language. Hence the table is explicit
// rather than derived from the ISO code.
AT_API int at_model_lang_code(const char* internal_lang, char* out, int cap);

// How many of our language tokens the model's shared_vocabulary.json actually
// contains; `out_missing` receives the absent ones. These tokens are not in the
// SentencePiece model, so a vocabulary without them means the directory is not an
// NLLB-200 conversion - it would load and then answer with noise.
AT_API int at_model_check_vocab(const char* dir_utf8, char* out_missing, int cap);

// 1 when the caller has to append the source EOS token itself, which is the case
// for the shipped conversion: its config.json claims "add_source_eos": false while
// the weights need it. Without the token every translation degenerates into a
// repetition of the first source token. See the note in at_model.c.
AT_API int at_model_source_eos_needed(const char* dir_utf8);

// ---------------------------------------------------------------------------
// Inference
//
// Loading reads ~600 MB from disk and takes a few seconds, so it happens once and
// is kept. It is deliberately never freed - see the note in at_model.cpp.
// ---------------------------------------------------------------------------
AT_API int at_model_ready(void);

// Loads the model in `dir_utf8`. Returns 1 on success, 0 on failure
// (at_model_error() then says why).
AT_API int at_model_load(const char* dir_utf8);

// Translates `text_utf8` into `target_lang_utf8` ("zh-cn", "ja", ...).
// Returns the number of bytes written to out_text, or a negative value:
//   -1 nothing loaded, -2 bad arguments, -3 encode/decode failed, -4 inference failed
AT_API int at_model_translate(const char* text_utf8, const char* target_lang_utf8,
                              char* out_text, int out_cap);

// Last failure, human readable. Never NULL.
AT_API const char* at_model_error(void);

// ---------------------------------------------------------------------------
// Steering
//
// NLLB needs to be told which language it is reading and which one it should
// write; the model adds neither token itself. The target is per call
// (at_model_translate), the source is a setting because every text this mod
// translates comes from the same place.
// ---------------------------------------------------------------------------

// "en" -> eng_Latn. Refuses unknown codes instead of quietly translating from
// the wrong language. Returns 1 on success.
AT_API int at_set_source_lang(const char* internal_lang);

// The FLORES-200 token currently used as the source language.
AT_API const char* at_model_source_lang(void);

// Compute type for the next load: "int8" (the shipped conversion), "int8_float32",
// "float32", "auto", "default". Call before at_model_load(). Returns 0 and sets
// at_model_error() for a name CTranslate2 does not know.
AT_API int at_set_compute_type(const char* name);

// The compute type that will be used.
AT_API const char* at_model_compute_type(void);

// Diagnostic: the SentencePiece pieces of `text_utf8`, joined with '|'.
AT_API int at_model_tokenize(const char* text_utf8, char* out, int cap);

// Diagnostic: the exact token list the engine feeds - source language token, the
// text pieces, and the source EOS when the model needs one - joined with " | ".
// This is what at_model_translate builds, so the CLI shows the truth.
AT_API int at_model_pieces(const char* text_utf8, char* out, int cap);

#ifdef __cplusplus
}
#endif

#endif // AT_MODEL_H
