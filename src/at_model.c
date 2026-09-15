// at_model.c — offline NLLB-200 support: model file checks and FLORES-200 codes.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "at_model.h"
#include "at_json.h"

// The four files a CTranslate2 NLLB conversion consists of.
static const char* MODEL_FILES[] = {
    "model.bin",
    "config.json",
    "shared_vocabulary.json",
    "sentencepiece.bpe.model",
};
#define MODEL_FILE_COUNT ((int)(sizeof(MODEL_FILES) / sizeof(MODEL_FILES[0])))

static int file_exists(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) {
        return 0;
    }
    fclose(f);
    return 1;
}

static long long file_size(const char* path)
{
    FILE* f = fopen(path, "rb");
    long long size;
    if (!f) {
        return 0;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 0;
    }
    size = (long long)ftell(f);
    fclose(f);
    return size > 0 ? size : 0;
}

int at_model_check_dir(const char* dir_utf8, char* out_missing, int cap)
{
    char path[1024];
    int found = 0;
    int i;

    if (out_missing && cap > 0) {
        out_missing[0] = 0;
    }
    if (!dir_utf8 || !dir_utf8[0]) {
        return 0;
    }

    for (i = 0; i < MODEL_FILE_COUNT; i++) {
        if (_snprintf_s(path, sizeof(path), _TRUNCATE, "%s/%s", dir_utf8, MODEL_FILES[i]) < 0) {
            continue;
        }
        if (file_exists(path)) {
            found++;
        } else if (out_missing && cap > 0) {
            if (out_missing[0]) {
                strncat_s(out_missing, (size_t)cap, ", ", _TRUNCATE);
            }
            strncat_s(out_missing, (size_t)cap, MODEL_FILES[i], _TRUNCATE);
        }
    }

    return found;
}

long long at_model_dir_size(const char* dir_utf8)
{
    char path[1024];
    long long total = 0;
    int i;

    if (!dir_utf8 || !dir_utf8[0]) {
        return 0;
    }

    for (i = 0; i < MODEL_FILE_COUNT; i++) {
        if (_snprintf_s(path, sizeof(path), _TRUNCATE, "%s/%s", dir_utf8, MODEL_FILES[i]) < 0) {
            continue;
        }
        total += file_size(path);
    }
    return total;
}

// ---------------------------------------------------------------------------
// Language codes
//
// NLLB is a many-to-many model steered by a FLORES-200 token ("eng_Latn",
// "zho_Hans", ...). Getting one wrong does not fail loudly - it translates into a
// different language - so the mapping is written out rather than derived, and the
// Simplified/Traditional distinction is explicit.
//
// Several keys may share one code on purpose: the same language is spelled
// differently by the game (language_id "pt-br"), by mod localization tables (the
// community's Ukrainian mod writes "ua", not the ISO "uk") and by Lingua
// Imperialis ("pt", "zh"). Aliases remove the need to guess which spelling is in
// front of us, and they are also what makes the per-mod source language work: we
// resolve whatever key the localization file uses.
// ---------------------------------------------------------------------------
typedef struct {
    const char* internal;
    const char* flores;
} ModelLangMap;

static const ModelLangMap MODEL_LANGS[] = {
    { "en",    "eng_Latn" },

    // Chinese: the game ships both scripts; "zh" alone means Simplified here,
    // because that is what the game's own default is.
    { "zh",    "zho_Hans" },
    { "zh-cn", "zho_Hans" },
    { "zh-tw", "zho_Hant" },

    // Ukrainian: ISO says uk, the Darktide modding ecosystem writes ua.
    { "uk",    "ukr_Cyrl" },
    { "ua",    "ukr_Cyrl" },

    // Portuguese: the game ships pt-br, Lingua writes pt.
    { "pt",    "por_Latn" },
    { "pt-br", "por_Latn" },

    { "ja",    "jpn_Jpan" },
    { "ko",    "kor_Hang" },
    { "ru",    "rus_Cyrl" },
    { "de",    "deu_Latn" },
    { "fr",    "fra_Latn" },
    { "es",    "spa_Latn" },
    { "it",    "ita_Latn" },
    { "pl",    "pol_Latn" },
    { "nl",    "nld_Latn" },
    { "sv",    "swe_Latn" },
    { "tr",    "tur_Latn" },
    { "ar",    "arb_Arab" },
};

int at_model_lang_code(const char* internal_lang, char* out, int cap)
{
    size_t i;

    if (!internal_lang || !out || cap <= 0) {
        return 0;
    }
    for (i = 0; i < sizeof(MODEL_LANGS) / sizeof(MODEL_LANGS[0]); i++) {
        if (_stricmp(MODEL_LANGS[i].internal, internal_lang) == 0) {
            strncpy_s(out, (size_t)cap, MODEL_LANGS[i].flores, _TRUNCATE);
            return 1;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The source EOS problem
//
// The NLLB conversion this mod uses ships a config.json that says
// "add_source_eos": false, and that is wrong for the weights sitting next to it.
// Without a trailing </s> on the source the encoder state is worthless and every
// request comes back as the first source token repeated to the decoding limit
// ("Ke Ke Ke ..." for "Keystone unlocked"). With it, the same request returns
// 关键石解锁 - verified to the character against Lingua Imperialis'
// dtranslate.dll, which appends the token itself.
//
// The model directory is user data (and model.bin is pinned by SHA-256 by the
// project that publishes it), so nothing is edited on disk: the token is appended
// at translation time instead. A model that genuinely asks CTranslate2 to add it
// would get a double EOS, so the flag is read here rather than assumed.
// ---------------------------------------------------------------------------
int at_model_source_eos_needed(const char* dir_utf8)
{
    char path[1024];
    char text[4096];
    FILE* file;
    size_t len;
    JVal* root;
    JVal* flag;

    if (!dir_utf8 || !dir_utf8[0]) {
        return 1;
    }

    _snprintf_s(path, sizeof(path), _TRUNCATE, "%s/config.json", dir_utf8);
    file = fopen(path, "rb");
    if (!file) {
        // No config at all: CTranslate2 refuses to load such a directory anyway.
        return 1;
    }
    len = fread(text, 1, sizeof(text) - 1, file);
    fclose(file);
    text[len] = 0;

    root = json_parse(text);
    if (!root) {
        return 1;
    }

    // Not freeing the parsed document: it is a few hundred bytes, read once per
    // model load, and at_model.cpp already leaks its CTranslate2 objects on purpose.
    flag = json_get(root, "add_source_eos");
    if (flag && flag->type == J_BOOL && flag->bval) {
        return 0;                      // the model adds it itself
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Vocabulary sanity check
//
// The language tokens are NOT in the SentencePiece model: they live in the
// CTranslate2 vocabulary (shared_vocabulary.json), which is why they have to be
// handed over as ready-made tokens. A directory whose vocabulary lacks them (a
// model converted from something else, a truncated download) still loads happily
// and then answers every request with noise - so it is worth one scan of the file
// at load time. The file is a JSON array of quoted tokens, one per line, so a
// search for the quoted token is exact.
// ---------------------------------------------------------------------------
int at_model_check_vocab(const char* dir_utf8, char* out_missing, int cap)
{
    char path[1024];
    FILE* file;
    char* text;
    long size;
    size_t i;
    int found = 0;

    if (out_missing && cap > 0) {
        out_missing[0] = 0;
    }
    if (!dir_utf8 || !dir_utf8[0]) {
        return 0;
    }

    _snprintf_s(path, sizeof(path), _TRUNCATE, "%s/shared_vocabulary.json", dir_utf8);
    file = fopen(path, "rb");
    if (!file) {
        if (out_missing && cap > 0) {
            strncpy_s(out_missing, (size_t)cap, "shared_vocabulary.json", _TRUNCATE);
        }
        return 0;
    }

    if (fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) <= 0) {
        fclose(file);
        return 0;
    }
    rewind(file);

    text = (char*)malloc((size_t)size + 1);
    if (!text) {
        fclose(file);
        return 0;
    }
    if (fread(text, 1, (size_t)size, file) != (size_t)size) {
        free(text);
        fclose(file);
        return 0;
    }
    text[size] = 0;
    fclose(file);

    for (i = 0; i < sizeof(MODEL_LANGS) / sizeof(MODEL_LANGS[0]); i++) {
        char quoted[64];
        size_t j;
        int duplicate = 0;

        // Aliases map several keys onto one language, so count each code once -
        // otherwise "found" would stay high even when a whole language is absent.
        for (j = 0; j < i; j++) {
            if (_stricmp(MODEL_LANGS[j].flores, MODEL_LANGS[i].flores) == 0) {
                duplicate = 1;
                break;
            }
        }
        if (duplicate) {
            continue;
        }

        _snprintf_s(quoted, sizeof(quoted), _TRUNCATE, "\"%s\"", MODEL_LANGS[i].flores);
        if (strstr(text, quoted)) {
            found++;
        } else if (out_missing && cap > 0) {
            // Report the first few absent ones; that is enough to identify the file.
            size_t used = strlen(out_missing);
            if (used < (size_t)cap - 1) {
                _snprintf_s(out_missing + used, (size_t)cap - used, _TRUNCATE, "%s%s",
                            used ? ", " : "", MODEL_LANGS[i].flores);
            }
        }
    }

    free(text);
    return found;
}

// Number of distinct languages in the table above, aliases not counted twice.
int at_model_lang_count(void)
{
    size_t i, j;
    int distinct = 0;

    for (i = 0; i < sizeof(MODEL_LANGS) / sizeof(MODEL_LANGS[0]); i++) {
        int duplicate = 0;
        for (j = 0; j < i; j++) {
            if (_stricmp(MODEL_LANGS[j].flores, MODEL_LANGS[i].flores) == 0) {
                duplicate = 1;
                break;
            }
        }
        if (!duplicate) {
            distinct++;
        }
    }
    return distinct;
}
