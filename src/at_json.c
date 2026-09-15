// at_json.c — recursive descent JSON reader. See at_json.h for why it lives here.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "at_json.h"

#define AT_JSON_MAX_DEPTH 64

typedef struct {
    const char* p;
    int depth;
    int failed;
} Parser;

static JVal* parse_value(Parser* ps);

static JVal* jnew(JType type)
{
    JVal* v = (JVal*)calloc(1, sizeof(JVal));
    if (v) {
        v->type = type;
    }
    return v;
}

void json_free(JVal* v)
{
    int i;
    if (!v) {
        return;
    }
    free(v->str);
    for (i = 0; i < v->count; i++) {
        if (v->items) {
            json_free(v->items[i]);
        }
        if (v->vals) {
            json_free(v->vals[i]);
        }
        if (v->keys) {
            free(v->keys[i]);
        }
    }
    free(v->items);
    free(v->vals);
    free(v->keys);
    free(v);
}

static void skip_ws(Parser* ps)
{
    for (;;) {
        char c = *ps->p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            ps->p++;
        } else {
            return;
        }
    }
}

// Appends one byte to a growing buffer. Used for string values.
typedef struct {
    char* data;
    int len;
    int cap;
    int oom;
} Buf;

static void buf_init(Buf* b)
{
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    b->oom = 0;
}

static void buf_push(Buf* b, const char* src, int n)
{
    if (b->oom) {
        return;
    }
    if (b->len + n + 1 > b->cap) {
        int want = (b->cap ? b->cap * 2 : 64);
        char* grown;
        while (want < b->len + n + 1) {
            want *= 2;
        }
        grown = (char*)realloc(b->data, (size_t)want);
        if (!grown) {
            b->oom = 1;
            return;
        }
        b->data = grown;
        b->cap = want;
    }
    memcpy(b->data + b->len, src, (size_t)n);
    b->len += n;
    b->data[b->len] = 0;
}

// Encodes one Unicode code point as UTF-8.
static void buf_push_utf8(Buf* b, unsigned int cp)
{
    char tmp[4];
    int n = 0;

    if (cp < 0x80) {
        tmp[n++] = (char)cp;
    } else if (cp < 0x800) {
        tmp[n++] = (char)(0xC0 | (cp >> 6));
        tmp[n++] = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        tmp[n++] = (char)(0xE0 | (cp >> 12));
        tmp[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[n++] = (char)(0x80 | (cp & 0x3F));
    } else {
        tmp[n++] = (char)(0xF0 | (cp >> 18));
        tmp[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
        tmp[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[n++] = (char)(0x80 | (cp & 0x3F));
    }
    buf_push(b, tmp, n);
}

static int hex4(const char* s, unsigned int* out)
{
    unsigned int v = 0;
    int i;
    for (i = 0; i < 4; i++) {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9') {
            v |= (unsigned int)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            v |= (unsigned int)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            v |= (unsigned int)(c - 'A' + 10);
        } else {
            return 0;
        }
    }
    *out = v;
    return 1;
}

// Reads a quoted string, decoding escapes into UTF-8. Returns NULL on error.
static char* parse_string_raw(Parser* ps)
{
    Buf b;

    buf_init(&b);
    ps->p++; // opening quote

    for (;;) {
        char c = *ps->p;

        if (c == 0) {
            free(b.data);
            ps->failed = 1;
            return NULL;
        }
        if (c == '"') {
            ps->p++;
            break;
        }
        if (c == '\\') {
            char esc = ps->p[1];
            ps->p += 2;
            switch (esc) {
            case '"':  buf_push(&b, "\"", 1); break;
            case '\\': buf_push(&b, "\\", 1); break;
            case '/':  buf_push(&b, "/", 1); break;
            case 'b':  buf_push(&b, "\b", 1); break;
            case 'f':  buf_push(&b, "\f", 1); break;
            case 'n':  buf_push(&b, "\n", 1); break;
            case 'r':  buf_push(&b, "\r", 1); break;
            case 't':  buf_push(&b, "\t", 1); break;
            case 'u': {
                unsigned int cp = 0;
                if (!hex4(ps->p, &cp)) {
                    free(b.data);
                    ps->failed = 1;
                    return NULL;
                }
                ps->p += 4;
                // surrogate pair -> single code point
                if (cp >= 0xD800 && cp <= 0xDBFF && ps->p[0] == '\\' && ps->p[1] == 'u') {
                    unsigned int lo = 0;
                    if (hex4(ps->p + 2, &lo) && lo >= 0xDC00 && lo <= 0xDFFF) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        ps->p += 6;
                    }
                }
                buf_push_utf8(&b, cp);
                break;
            }
            default:
                // Unknown escape: keep the escaped byte rather than losing text.
                buf_push(&b, &esc, 1);
                break;
            }
            continue;
        }
        buf_push(&b, &c, 1);
        ps->p++;
    }

    if (b.oom) {
        free(b.data);
        ps->failed = 1;
        return NULL;
    }
    if (!b.data) {
        // empty string
        b.data = (char*)malloc(1);
        if (!b.data) {
            ps->failed = 1;
            return NULL;
        }
        b.data[0] = 0;
    }
    return b.data;
}

static JVal* parse_string(Parser* ps)
{
    char* s = parse_string_raw(ps);
    JVal* v;

    if (!s) {
        return NULL;
    }
    v = jnew(J_STR);
    if (!v) {
        free(s);
        return NULL;
    }
    v->str = s;
    return v;
}

static JVal* parse_number(Parser* ps)
{
    char* end = NULL;
    double d = strtod(ps->p, &end);
    JVal* v;

    if (end == ps->p) {
        ps->failed = 1;
        return NULL;
    }
    ps->p = end;
    v = jnew(J_NUM);
    if (v) {
        v->num = d;
    }
    return v;
}

static int match_lit(Parser* ps, const char* word)
{
    size_t n = strlen(word);
    if (strncmp(ps->p, word, n) != 0) {
        return 0;
    }
    ps->p += n;
    return 1;
}

static JVal* parse_array(Parser* ps)
{
    JVal* v = jnew(J_ARR);
    int cap = 0;

    if (!v) {
        return NULL;
    }
    ps->p++; // '['
    skip_ws(ps);

    if (*ps->p == ']') {
        ps->p++;
        return v;
    }

    for (;;) {
        JVal* item = parse_value(ps);
        if (!item) {
            json_free(v);
            return NULL;
        }
        if (v->count >= cap) {
            int want = cap ? cap * 2 : 4;
            JVal** grown = (JVal**)realloc(v->items, sizeof(JVal*) * (size_t)want);
            if (!grown) {
                json_free(item);
                json_free(v);
                ps->failed = 1;
                return NULL;
            }
            v->items = grown;
            cap = want;
        }
        v->items[v->count++] = item;

        skip_ws(ps);
        if (*ps->p == ',') {
            ps->p++;
            skip_ws(ps);
            continue;
        }
        if (*ps->p == ']') {
            ps->p++;
            return v;
        }
        json_free(v);
        ps->failed = 1;
        return NULL;
    }
}

static JVal* parse_object(Parser* ps)
{
    JVal* v = jnew(J_OBJ);
    int cap = 0;

    if (!v) {
        return NULL;
    }
    ps->p++; // '{'
    skip_ws(ps);

    if (*ps->p == '}') {
        ps->p++;
        return v;
    }

    for (;;) {
        char* key;
        JVal* val;

        if (*ps->p != '"') {
            json_free(v);
            ps->failed = 1;
            return NULL;
        }
        key = parse_string_raw(ps);
        if (!key) {
            json_free(v);
            return NULL;
        }

        skip_ws(ps);
        if (*ps->p != ':') {
            free(key);
            json_free(v);
            ps->failed = 1;
            return NULL;
        }
        ps->p++;
        skip_ws(ps);

        val = parse_value(ps);
        if (!val) {
            free(key);
            json_free(v);
            return NULL;
        }

        if (v->count >= cap) {
            int want = cap ? cap * 2 : 4;
            char** gk = (char**)realloc(v->keys, sizeof(char*) * (size_t)want);
            JVal** gv;
            if (!gk) {
                free(key);
                json_free(val);
                json_free(v);
                ps->failed = 1;
                return NULL;
            }
            v->keys = gk;
            gv = (JVal**)realloc(v->vals, sizeof(JVal*) * (size_t)want);
            if (!gv) {
                free(key);
                json_free(val);
                json_free(v);
                ps->failed = 1;
                return NULL;
            }
            v->vals = gv;
            cap = want;
        }
        v->keys[v->count] = key;
        v->vals[v->count] = val;
        v->count++;

        skip_ws(ps);
        if (*ps->p == ',') {
            ps->p++;
            skip_ws(ps);
            continue;
        }
        if (*ps->p == '}') {
            ps->p++;
            return v;
        }
        json_free(v);
        ps->failed = 1;
        return NULL;
    }
}

static JVal* parse_value(Parser* ps)
{
    char c;

    if (ps->depth >= AT_JSON_MAX_DEPTH) {
        ps->failed = 1;
        return NULL;
    }
    skip_ws(ps);
    c = *ps->p;

    // A UTF-8 BOM at the start of the body is tolerated.
    if ((unsigned char)c == 0xEF && (unsigned char)ps->p[1] == 0xBB && (unsigned char)ps->p[2] == 0xBF) {
        ps->p += 3;
        skip_ws(ps);
        c = *ps->p;
    }

    ps->depth++;
    switch (c) {
    case '"': {
        JVal* v = parse_string(ps);
        ps->depth--;
        return v;
    }
    case '{': {
        JVal* v = parse_object(ps);
        ps->depth--;
        return v;
    }
    case '[': {
        JVal* v = parse_array(ps);
        ps->depth--;
        return v;
    }
    case 't': {
        JVal* v;
        if (!match_lit(ps, "true")) {
            break;
        }
        v = jnew(J_BOOL);
        if (v) {
            v->bval = 1;
        }
        ps->depth--;
        return v;
    }
    case 'f': {
        JVal* v;
        if (!match_lit(ps, "false")) {
            break;
        }
        v = jnew(J_BOOL);
        if (v) {
            v->bval = 0;
        }
        ps->depth--;
        return v;
    }
    case 'n': {
        JVal* v;
        if (!match_lit(ps, "null")) {
            break;
        }
        v = jnew(J_NULL);
        ps->depth--;
        return v;
    }
    default:
        break;
    }

    if (c == '-' || (c >= '0' && c <= '9')) {
        JVal* v = parse_number(ps);
        ps->depth--;
        return v;
    }

    ps->depth--;
    ps->failed = 1;
    return NULL;
}

JVal* json_parse(const char* text)
{
    Parser ps;
    JVal* v;

    if (!text) {
        return NULL;
    }
    ps.p = text;
    ps.depth = 0;
    ps.failed = 0;

    v = parse_value(&ps);
    if (!v) {
        return NULL;
    }
    skip_ws(&ps);
    if (*ps.p != 0) {
        // trailing garbage means the body was not what we think it was
        json_free(v);
        return NULL;
    }
    return v;
}

JVal* json_get(const JVal* obj, const char* key)
{
    int i;
    if (!obj || obj->type != J_OBJ || !key) {
        return NULL;
    }
    for (i = 0; i < obj->count; i++) {
        if (obj->keys[i] && strcmp(obj->keys[i], key) == 0) {
            return obj->vals[i];
        }
    }
    return NULL;
}

JVal* json_at(const JVal* arr, int index)
{
    if (!arr || arr->type != J_ARR || index < 0 || index >= arr->count) {
        return NULL;
    }
    return arr->items[index];
}

const char* json_str(const JVal* v)
{
    if (!v || v->type != J_STR) {
        return NULL;
    }
    return v->str;
}

int json_int(const JVal* v, int fallback)
{
    if (!v || v->type != J_NUM) {
        return fallback;
    }
    return (int)v->num;
}

const char* json_key_at(const JVal* obj, int index)
{
    if (!obj || obj->type != J_OBJ || index < 0 || index >= obj->count) {
        return NULL;
    }
    return obj->keys[index];
}

JVal* json_path(const JVal* root, const char* path)
{
    const JVal* cur = root;
    const char* p = path;

    if (!root || !path) {
        return NULL;
    }

    while (*p && cur) {
        const char* dot = strchr(p, '.');
        int n = dot ? (int)(dot - p) : (int)strlen(p);

        if (n == 1 && p[0] == '*') {
            // "*" = first element of an array
            cur = json_at(cur, 0);
        } else {
            char key[128];
            if (n >= (int)sizeof(key)) {
                return NULL;
            }
            memcpy(key, p, (size_t)n);
            key[n] = 0;

            if (cur->type == J_ARR) {
                // digits address an array position
                int idx = atoi(key);
                int all_digits = n > 0;
                int i;
                for (i = 0; i < n; i++) {
                    if (key[i] < '0' || key[i] > '9') {
                        all_digits = 0;
                        break;
                    }
                }
                cur = all_digits ? json_at(cur, idx) : NULL;
            } else {
                cur = json_get(cur, key);
            }
        }

        if (!dot) {
            break;
        }
        p = dot + 1;
    }

    return (JVal*)cur;
}
