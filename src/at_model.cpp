// at_model.cpp — offline NLLB-200 translation through SentencePiece + CTranslate2.
//
// Compiled as C++ (both libraries are C++ with no C API) and exposing a plain C
// surface, because the rest of the core is C.
//
// Two decisions worth knowing about:
//
//   * The processor and translator are allocated with new and NEVER freed. With
//     CTranslate2 linked statically, tearing them down hangs the process at exit:
//     a staged probe printed every step and then sat there for 120 s without
//     exiting. In the game that would mean the game not closing. Leaking a
//     handful of objects once per process lets the OS reclaim them instead.
//
//     The flip side is the rule load_model_locked() enforces: **one model per
//     process**. A second load request is refused, whatever directory it names,
//     because the objects of the first one cannot be released - so the mod has to
//     tell the player to restart instead of pretending the model changed.
//
//   * A translation uses 8 threads at most, never all of them. CTranslate2 asks for
//     every core when nothing is configured, and inside the game that is both the
//     slowest setting (32 threads on 32 logical cores thrash: measured ~1000 ms
//     against 340 ms at 8) and the one that takes the machine away from the game.
//     at_model_set_threads() overrides it; the CLI's --threads measures it.
//
//   * compute_type is INT8, not the default. The NLLB conversion we ship is int8;
//     asking CTranslate2 for float32 makes it try to convert the model on load,
//     and ct2-translator does exactly that by default - it burns CPU with no
//     visible progress and never finishes. That cost a long debug session.
//
//   * NLLB is steered entirely by language tokens, and the model adds none itself
//     (config.json: "add_source_bos": false, "add_source_eos": false). So the
//     source language token has to be put in front of the source tokens by hand,
//     exactly as the HuggingFace tokenizer does when src_lang is set. Without it
//     the decoder has no idea what it is looking at and loops: "Hello" came back
//     as jpn_Jpan followed by the word Hello two hundred times.
//
//     The token is prepended as a piece instead of by tokenising "eng_Latn Hello"
//     as one string: SentencePiece may split that as "eng", "_Lat", "n" depending
//     on its merges, while the token list expects the single piece "eng_Latn".
//     PieceToId() tells us whether the piece really exists.
#include <cstdio>
#include <cstring>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <ctranslate2/models/model.h>
#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

#include "at_model.h"

namespace {

std::mutex g_lock;
sentencepiece::SentencePieceProcessor* g_spm = nullptr;      // never deleted (see above)
ctranslate2::models::ModelLoader* g_loader = nullptr;        // never deleted
ctranslate2::Translator* g_translator = nullptr;             // never deleted
bool g_ready = false;
char g_error[512] = { 0 };

// Source language, as a FLORES-200 token. The texts this mod translates come from
// English mod files, so that is the default; at_set_source_lang() can change it.
char g_source_lang[32] = "eng_Latn";

// Threads one translation may use. 0 = the default (see default_intra_threads()): enough
// to keep the queue moving without taking the whole machine away from the game.
int g_intra_threads = 0;

// The directory that is actually loaded, for the mod and the CLI to compare against
// what they asked for - the mismatch is silent otherwise (the load is a no-op).
std::string g_loaded_dir;

// The thread count the pool was built with: ReplicaPoolConfig cannot be read back from
// the Translator, so it is remembered here for at_model_current_threads().
int g_effective_threads = 0;

// Half the logical processors, capped at 8. Both halves of that rule are measured (one
// 102-character string, 1.3B int8, 3 runs each, on a 32-thread machine):
//
//     threads  32     16     8     4     2     1
//     ms      ~1000   ~400   340   ~410   640   1200
//
// "All of them" is not just bad for the game, it is the *slowest*: 32 threads on 32
// logical cores thrash. Half the cores is the passable default and 8 is the sweet spot on
// a big machine, so that is the cap; a small machine still gets a proportional share.
int default_intra_threads()
{
    const unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) {
        return 2;
    }
    int threads = (int)(hw / 2);
    if (threads > 8) {
        threads = 8;
    }
    return threads > 0 ? threads : 1;
}

// Compute type the model is loaded with. The shipped conversion is int8, so that
// is the default; the knob exists because a mismatch here does not fail loudly -
// CTranslate2 converts the weights on load and the output is simply nonsense.
char g_compute_type[32] = "int8";

// Whether at_model_translate has to append "</s>" to the source itself. See the
// note in at_model.c: the shipped config.json says add_source_eos=false, but the
// weights beside it only work when the source carries the EOS token.
bool g_source_eos = true;

void set_error(const char* message)
{
    g_error[0] = 0;
    if (message) {
        std::snprintf(g_error, sizeof(g_error), "%s", message);
    }
}

void set_error_status(const char* what, const std::string& status)
{
    std::snprintf(g_error, sizeof(g_error), "%s: %s", what, status.c_str());
}

// The exact token list the engine feeds for `text_utf8`: the source language token,
// the SentencePiece pieces of the text, and the source EOS this model needs (see
// at_model.c). Shared with the at_model_pieces diagnostic so the CLI can never
// print something different from what is really fed.
int build_source_tokens(const char* text_utf8, std::vector<std::string>& tokens)
{
    tokens.clear();
    tokens.emplace_back(g_source_lang);

    std::vector<std::string> pieces;
    const auto status = g_spm->Encode(text_utf8, &pieces);
    if (!status.ok()) {
        set_error_status("could not tokenize the text", status.ToString());
        return 0;
    }
    tokens.insert(tokens.end(), pieces.begin(), pieces.end());

    if (g_source_eos) {
        tokens.emplace_back("</s>");
    }
    return 1;
}

}  // namespace

extern "C" {

const char* at_model_error(void)
{
    return g_error;
}

int at_model_ready(void)
{
    return g_ready ? 1 : 0;
}

// Sets the language the texts are written in ("en", "de", ...). Unknown codes are
// refused rather than silently ignored: a wrong source token does not fail, it
// just makes every translation nonsense.
int at_set_source_lang(const char* internal_lang)
{
    char flores[32] = { 0 };
    if (!internal_lang || !at_model_lang_code(internal_lang, flores, (int)sizeof(flores))) {
        std::snprintf(g_error, sizeof(g_error), "no source language '%s'",
                      internal_lang ? internal_lang : "(null)");
        return 0;
    }
    std::snprintf(g_source_lang, sizeof(g_source_lang), "%s", flores);
    return 1;
}

const char* at_model_source_lang(void)
{
    return g_source_lang;
}

// Sets the compute type the next load uses ("int8", "int8_float32", "float32", ...).
// Unknown names are refused: CTranslate2 would otherwise fall back to a default and
// quietly translate with the wrong precision.
int at_set_compute_type(const char* name)
{
    if (!name || !name[0]) {
        std::snprintf(g_compute_type, sizeof(g_compute_type), "int8");
        return 1;
    }

    try {
        const auto type = ctranslate2::str_to_compute_type(name);
        // Round-trip it so a name CTranslate2 merely ignores cannot slip through.
        const std::string canonical = ctranslate2::compute_type_to_str(type);
        std::snprintf(g_compute_type, sizeof(g_compute_type), "%s", canonical.c_str());
        return 1;
    } catch (const std::exception& e) {
        std::snprintf(g_error, sizeof(g_error), "unknown compute type '%s': %s", name, e.what());
        return 0;
    }
}

const char* at_model_compute_type(void)
{
    return g_compute_type;
}

// Diagnostic: the token list the engine would feed for `text_utf8`, joined with
// " | " so the source language token and the trailing EOS are visible as tokens
// rather than being merged into the text.
int at_model_pieces(const char* text_utf8, char* out, int cap)
{
    std::lock_guard<std::mutex> guard(g_lock);

    if (!g_ready || !g_spm) {
        set_error("no model is loaded");
        return -1;
    }
    if (!text_utf8 || !out || cap <= 0) {
        set_error("missing argument");
        return -2;
    }
    out[0] = 0;

    std::vector<std::string> tokens;
    if (!build_source_tokens(text_utf8, tokens)) {
        return -3;
    }

    int used = 0;
    for (size_t i = 0; i < tokens.size(); ++i) {
        const char* separator = i ? " | " : "";
        for (const char* p = separator; *p && used < cap - 1; ++p) {
            out[used++] = *p;
        }
        for (const char* p = tokens[i].c_str(); *p && used < cap - 1; ++p) {
            out[used++] = *p;
        }
    }
    out[used] = 0;
    return used;
}

// Tokenisation probe for the CLI: what the model is actually fed, as
// "eng_Latn|▁Hello|!" style pieces. Purely diagnostic.
int at_model_tokenize(const char* text_utf8, char* out, int cap)
{
    std::lock_guard<std::mutex> guard(g_lock);

    if (!g_ready || !g_spm) {
        set_error("no model is loaded");
        return -1;
    }
    if (!text_utf8 || !out || cap <= 0) {
        set_error("missing argument");
        return -2;
    }
    out[0] = 0;

    std::vector<std::string> pieces;
    const auto status = g_spm->Encode(text_utf8, &pieces);
    if (!status.ok()) {
        set_error_status("could not tokenize the text", status.ToString());
        return -3;
    }

    int used = 0;
    for (size_t i = 0; i < pieces.size(); ++i) {
        const std::string& piece = pieces[i];
        if (i && used < cap - 1) {
            out[used++] = '|';
        }
        for (size_t j = 0; j < piece.size() && used < cap - 1; ++j) {
            out[used++] = piece[j];
        }
    }
    out[used] = 0;
    return used;
}

namespace {

// Set while a background load is running, so at_model_loading() can answer without
// touching the model lock (which the loader holds for the whole load).
std::mutex g_load_lock;
bool g_loading = false;
std::string g_load_dir;

// The load itself. The caller must hold g_lock: while this runs, no translation may
// start, and at_model_ready() stays false so submits are refused rather than queued.
int load_model_locked(const char* dir_utf8)
{
    // One model per process, whatever directory is asked for: the objects of the first
    // one are never released (see the note at the top of the file), so loading a second
    // would put two models in the game process at once - 1.7 GB plus 3.8 GB measured,
    // for a queue that can only ever use one of them. Asking again for the model that is
    // already loaded is a plain no-op; asking for a *different* one is refused loudly,
    // because the caller has to tell the player to restart instead of pretending the
    // change applied.
    if (g_ready) {
        if (g_loaded_dir == dir_utf8) {
            return 1;
        }
        set_error("another model is already loaded and cannot be released - restart the game to switch models");
        return -3;
    }
    if (!dir_utf8 || !dir_utf8[0]) {
        set_error("no model directory given");
        return 0;
    }

    char missing[256] = { 0 };
    if (at_model_check_dir(dir_utf8, missing, (int)sizeof(missing)) < 4) {
        std::snprintf(g_error, sizeof(g_error), "model directory is incomplete, missing: %s", missing);
        return 0;
    }

    // A directory that is missing the NLLB language tokens would load and then
    // translate everything into noise, so it is refused here instead.
    {
        char absent[256] = { 0 };
        const int wanted = at_model_lang_count();
        if (at_model_check_vocab(dir_utf8, absent, (int)sizeof(absent)) < wanted) {
            std::snprintf(g_error, sizeof(g_error),
                          "the vocabulary is missing NLLB language tokens (%s); "
                          "this is not a complete NLLB-200 conversion", absent);
            return 0;
        }
    }

    // Decided once, from config.json; see the note in at_model.c.
    g_source_eos = at_model_source_eos_needed(dir_utf8) != 0;

    g_spm = new sentencepiece::SentencePieceProcessor();
    {
        const std::string path = std::string(dir_utf8) + "/sentencepiece.bpe.model";
        const auto status = g_spm->Load(path);
        if (!status.ok()) {
            set_error_status("could not load the SentencePiece model", status.ToString());
            return 0;
        }
    }

    try {
        g_loader = new ctranslate2::models::ModelLoader(dir_utf8);
        g_loader->device = ctranslate2::Device::CPU;
        g_loader->compute_type = ctranslate2::str_to_compute_type(g_compute_type);

        // ReplicaPoolConfig is where the thread count lives in CTranslate2 4.x (it is not
        // a ModelLoader member): num_threads_per_replica = 0 asks for every core, and this
        // runs inside the game, so the default is half of them.
        ctranslate2::ReplicaPoolConfig pool;
        pool.num_threads_per_replica = (size_t)(g_intra_threads > 0 ? g_intra_threads : default_intra_threads());
        g_translator = new ctranslate2::Translator(*g_loader, pool);
        g_effective_threads = (int)pool.num_threads_per_replica;
    } catch (const std::exception& e) {
        std::snprintf(g_error, sizeof(g_error), "could not load the CTranslate2 model: %s", e.what());
        return 0;
    }

    g_loaded_dir = dir_utf8;
    g_ready = true;
    set_error("");
    return 1;
}

}  // namespace

// Threads a translation may use; 0 = the default (half the cores). Only read when a
// model is loaded, so set it before at_model_load()/at_model_load_async().
int at_model_set_threads(int threads)
{
    g_intra_threads = threads > 0 ? threads : 0;
    if (g_ready) {
        set_error("threads can only be set before the model is loaded");
        return 0;
    }
    return 1;
}

int at_model_current_threads(void)
{
    return g_effective_threads;
}

int at_model_machine_cores(void)
{
    const unsigned hw = std::thread::hardware_concurrency();
    return hw > 0 ? (int)hw : 0;
}

// The directory that is loaded, or "" when none is. The mod compares this with the model
// it asked for: a *different* directory after a load request means the request was a
// no-op (one model per process), and the player has to restart for the change to apply.
int at_model_current_dir(char* out, int cap)
{
    if (!out || cap <= 0) {
        return 0;
    }
    out[0] = 0;
    if (g_loaded_dir.empty()) {
        return 0;
    }
    std::snprintf(out, (size_t)cap, "%s", g_loaded_dir.c_str());
    return (int)g_loaded_dir.size();
}

int at_model_load(const char* dir_utf8)
{
    std::lock_guard<std::mutex> guard(g_lock);
    return load_model_locked(dir_utf8);
}

// Loading reads ~600 MB, which on a cold page cache takes seconds. Doing that in the
// frame callback would freeze the game, so the same trick as translation: a detached
// worker loads while the game keeps drawing, and at_model_loading()/at_model_status()
// report progress.
//   1 = a load was started, 0 = already loaded or already loading, <0 = refused
int at_model_load_async(const char* dir_utf8)
{
    if (!dir_utf8 || !dir_utf8[0]) {
        set_error("no model directory given");
        return -2;
    }

    {
        std::lock_guard<std::mutex> lock(g_load_lock);
        if (g_ready) {
            // Already loaded: the same directory is a no-op, a different one cannot be
            // honoured at all (one model per process) - see load_model_locked().
            if (g_loaded_dir == dir_utf8) {
                return 0;
            }
            set_error("another model is already loaded and cannot be released - restart the game to switch models");
            return -3;
        }
        if (g_loading) {
            return 0;
        }
        g_loading = true;
        g_load_dir = dir_utf8;
    }

    std::thread([]() {
        std::string dir;
        {
            std::lock_guard<std::mutex> lock(g_load_lock);
            dir = g_load_dir;
        }

        {
            std::lock_guard<std::mutex> guard(g_lock);
            load_model_locked(dir.c_str());     // failure lands in at_model_error()
        }

        std::lock_guard<std::mutex> lock(g_load_lock);
        g_loading = false;
    }).detach();

    return 1;
}

int at_model_loading(void)
{
    std::lock_guard<std::mutex> lock(g_load_lock);
    return g_loading ? 1 : 0;
}

// The inference itself, with no locking and no output buffer: the synchronous entry
// point and the background worker both go through this.
static int translate_to_string(const char* text_utf8, const char* target_lang_utf8, std::string& out)
{
    out.clear();

    if (!g_ready || !g_translator || !g_spm) {
        set_error("no model is loaded");
        return -1;
    }
    if (!text_utf8 || !target_lang_utf8) {
        set_error("missing argument");
        return -2;
    }

    char flores[32] = { 0 };
    if (!at_model_lang_code(target_lang_utf8, flores, (int)sizeof(flores))) {
        std::snprintf(g_error, sizeof(g_error), "no NLLB language code for '%s'", target_lang_utf8);
        return -2;
    }

    std::vector<std::string> source_tokens;
    if (!build_source_tokens(text_utf8, source_tokens)) {
        return -3;
    }
    if (source_tokens.size() <= 1) {
        set_error("the text produced no tokens");
        return -3;
    }

    try {
        const std::vector<std::vector<std::string>> batch{ source_tokens };
        // NLLB is steered by the target language token as a decoding prefix
        const std::vector<std::vector<std::string>> prefix{ { std::string(flores) } };

        ctranslate2::TranslationOptions options;
        options.beam_size = 1;                 // game strings are short; beam 1 is enough
        options.max_decoding_length = 200;

        const auto results = g_translator->translate_batch(batch, prefix, options);
        if (results.empty() || results[0].hypotheses.empty()) {
            set_error("the model returned no translation");
            return -4;
        }

        // CTranslate2 returns the forced prefix as the first token of the
        // hypothesis; it is an instruction, not part of the translation.
        std::vector<std::string> hypothesis = results[0].hypotheses[0];
        if (!hypothesis.empty() && hypothesis.front() == flores) {
            hypothesis.erase(hypothesis.begin());
        }
        if (hypothesis.empty()) {
            set_error("the model returned nothing after the language token");
            return -4;
        }

        std::string decoded;
        const auto status = g_spm->Decode(hypothesis, &decoded);
        if (!status.ok()) {
            set_error_status("could not detokenize the result", status.ToString());
            return -3;
        }
        if (decoded.empty()) {
            set_error("the model returned an empty translation");
            return -4;
        }

        out.swap(decoded);
        return (int)out.size();
    } catch (const std::exception& e) {
        std::snprintf(g_error, sizeof(g_error), "inference failed: %s", e.what());
        return -4;
    }
}

int at_model_translate(const char* text_utf8, const char* target_lang_utf8,
                       char* out_text, int out_cap)
{
    std::lock_guard<std::mutex> guard(g_lock);

    if (!text_utf8 || !target_lang_utf8 || !out_text || out_cap <= 0) {
        set_error("missing argument");
        return -2;
    }
    out_text[0] = 0;

    std::string result;
    const int rc = translate_to_string(text_utf8, target_lang_utf8, result);
    if (rc < 0) {
        return rc;
    }
    if ((int)result.size() >= out_cap) {
        set_error("the translation does not fit the output buffer");
        return -4;
    }

    std::memcpy(out_text, result.data(), result.size() + 1);
    return (int)result.size();
}

// ---------------------------------------------------------------------------
// Asynchronous translation
//
// Loading reads ~600 MB and a single string costs ~0.8 s. Both are far too slow
// for the game's frame callback, which is why the HTTP queue has the same
// submit/poll shape. The Lua side submits one string, keeps drawing, and collects
// the answer a few frames later; nothing on the game thread ever waits here.
//
// One job at a time is enough: the mod's queue is sequential by design. A submit
// while a job is running (or while an uncollected result is waiting) is refused
// with 0 rather than queued, so a stuck job cannot build up a backlog.
// ---------------------------------------------------------------------------
namespace {

std::mutex g_job_lock;
std::condition_variable g_job_cv;
bool g_job_thread_started = false;
bool g_job_pending = false;
// One job in flight, strictly - and this needs a real state, not a "pending" flag.
//
// The first version cleared the pending flag the moment the worker picked the job
// up, so while a translation was being computed the core looked idle and a second
// submit was accepted. The core then produced two results in a row while the caller
// - which polls once per frame - attributed the first one to the second string.
// From that point every translation belonged to the next key, for the rest of the
// run, silently: it was found in the game log as a chain of off-by-one entries
// (bar_color_cooldown holding bar_color's translation).
//
// With the state below, a submit is refused until the previous result has actually
// been collected, so submit/poll stay paired no matter how the caller interleaves
// them.
enum {
    JOB_IDLE = 0,       // nothing to do, nothing to collect
    JOB_RUNNING = 1,    // accepted; queued or being computed
    JOB_DONE = 2,       // finished, the result is waiting for at_model_poll
};

int g_job_state = JOB_IDLE;   // guarded by g_job_lock
std::string g_job_text;
std::string g_job_lang;
std::string g_job_result;
int g_job_rc = 0;

void job_worker()
{
    for (;;) {
        std::string text;
        std::string lang;
        {
            std::unique_lock<std::mutex> lock(g_job_lock);
            // Only RUNNING is work to pick up: DONE means "waiting to be collected",
            // and treating that as work would translate the same string twice.
            g_job_cv.wait(lock, []() { return g_job_state == JOB_RUNNING; });
            text = g_job_text;
            lang = g_job_lang;
            // deliberately left RUNNING for the whole computation
        }

        std::string result;
        int rc;
        {
            std::lock_guard<std::mutex> guard(g_lock);   // the model itself
            rc = translate_to_string(text.c_str(), lang.c_str(), result);
        }

        {
            std::lock_guard<std::mutex> lock(g_job_lock);
            g_job_result = result;
            g_job_rc = rc;
            g_job_state = JOB_DONE;
        }
    }
}

}  // namespace

// 1 = accepted, 0 = busy or a result is still waiting, <0 = refused (no model, bad args)
int at_model_submit(const char* text_utf8, const char* target_lang_utf8)
{
    if (!g_ready || !g_spm) {
        set_error("no model is loaded");
        return -1;
    }
    if (!text_utf8 || !target_lang_utf8 || !text_utf8[0]) {
        set_error("missing argument");
        return -2;
    }

    {
        std::lock_guard<std::mutex> lock(g_job_lock);
        // Busy, or a result nobody has collected yet: either way a new job would
        // push the pairing out of step (see the note above job_worker).
        if (g_job_state != JOB_IDLE) {
            return 0;
        }
        if (!g_job_thread_started) {
            // Detached on purpose: at exit the model objects are leaked rather than
            // destroyed (see the note at the top), and the same applies to this
            // thread - the process is going away anyway.
            std::thread(job_worker).detach();
            g_job_thread_started = true;
        }
        g_job_text = text_utf8;
        g_job_lang = target_lang_utf8;
        g_job_result.clear();
        g_job_rc = 0;
        g_job_state = JOB_RUNNING;
    }

    g_job_cv.notify_one();
    return 1;
}

// 0 = still working, >0 = bytes written, <0 = the job failed (at_model_error())
int at_model_poll(char* out_text, int cap)
{
    if (!out_text || cap <= 0) {
        set_error("missing argument");
        return -2;
    }

    std::lock_guard<std::mutex> lock(g_job_lock);
    if (g_job_state != JOB_DONE) {
        return 0;
    }

    g_job_state = JOB_IDLE;
    if (g_job_rc < 0) {
        return g_job_rc;
    }
    if ((int)g_job_result.size() >= cap) {
        set_error("the translation does not fit the output buffer");
        return -4;
    }

    std::memcpy(out_text, g_job_result.data(), g_job_result.size() + 1);
    return (int)g_job_result.size();
}

}  // extern "C"
