// at_json.h — minimal JSON reader for translation service responses.
//
// Why this exists in the native core instead of in Lua: nothing in DMF/LuaJIT
// offers JSON, and logic that lives in Lua can only be exercised by launching the
// game. Keeping it here means at_cli.exe can test the exact code path the game
// uses, with no game, no model and no network ("at_cli.exe selftest").
//
// Scope: read-only, one parse at a time, values freed with json_free(). Not a
// general purpose library — no serialisation, no streaming, depth capped.
#ifndef AT_JSON_H
#define AT_JSON_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    J_NULL = 0,
    J_BOOL,
    J_NUM,
    J_STR,
    J_ARR,
    J_OBJ
} JType;

typedef struct JVal {
    JType type;
    int bval;                  // J_BOOL
    double num;                // J_NUM
    char* str;                 // J_STR, decoded to UTF-8
    struct JVal** items;       // J_ARR
    char** keys;               // J_OBJ
    struct JVal** vals;        // J_OBJ
    int count;
} JVal;

// Parses a complete JSON document. Returns NULL on malformed input.
JVal* json_parse(const char* text);

void json_free(JVal* v);

// Object member lookup (NULL when absent or when v is not an object).
JVal* json_get(const JVal* obj, const char* key);

// Array element lookup (NULL when out of range or when v is not an array).
JVal* json_at(const JVal* arr, int index);

// The string value, or NULL when v is not a string.
const char* json_str(const JVal* v);

// Number as int, or `fallback`.
int json_int(const JVal* v, int fallback);

// Convenience: "a.b.0.c" walked from `root`. Returns NULL if any step is missing.
JVal* json_path(const JVal* root, const char* path);

// Keys of an object, for diagnostics (NULL when not an object).
const char* json_key_at(const JVal* obj, int index);

#ifdef __cplusplus
}
#endif

#endif // AT_JSON_H
