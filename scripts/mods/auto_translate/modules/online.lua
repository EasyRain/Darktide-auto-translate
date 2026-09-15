-- online.lua — drives the machine translation queue, one request at a time.
--
-- The game thread must never block, so this is a poll loop rather than a function
-- that runs to completion: mod.update() calls M.update(mod, dt) once per frame,
-- which either collects a finished response or starts the next request. All the
-- per-provider knowledge (URLs, language spellings, response shapes) lives in the
-- native core (at_core.dll) — the same code at_cli.exe exercises offline.
--
-- Why the parsing is not done here: logic in Lua can only be tested by launching
-- the game, which is exactly what we wanted to stop doing. See src/at_online.c.
local M = {}

local util
local store
local glossary
local engines
local injector

function M.init(u, s, g, e, i)
    util = u
    store = s
    glossary = g
    engines = e
    injector = i
end

-- ---------------------------------------------------------------------------
-- Native core
-- ---------------------------------------------------------------------------
local core = nil              -- ffi library handle, nil until loaded
local core_state = "unloaded" -- unloaded | ok | failed
local core_reason = nil

local CORE_PATHS = {
    "../mods/auto_translate/bin/at_core.dll",
    "mods/auto_translate/bin/at_core.dll",
    "../../mods/auto_translate/bin/at_core.dll",
}

local CDEF = [[
int at_available(void);
const char* at_error(void);
const char* at_version(void);
int at_http_get(const char*, const char*);
int at_http_post(const char*, const char*, const char*, const char*, const char*);
int at_http_poll(int*, int*, int*, char*, int, int*, unsigned long*);
int at_http_pending(void);
const char* at_win_error_text(unsigned long);
int at_set_proxy(const char*);
const char* at_proxy_in_use(void);
const char* at_proxy_hint(void);
int at_online_provider_known(const char*);
int at_online_needs_key(const char*);
int at_online_uses_post(const char*);
int at_online_host(const char*, const char*, char*, int);
int at_online_path(const char*, const char*, const char*, const char*, const char*, char*, int);
int at_online_body(const char*, const char*, const char*, const char*, char*, int);
int at_online_headers(const char*, const char*, char*, int);
const char* at_online_content_type(const char*);
int at_online_parse(const char*, const char*, char*, int);
const char* at_online_error(void);
int at_online_lang_code_for(const char*, const char*, char*, int);
int at_set_model_dir(const char*);
int at_model_ready(void);
int at_model_status(void);
int at_load_model_async(void);
int at_submit(const char*, const char*);
int at_poll(char*, int);
const char* at_model_error(void);
long long at_model_disk_size(void);
int at_model_threads(void);
int at_model_core_count(void);
int at_model_loaded_dir(char*, int);
int at_download_start(const char*, const char*, const char*);
int at_download_use_proxy(int);
int at_download_proxy_mode(void);
int at_download_route_is_proxied(const char*);
int at_download_status(void);
long long at_download_received(void);
long long at_download_total(void);
int at_download_cancel(void);
const char* at_download_error(void);
const char* at_download_path(void);
int at_sha256_file(const char*, char*, int);
long long at_file_size64(const char*);
int at_delete_file(const char*);
]]

-- Reads a C string safely: a NULL pointer is cdata (truthy!) in LuaJIT, so a
-- plain nil check is not enough.
local function cstr(ptr)
    local ffi = Mods and Mods.lua and Mods.lua.ffi
    if not (ffi and ptr) then
        return nil
    end
    local ok, s = pcall(ffi.string, ptr)
    if ok and type(s) == "string" then
        return s
    end
    return nil
end

-- Loads the DLL once. Returns the library handle, or nil plus a reason.
function M.load_core(mod)
    if core then
        return core
    end
    if core_state == "failed" then
        return nil, core_reason
    end

    local ffi = Mods and Mods.lua and Mods.lua.ffi
    if not (ffi and ffi.cdef and ffi.load) then
        core_state = "failed"
        core_reason = "LuaJIT FFI is unavailable"
        return nil, core_reason
    end

    local ok, err = pcall(ffi.cdef, CDEF)
    if not ok then
        -- re-declaring the same prototypes is harmless; do not let it stop us
        util.log(mod, "ffi.cdef reported: %s", tostring(err))
    end

    local tried = {}
    for _, path in ipairs(CORE_PATHS) do
        local loaded, handle = pcall(ffi.load, path)
        if loaded and handle then
            local probed, available = pcall(function()
                return handle.at_available()
            end)
            if probed and available == 1 then
                core = handle
                core_state = "ok"
                util.info(mod, "native core loaded: %s (v%s)", path, tostring(handle.at_version()))
                return core
            end
            tried[#tried + 1] = path .. " (loaded but not available)"
        else
            tried[#tried + 1] = path .. " (" .. tostring(handle) .. ")"
        end
    end

    core_state = "failed"
    core_reason = "at_core.dll not found or unusable: " .. table.concat(tried, "; ")
    util.warn(mod, "%s", core_reason)
    return nil, core_reason
end

function M.core_status()
    return core_state, core_reason
end

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
-- The API is paid/quota'd rather than hostile, but a burst is still a bad idea:
-- being rate limited costs a 300 s cooldown, so four requests a second is the
-- sensible ceiling. ~1800 keys take about 8 minutes.
local MIN_INTERVAL_FREE = 0.6
local MIN_INTERVAL_API = 0.25

-- HTTP 429/403 means "you are over the quota" — back off instead of burning
-- through the rest of the queue (the same idea as Lingua's 300 s cooldown).
local QUOTA_COOLDOWN = 300

local LOG_EVERY = 25

local BODY_CAP = 262144
local SMALL_CAP = 8192
local PATH_CAP = 16384

local ffi_ready = nil
local body_buf, host_buf, path_buf, out_buf, id_buf, result_buf, code_buf, len_buf, win_buf, headers_buf

local function ensure_buffers()
    if ffi_ready ~= nil then
        return ffi_ready
    end
    local ffi = Mods and Mods.lua and Mods.lua.ffi
    if not (ffi and ffi.new) then
        ffi_ready = false
        return false
    end
    -- body_buf doubles as the POST request body (the core copies it when the job
    -- is queued) and as the response buffer.
    body_buf = ffi.new("char[?]", BODY_CAP)
    host_buf = ffi.new("char[?]", 512)
    path_buf = ffi.new("char[?]", PATH_CAP)
    out_buf = ffi.new("char[?]", SMALL_CAP)
    headers_buf = ffi.new("char[?]", 1024)
    id_buf = ffi.new("int[1]")
    result_buf = ffi.new("int[1]")
    code_buf = ffi.new("int[1]")
    len_buf = ffi.new("int[1]")
    win_buf = ffi.new("unsigned long[1]")
    ffi_ready = true
    return true
end

-- ---------------------------------------------------------------------------
-- Text safety
--
-- A translation goes into the game's localization table and may pass through
-- string.format (DMF's localize always calls it). A '%' the source did not have
-- either throws "invalid option" or silently eats a character, so a translation
-- whose format specifiers do not match the source is refused rather than stored.
--
-- Scanned by hand instead of by pattern: in "%%s" the first two characters are an
-- escaped percent, and a Lua pattern cannot tell that apart from the specifier "%s".
-- ---------------------------------------------------------------------------
local FLAG_CHARS = "[-+ #0-9.]"
local CONV_CHARS = "[diouxXeEfgGqcs]"

-- Returns: counts by specifier, total specifiers, count of lone '%' (unsafe).
local function scan_format(text)
    local counts, total, strays = {}, 0, 0
    local i, n = 1, #text

    while i <= n do
        if text:sub(i, i) == "%" then
            local j = i + 1
            if text:sub(j, j) == "%" then
                i = j + 1 -- literal percent, safe
            else
                while j <= n and text:sub(j, j):match(FLAG_CHARS) do
                    j = j + 1
                end
                if text:sub(j, j):match(CONV_CHARS) then
                    local spec = text:sub(i, j)
                    counts[spec] = (counts[spec] or 0) + 1
                    total = total + 1
                    i = j + 1
                else
                    strays = strays + 1
                    i = i + 1
                end
            end
        else
            i = i + 1
        end
    end

    return counts, total, strays
end

-- The offline model marks anything it could not represent with SentencePiece's
-- unknown-token marker (U+2047). It appears whenever the model produced <unk> -
-- an out-of-vocabulary word, or a glossary placeholder whose bracket characters it
-- could not encode - and it means content was lost. Stored, it shows up in the game
-- as "⁇" in the middle of a sentence, so it is refused instead. A service never
-- returns this character, so the check costs the online path nothing.
local UNK_MARKER = "\226\129\135"   -- UTF-8 for U+2047, written byte-wise: Lua 5.1

-- Characters, not bytes: Lua's '#' counts bytes, so a 13-character Chinese translation
-- measures 39 - which made the first version of the guard below let the truncated
-- description through. This counts UTF-8 lead bytes, which LuaJIT can do without a
-- utf8 library.
local function char_count(text)
    local n = 0
    for i = 1, #text do
        local b = text:byte(i)
        if not b or b < 0x80 or b >= 0xC0 then
            n = n + 1
        end
    end
    return n
end

-- A translation that keeps only a fraction of the source is not a translation.
--
-- The offline model truncates: "Match curios whose Health blessing is at least this
-- percent (max roll 21). 0 disables this check." (102 characters) came back as
-- "請與此相關的好奇心相匹配," (13), with "curios" read as "curiosity" - two thirds of the
-- sentence simply gone, and nothing above noticed because the format-specifier check
-- has nothing to compare when the source carries no specifiers.
--
-- The bar is deliberately low, because Chinese, Japanese and Korean are far more
-- compact than English: a fourth of the character count means content was dropped, not
-- that the target language is concise. Short strings are exempt - a label is short by
-- nature - which is also why this cannot replace the guards above.
local function too_short(source, translated)
    local source_chars = char_count(source)
    if source_chars < 30 then
        return false
    end
    return char_count(translated) * 4 < source_chars
end

-- Returns true when the translation is safe to store, or false plus a reason.
function M.text_is_safe(source, translated)
    if type(source) ~= "string" or type(translated) ~= "string" or translated == "" then
        return false, "empty translation"
    end

    if translated:find(UNK_MARKER, 1, true) then
        return false, "the model could not represent part of the text (unknown tokens)"
    end

    if too_short(source, translated) then
        return false, string.format("the translation dropped most of the text (%d characters for %d)",
                                    #translated, #source)
    end

    local src_counts, src_total = scan_format(source)
    local dst_counts, dst_total, dst_strays = scan_format(translated)

    if dst_strays > 0 then
        return false, string.format("translation has %d stray '%%' the source does not have", dst_strays)
    end
    if src_total ~= dst_total then
        return false, string.format("format placeholders differ (source %d, translation %d)", src_total, dst_total)
    end
    for spec, count in pairs(src_counts) do
        if (dst_counts[spec] or 0) ~= count then
            return false, string.format("format placeholder '%s' is missing or changed", spec)
        end
    end

    return true
end

-- Text with no letters at all ("12", "—", "100") has nothing to translate.
local function has_letters(text)
    return tostring(text or ""):find("[%a]") ~= nil
end

-- Key labels - "[F10]", "[TAB]", "[Ctrl+S]", "[Mouse 1]" - are key names, not prose.
--
-- A translation service returns them untouched, which is why they were never a
-- problem before; the offline model answers them with an invented sentence instead
-- ("[TAB]" came back as "這就是我想要的.", "[F10]" as "沒有任何其他方法"), which then
-- gets stored and shown in the game's UI. Skipping them is the honest fix: there is
-- nothing to translate in a key name.
local function is_key_label(text)
    return text:match("^%[.-%]$") ~= nil
end

-- Colour-picker entries: the whole string is one {#color(r,g,b)}...#reset() run.
--
-- Several mods surface the game's entire colour palette as swatch names, and on a
-- live install that is almost the whole workload: 1300 of 1356 keys, while the
-- three mods responsible contribute two lines of real interface text between them.
-- The names are Citadel paint names ("Rakarth Flesh", "Rhinox Hide"), which players
-- know in English; translating them literally ("拉卡斯要塞的血色") makes them harder to
-- match against the paint, and short brand-like strings are exactly where a machine
-- translation drifts between calls.
--
-- Anchored, and the text between the tags may not contain braces: a string with
-- two or more coloured runs ("{#color(...)}Fire{#reset()} and {#color(...)}Ice{#reset()}")
-- is real interface text and is still translated. Only a single wrapped run counts
-- as a swatch. Set the "Translate colour names" option to take those on anyway.
local COLOUR_ENTRY = "^{#color%(%d+,%d+,%d+%)}[^{}]*{#reset%(%)}$"

local function is_colour_entry(text)
    return type(text) == "string" and text:match(COLOUR_ENTRY) ~= nil
end

-- A mod may write `en = Localize("loc_some_game_key")`. That is evaluated when the
-- file loads, so "en" ends up holding the *game's own text in the player's current
-- language* — already Chinese for a Chinese player. Sending that to a translator
-- means translating Chinese into Chinese. (Design note 3 in
-- i18n/AUTO_TRANSLATE_DESIGN.md.)
--
-- Scripts we refuse to translate *into* when the text is already written in them.
--
-- The rule exists for "Chinese into Chinese": sending a Chinese string to a Chinese
-- target makes the model answer with an invented sentence. It is deliberately limited
-- to the Chinese targets. A Japanese or Korean target with Chinese source text is a
-- legitimate translation - a Chinese mod read by a Japanese player - and a Japanese
-- string sent to a Japanese target simply comes back unchanged, which the queue
-- already tags as such.
--
-- Detected by script: one leading byte in E3..ED means a three-byte UTF-8 sequence
-- in U+3000..U+DFFF, which covers CJK ideographs, kana and Hangul.
local CJK_SAME_LANGUAGE = { ["zh-cn"] = true, ["zh-tw"] = true }

local function contains_cjk(text)
    for i = 1, #text do
        local b = text:byte(i)
        if b and b >= 0xE3 and b <= 0xED then
            return true
        end
    end
    return false
end

-- Is there anything in this string worth translating?
--
-- NOTE: this has to stay below CJK_SAME_LANGUAGE and contains_cjk. It was moved up
-- once, and because Lua resolves locals lexically at compile time that reference
-- became a global - nil at runtime - so the mod died with "attempt to index global
-- 'CJK_TARGETS'" the moment the queue started. A syntax check cannot see that;
-- tools/smoke_online.lua catches it because it actually calls this function.
local function translatable(text, lang)
    if not has_letters(text) then
        return false
    end
    if is_key_label(text) then
        return false
    end
    if CJK_SAME_LANGUAGE[lang] and contains_cjk(text) then
        return false
    end
    return true
end

-- Exposed so tools/smoke_online.lua can exercise the guards outside the game.
M.is_translatable = function(text, lang)
    return translatable(text, lang)
end

-- ---------------------------------------------------------------------------
-- Queue
--
-- Head and tail are tracked explicitly. The obvious `#queue - qhead + 1` is
-- wrong here: the table is deliberately left with nil holes where items were
-- popped, and Lua's '#' is allowed to return any border of such a table. It
-- reported a negative length and, worse, q_push could write over live entries.
-- ---------------------------------------------------------------------------
local queue, qhead, qtail = {}, 1, 0
local inflight = nil

local function q_count()
    return qtail - qhead + 1
end

local function q_push(item)
    qtail = qtail + 1
    queue[qtail] = item
end

local function q_pop()
    if qhead > qtail then
        return nil
    end
    local item = queue[qhead]
    queue[qhead] = nil
    qhead = qhead + 1
    return item
end

local function q_unshift(item)
    qhead = qhead - 1
    queue[qhead] = item
end

local function q_clear()
    queue, qhead, qtail = {}, 1, 0
end

-- ---------------------------------------------------------------------------
-- Multi-line strings: translated one line at a time, then put back together
--
-- Real mod text is full of line breaks - Enhanced_descriptions joins its English
-- descriptions with .."\n", IME_Enable ends its tooltip with "\n\n" - and a model given
-- the whole block as one request moves the breaks, drops them, or translates the text
-- on both sides of one as a single sentence ("... on Energised Hits. Immune to Ranged
-- Attacks ..." becomes one line). The game then renders one long paragraph, or loses a
-- line outright.
--
-- So the *masked* text is split at its breaks, each piece is translated on its own, and
-- the pieces are joined again with the exact separators that were removed. Masking
-- happens once for the whole string, which keeps one token list for it (no placeholders
-- are ever introduced or lost by the split itself), and the reassembled text goes
-- through accept_translation() exactly like a single-line answer, so every guard still
-- applies to the whole string.
--
-- The escape forms are handled too: a literal backslash-n (the game expands it later,
-- so it has to survive as written) and backslash-r-backslash-n.
--
-- (No pattern alternation here: Lua patterns have no "|", which is why this walks the
-- bytes and asks line_break_at() about each position.)
-- ---------------------------------------------------------------------------
local function line_break_at(text, pos)
    local c = text:sub(pos, pos)
    if c == "\n" then
        return "\n"
    end
    if c == "\r" then
        if text:sub(pos + 1, pos + 1) == "\n" then
            return "\r\n"
        end
        return "\r"
    end
    if c == "\\" then
        local next_char = text:sub(pos + 1, pos + 1)
        if next_char == "n" then
            return "\\n"                     -- the two characters, backslash and n
        end
        if next_char == "r" and text:sub(pos + 2, pos + 3) == "\\n" then
            return "\\r\\n"
        end
    end
    return nil
end

local function has_line_break(text)
    if type(text) ~= "string" then
        return false
    end
    return text:find("\n", 1, true) ~= nil
        or text:find("\r", 1, true) ~= nil
        or text:find("\\n", 1, true) ~= nil
        or text:find("\\r\\n", 1, true) ~= nil
end

-- Returns the pieces and the separators between them, so the original text can be
-- rebuilt byte for byte: split_lines("a\r\nb") -> { "a", "b" }, { "\r\n" }.
local function split_lines(text)
    local segments, separators = {}, {}
    local start, pos = 1, 1
    while pos <= #text do
        local sep = line_break_at(text, pos)
        if sep then
            segments[#segments + 1] = text:sub(start, pos - 1)
            separators[#separators + 1] = sep
            pos = pos + #sep
            start = pos
        else
            pos = pos + 1
        end
    end
    segments[#segments + 1] = text:sub(start)
    return segments, separators
end

-- The next piece that actually needs the model, skipping the ones that do not: an
-- empty line, and a piece that is only a placeholder or a key label ("[F10]"). Skipped
-- pieces are remembered verbatim, so the reassembled string keeps them.
local function next_line_segment(state, lang)
    while state.index <= #state.segments do
        local index = state.index
        local segment = state.segments[index]
        if segment == "" or not M.is_translatable(segment, lang) then
            state.done[index] = segment
            state.index = index + 1
        else
            return index, segment
        end
    end
    return nil
end

local function assemble_lines(state)
    local out = {}
    for i, segment in ipairs(state.segments) do
        out[#out + 1] = state.done[i] or segment
        if state.separators[i] then
            out[#out + 1] = state.separators[i]
        end
    end
    return table.concat(out)
end

-- True when masking left nothing to translate but placeholders: the whole string was
-- known terms ("Right", "Hive Scum"), and the answer is simply the unmasking.
--
-- Measured, this is not a micro-optimisation but the fix for a real failure: a bare
-- placeholder is exactly what these models mangle ("⟦0⟧" came back as "⁇ 0 ⁇ "), so
-- those strings used to be refused forever even though their official translation was
-- sitting in the token list. The conditions matter: something has to have been masked
-- (masked ~= en) and no letters may be left - otherwise a Cyrillic or Chinese source
-- with no glossary terms would count as "nothing to translate" and be stored as is.
local function is_fully_protected(en, masked, tokens)
    return type(masked) == "string"
        and type(en) == "string"
        and #tokens > 0
        and masked ~= en
        and not masked:find("%a")
end

-- ---------------------------------------------------------------------------
-- Batching short strings for the offline model
--
-- A label on its own has no context, and that is exactly what the model gets wrong:
-- measured on the real conversion, "Right" came back as "這樣的情況" and "Top" as
-- "排在第一位", while a batch of numbered items came back right:
--   "[1] Left [2] Center [3] Right [4] Top [5] Bottom"
--   -> "左側 [2] 中部 [3] 右側 [4] 上方 [5] 下方"
-- Numbered markers survive; "Left | Center | ..." collapsed into one sentence, so the
-- markers are what this uses. It also cuts the per-call overhead: one inference for up
-- to LOCAL_BATCH_MAX_ITEMS strings.
--
-- Only short strings are batched, and the batch is balanced by *length* rather than by
-- count, so a handful of longer phrases is not pushed into one request while a pile of
-- two-word labels can share more room. Anything that already carries its own context
-- (a sentence, or text with a line break) is translated on its own as before.
-- ---------------------------------------------------------------------------
local LOCAL_BATCH_MAX_ITEMS = 8
local LOCAL_BATCH_MAX_CHARS = 160     -- total source characters per batch
local LOCAL_BATCH_ITEM_CHARS = 24     -- longer than this is a sentence, not a label

local function batchable(item)
    if item.no_batch then
        return false                    -- a batch it was in came back unusable
    end
    local text = item.en
    return type(text) == "string" and char_count(text) <= LOCAL_BATCH_ITEM_CHARS
        and not has_line_break(text)    -- multi-line text goes through dispatch_lines()
end

local function q_peek()
    if qhead > qtail then
        return nil
    end
    return queue[qhead]
end

-- Takes the items that will travel together. `item` has already been popped; more are
-- popped only while they qualify, so nothing has to be pushed back into place.
local function take_batch(item)
    local batch = { item }
    if not batchable(item) then
        return batch
    end

    local chars = char_count(item.en)
    while #batch < LOCAL_BATCH_MAX_ITEMS do
        local nxt = q_peek()
        if not nxt or not batchable(nxt) then
            break
        end
        local size = char_count(nxt.en)
        if chars + size > LOCAL_BATCH_MAX_CHARS then
            break
        end
        q_pop()
        batch[#batch + 1] = nxt
        chars = chars + size
    end
    return batch
end

-- Splits a translated batch back into one string per input.
--
-- Returns nil when the result cannot be trusted - a marker missing, a part empty - and
-- the caller then translates those items one by one. The leading marker is allowed to
-- be missing, because the model does sometimes swallow it: item 1 is then whatever
-- comes before "[2]".
--
-- Markers are single digit: the batch cap is 8 items, so "[1]" can never be a prefix of
-- a longer marker ("[10]") and matching them textually is safe.
local function split_batch(text, count)
    if type(text) ~= "string" or count < 1 then
        return nil
    end

    if count == 1 then
        local only = text:gsub("^%s+", ""):gsub("%s+$", "")
        return only ~= "" and { only } or nil
    end

    local parts = {}
    for i = 1, count do
        local marker = "[" .. i .. "]"
        local from = text:find(marker, 1, true)

        if not from then
            if i > 1 then
                return nil
            end
            local second = text:find("[2]", 1, true)
            if not second then
                return nil
            end
            parts[1] = text:sub(1, second - 1)
        else
            local following = (i < count) and text:find("[" .. (i + 1) .. "]", from + #marker, true) or nil
            parts[i] = text:sub(from + #marker, following and (following - 1) or #text)
        end
    end

    for i = 1, count do
        local part = parts[i]
        if not part then
            return nil
        end
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        if part == "" then
            return nil
        end
        parts[i] = part
    end
    return parts
end

-- Exposed for tools/smoke_online.lua. It loads the real queue and drives the real
-- take_batch(), so the test cannot drift from what dispatch() actually does - a test
-- with its own copy of the grouping rule would keep passing while the loaded one broke.
M.plan_batch_for_tests = function(items)
    q_clear()
    for i = #items, 1, -1 do
        q_unshift(items[i])
    end

    local groups = {}
    while true do
        local first = q_pop()
        if not first then
            break
        end
        groups[#groups + 1] = take_batch(first)
    end
    return groups
end
M.split_batch_for_tests = split_batch
M.split_lines_for_tests = split_lines
M.has_line_break_for_tests = has_line_break
M.batch_limits = { items = LOCAL_BATCH_MAX_ITEMS, chars = LOCAL_BATCH_MAX_CHARS, item_chars = LOCAL_BATCH_ITEM_CHARS }

-- Exposed for tools/verify_batch.lua: the caps were chosen by measuring the real model
-- (a batch of short labels is where its word-sense errors go away, and a long one loses
-- markers), so the tool has to be able to vary them and the smoke test has to be able to
-- read them back.
function M.set_batch_limits_for_tests(items, chars, item_chars)
    LOCAL_BATCH_MAX_ITEMS = items or LOCAL_BATCH_MAX_ITEMS
    LOCAL_BATCH_MAX_CHARS = chars or LOCAL_BATCH_MAX_CHARS
    LOCAL_BATCH_ITEM_CHARS = item_chars or LOCAL_BATCH_ITEM_CHARS
    M.batch_limits.items = LOCAL_BATCH_MAX_ITEMS
    M.batch_limits.chars = LOCAL_BATCH_MAX_CHARS
    M.batch_limits.item_chars = LOCAL_BATCH_ITEM_CHARS
    return M.batch_limits
end

-- Loaded translation files, keyed by mod+language. Cached on purpose: re-reading
-- the file for every key would throw away the entries stored moments ago.
local data_cache = {}
local dirty = {}
local dirty_count = 0

local function cache_key(mod_id, lang)
    return mod_id .. "\0" .. tostring(lang)
end

local function data_for(mod_id, lang)
    local k = cache_key(mod_id, lang)
    local data = data_cache[k]
    if not data then
        data = store.load(mod_id, lang)
        if type(data) ~= "table" then
            data = { enabled = true, entries = {} }
        end
        data_cache[k] = data
    end
    return data
end

local function mark_dirty(mod_id, lang)
    local k = cache_key(mod_id, lang)
    if not dirty[k] then
        dirty_count = dirty_count + 1
    end
    dirty[k] = { mod_id = mod_id, lang = lang }
end

-- Writes every changed translation file. Returns the number written.
function M.flush(mod)
    local written = 0
    for k, item in pairs(dirty) do
        local data = data_cache[k]
        if data and store.save(item.mod_id, item.lang, data) then
            written = written + 1
        else
            util.warn(mod, "could not write translations for %s (%s)", item.mod_id, item.lang)
        end
        dirty[k] = nil
    end
    dirty_count = 0
    return written
end

-- Drops cached store tables so the next run re-reads them from disk.
function M.forget_cache()
    data_cache = {}
    dirty = {}
    dirty_count = 0
end

-- ---------------------------------------------------------------------------
-- Provider health
--
-- Some providers are simply unreachable from some networks (Google is blocked in
-- mainland China, so google_gtx fails on every single key while mymemory works
-- fine). Retrying a dead provider for every queued key would double the runtime
-- and hide the real problem, so a provider that fails to connect repeatedly is
-- dropped for the rest of the session and the log says so once.
-- ---------------------------------------------------------------------------
local PROVIDER_DISABLE_AFTER = 3

local provider_failures = {}
local disabled_providers = {}

local function note_provider_transport_failure(mod, name, reason)
    provider_failures[name] = (provider_failures[name] or 0) + 1
    if provider_failures[name] >= PROVIDER_DISABLE_AFTER and not disabled_providers[name] then
        disabled_providers[name] = reason or "unreachable"
        util.warn(mod, "provider '%s' is unreachable (%s); skipping it for the rest of this session",
            name, tostring(reason))
        if name == "google_gtx" then
            local hint = core and cstr(core.at_proxy_hint()) or nil
            if hint and hint ~= "" then
                util.warn(mod, "%s", hint)
            end
        end
    end
end

local function note_provider_success(name)
    if (provider_failures[name] or 0) > 0 then
        provider_failures[name] = 0
    end
end

function M.provider_health()
    return disabled_providers, provider_failures
end

-- The providers of an item, minus the ones this session has given up on.
local function usable_providers(list)
    local out = {}
    for _, name in ipairs(list) do
        if not disabled_providers[name] then
            out[#out + 1] = name
        end
    end
    return out
end

-- Throws away responses left in the core's result queue.
--
-- A request that is already in flight cannot be cancelled, so when a run is
-- stopped (reload, setting change) its answer arrives later and sits in the queue.
-- If the next run polls it as "its own" first response, that translation is stored
-- under the wrong key and EVERY following translation is shifted by one - silent
-- data corruption. Draining here removes the ones that already arrived; the job id
-- check in M.update catches the ones still running.
local function drain_results(mod)
    if not core or not ensure_buffers() then
        return 0
    end
    local dropped = 0
    while dropped < 64 do
        if core.at_http_poll(id_buf, result_buf, code_buf, body_buf, BODY_CAP, len_buf, win_buf) ~= 1 then
            break
        end
        dropped = dropped + 1
    end
    if dropped > 0 then
        util.info(mod, "discarded %d response(s) left over from the previous queue", dropped)
    end
    return dropped
end

-- True when the provider copes with the game's rich-text markup on its own.
-- DeepL passes "{#color(162,158,145)}Citadel Rakarth Flesh{#reset()}" through
-- intact and translates the words (verified against the live API), so masking the
-- tags would only add placeholders it can drop. The free Google endpoints return
-- such a string untranslated, so for them the tags stay masked.
--
-- The local model is not markup-safe either (NLLB happily mangles braces), so it is
-- deliberately absent from this table and gets the masked text.
local MARKUP_SAFE = { deepl = true }

-- ---------------------------------------------------------------------------
-- Local model engine
--
-- The offline engine runs through this same module on purpose: the queue, the
-- pacing, the live injection, the failure accounting and - most importantly - the
-- four anti-misalignment guards are all here, and a second copy of them would be a
-- second place to get them wrong. Only the transport differs: instead of an HTTP
-- job there is a submit/poll pair in the core, and instead of JSON there is plain
-- text.
--
-- Model status codes from the core: 0 no files, 1 files but not loaded, 2 ready,
-- 3 a background load is running.
-- ---------------------------------------------------------------------------
local MODEL_READY = 2
local MODEL_LOADING = 3

local function model_loading()
    return core ~= nil and core.at_model_status() == MODEL_LOADING
end

local function model_ready()
    return core ~= nil and core.at_model_status() == MODEL_READY
end

-- The local twin of drain_results(). The core holds at most one uncollected result,
-- and at_submit() refuses to start while that slot is full - so a result belonging
-- to a run we threw away would both block the next item and, when finally collected,
-- look like the answer to it. That is exactly the off-by-one this module fights, one
-- transport over.
local function drain_local(mod)
    if not core or not ensure_buffers() then
        return 0
    end
    local n = core.at_poll(out_buf, SMALL_CAP)
    if n > 0 then
        util.info(mod, "discarded a stale local translation (%d bytes)", n)
    elseif n < 0 then
        local why = cstr(core.at_model_error())
        util.info(mod, "discarded a stale local failure: %s", tostring(why))
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Pacing
-- ---------------------------------------------------------------------------
local elapsed = 0
local next_slot = 0
local cooldown_until = 0

M.state = {
    running = false,
    finished = false,
    lang = nil,
    engine = nil,
    provider = nil,
    is_local = false,     -- true when the queue is driven by the offline model
    model_files = 0,      -- how many of the 4 model files were found
    queued = 0,
    done = 0,
    failed = 0,
    refused = 0,
    skipped = 0,
    live = 0,
    unchanged = 0,
    parked = 0,           -- keys the offline engine gave up on (see MAX_LOCAL_REFUSALS)
    last_error = nil,
}


-- The "cores for the offline model" setting, in the form the core wants:
--   0  = automatic (min(cores/2, 8)), which is the default
--  -1  = every core, the CTranslate2 default: measurably the slowest and the one that
--        takes the machine away from the game, so it is a deliberate choice, not the
--        automatic one
--  n  = exactly n cores
local function threads_setting(mod)
    local want = mod and mod:get("model_threads")
    if type(want) == "number" then
        return want >= 0 and math.floor(want) or -1
    end
    if want == "all" then
        return -1
    end
    if type(want) == "string" and want ~= "" and want ~= "auto" then
        local n = tonumber(want)
        if n and n > 0 then
            return math.floor(n)
        end
    end
    return 0
end

-- Whether a model is in memory right now. Used by the settings handler: the offline
-- model's thread pool is fixed at load time, so a change to the thread option cannot take
-- effect until the process restarts.
function M.model_in_memory()
    return model_ready()
end

-- Says, once per session, that the model the mod asked for is not the one in memory.
--
-- Only one model fits in the game process - the core never releases one (1,663 MB for
-- the 1.3B, 3,813 MB for the 3.3B, and the whole point is to never pay both) - so
-- changing the engine takes a restart. The notice has to say so: otherwise the player
-- switches to the 3.3B and keeps getting the 1.3B's answers, with nothing anywhere
-- telling them why.
function M.note_model_switch(mod, wanted)
    if M.state.model_switch_reported then
        return
    end
    M.state.model_switch_reported = true

    local ffi = Mods.lua.ffi
    local buf = ffi.new("char[?]", 1024)
    local n = core.at_model_loaded_dir(buf, 1024)
    local loaded = n > 0 and ffi.string(buf, n) or ""
    if loaded == "" or loaded == wanted then
        return
    end

    util.warn(mod, "the model in memory is %s, not %s: restart the game to switch models (only one fits in the process)",
        loaded, tostring(wanted))
    local message = mod:localize("model_restart_needed", loaded)
    if type(mod.notify) == "function" then
        pcall(mod.notify, mod, message)
    end
    if type(mod.echo) == "function" then
        pcall(mod.echo, mod, message)
    end
end

-- The "Windows has a proxy but it is switched off" note from the core. Logged when
-- the queue starts and attached to a connection failure when one happens.
M.proxy_hint = ""

local function provider_needs_key(name)
    return name == "google_api" or name == "deepl"
end

local function providers_for(mod, engine, lang)
    if engine == "online_api" then
        return { engines.api_provider(mod) }
    end
    if engine == "online_free" then
        -- not offered in the options any more; still usable if selected by hand
        return engines.providers_for(engine, lang)
    end
    return {}
end

local function min_interval(engine)
    return engine == "online_api" and MIN_INTERVAL_API or MIN_INTERVAL_FREE
end

-- ---------------------------------------------------------------------------
-- Pipeline control
-- ---------------------------------------------------------------------------
function M.is_running()
    return M.state.running
end

-- Builds the queue from a scan report and starts (or resumes) work.
function M.start(mod, report, lang)
    local engine = engines.resolve(mod, lang)
    local gap = engines.gap(engine, lang)

    M.stop(mod)

    if engine == nil then
        util.warn(mod, "no translation engine is available (no downloaded model and no API key)")
        M.state.finished = true
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, mod:localize("no_engine_available"))
        end
        return false
    end

    if gap then
        util.warn(mod, "engine '%s' cannot produce '%s' (would return '%s'); nothing queued",
            engine, tostring(lang), tostring(gap.actual))
        return false
    end

    local providers = providers_for(mod, engine, lang)
    local is_local = engines.is_local_engine(engine) == true

    -- The offline engine needs no provider, no API key and no proxy; it needs the
    -- model on disk and (asynchronously) in memory.
    if is_local then
        providers = {}
    elseif #providers == 0 then
        util.info(mod, "engine '%s' has no online provider for '%s'", engine, tostring(lang))
        return false
    end

    if not is_local then
        local key = mod:get("online_api_key")
        local has_key = type(key) == "string" and key ~= ""
        if not has_key then
            for _, provider in ipairs(providers) do
                if provider_needs_key(provider) then
                    util.warn(mod, "provider '%s' needs an API key but none is set", provider)
                    return false
                end
            end
        end
    end

    if not M.load_core(mod) then
        return false
    end
    if not ensure_buffers() then
        util.warn(mod, "could not allocate FFI buffers; online translation disabled")
        return false
    end

    if is_local then
        -- The flat models folder, or a legacy subdirectory when that is where the files
        -- still are (an installation made before the layout was flattened).
        local dir, legacy = engines.model_dir_in_use(engine)
        if legacy then
            util.warn(mod, "the model files are in %s; with one model left they belong directly in %s",
                tostring(dir), tostring(engines.model_dir(engine)))
        end
        local files = core.at_set_model_dir(dir)
        if files < 4 then
            util.warn(mod, "the %s model is incomplete in %s (%d/4 files); not starting",
                tostring(engine), tostring(dir), files)
            return false
        end
        M.state.model_files = files

        -- How many cores the offline model may use. The core only accepts this before a
        -- model is loaded, so a change mid-session cannot apply - and saying that is the
        -- point of the check below (the setting's tooltip promises a restart).
        local wanted_threads = threads_setting(mod)
        if not core.at_set_model_threads(wanted_threads) then
            local current = core.at_model_threads()
            if wanted_threads ~= 0 and current ~= wanted_threads then
                M.state.threads_pending = true
                util.info(mod, "the thread cap (%d) applies after a restart; the loaded model uses %d",
                    wanted_threads, current)
            end
        end

        -- Loading reads 1.4 GB; on the game thread that is a visible freeze, so it
        -- runs on a background thread of the core and the HUD shows it while it
        -- lasts (see M.status().loading).
        local started = core.at_load_model_async()
        if started < 0 then
            -- Only one model fits in the process (the core never releases one), so a
            -- different model than the loaded one is refused. Saying so is the whole
            -- point: the player changed the engine and would otherwise be told nothing
            -- while the old model keeps answering.
            util.warn(mod, "could not start loading the offline model: %s", tostring(cstr(core.at_model_error())))
            M.note_model_switch(mod, dir)
            return false
        end
        if started == 1 then
            util.info(mod, "loading the offline model from %s (%d/4 files, %.0f MB) with %d of %d core(s)",
                tostring(dir), files, tonumber(core.at_model_disk_size()) / (1024 * 1024),
                core.at_model_threads(), core.at_model_core_count())
        elseif not M.state.model_switch_checked then
            -- Already loaded: the same directory is fine, a different one means the
            -- request did nothing at all.
            M.note_model_switch(mod, dir)
        end
        M.state.model_switch_checked = true
    else
        -- Proxy: an address typed in the mod options wins, otherwise the Windows
        -- setting is used when it is switched on. WinHTTP reads neither by itself.
        local proxy = mod:get("proxy")
        if type(proxy) ~= "string" then
            proxy = ""
        end
        core.at_set_proxy(proxy)
        util.info(mod, "proxy: %s", tostring(cstr(core.at_proxy_in_use())))
        -- Log only. DMF shows warnings as on-screen notifications, and "Windows has a
        -- proxy configured but switched off" is not something to interrupt the player
        -- with on every launch - it is only worth raising when a request actually
        -- fails to connect (see fail_item).
        M.proxy_hint = cstr(core.at_proxy_hint()) or ""
        if M.proxy_hint ~= "" then
            util.info(mod, "proxy note: %s", M.proxy_hint)
        end

        -- drop providers this session already found to be unreachable
        providers = usable_providers(providers)
        if #providers == 0 then
            util.warn(mod, "every online provider for '%s' has been unreachable this session", tostring(lang))
            return false
        end
    end

    local queued, skipped, colours = 0, 0, 0
    local take_colours = mod:get("translate_colours") == true

    for _, entry in ipairs(report.mods) do
        if not entry.skipped and #entry.pending > 0 then
            for _, item in ipairs(entry.pending) do
                if not take_colours and is_colour_entry(item.en) then
                    -- Swatch names: left in English on purpose (see COLOUR_ENTRY).
                    colours = colours + 1
                elseif translatable(item.en, lang) then
                    q_push({
                        mod_id = entry.name,
                        key = item.key,
                        en = item.en,
                        hash = item.hash,
                        provider_index = 1,
                        providers = providers,
                    })
                    queued = queued + 1
                else
                    skipped = skipped + 1
                end
            end
        end
    end

    M.state.running = queued > 0
    M.state.finished = queued == 0
    M.state.lang = lang
    M.state.engine = engine
    M.state.is_local = is_local
    M.state.provider = is_local and nil or providers[1]
    M.state.queued = queued
    M.state.done = 0
    M.state.failed = 0
    M.state.refused = 0
    M.state.skipped = skipped
    M.state.colours = colours
    M.state.live = 0
    M.state.unchanged = 0
    M.state.last_error = nil

    local notes = {}
    if skipped > 0 then
        notes[#notes + 1] = string.format("%d had no text to translate", skipped)
    end
    if colours > 0 then
        notes[#notes + 1] = string.format("%d colour name(s) left in English", colours)
    end
    util.info(mod, "online translation queued: %d key(s) into '%s' via %s [%s]%s",
        queued, tostring(lang), engine,
        is_local and "offline model" or table.concat(providers, ", "),
        #notes > 0 and (" (" .. table.concat(notes, ", ") .. ")") or "")

    return queued > 0
end

function M.stop(mod)
    -- Drain before clearing: see drain_results() for why this matters. The local
    -- engine has its own single-slot queue and needs the same treatment.
    drain_results(mod)
    drain_local(mod)
    q_clear()
    inflight = nil
    M.state.running = false
    M.state.finished = false
    M.state.is_local = false
end

local function finish(mod, reason)
    M.state.running = false
    M.state.finished = true
    local written = M.flush(mod)
    local translated = M.state.done - M.state.unchanged
    util.info(mod,
        "online translation %s: %d translated, %d unchanged, %d failed, %d refused, %d skipped, %d file(s) written",
        reason, translated, M.state.unchanged, M.state.failed, M.state.refused, M.state.skipped, written)
    if M.state.unchanged > 0 then
        util.info(mod, "%d key(s) came back unchanged (font names, key labels, numbers) and are marked src = 'unchanged'",
            M.state.unchanged)
    end
    if (M.state.parked or 0) > 0 then
        util.info(mod, "%d key(s) were parked: the offline model refused them %d times, so they are left alone until another engine translates this language",
            M.state.parked, MAX_LOCAL_REFUSALS)
    end

    -- One message per run, and it says what the player has to do: mod option texts
    -- are localised (and cached as plain strings) while DMF initialises `data`, so
    -- a translation produced afterwards is only picked up on the next launch.
    if type(mod.notify) == "function" and M.state.done > 0 then
        local message = mod:localize("translation_done", M.state.done, tostring(M.state.lang))
        pcall(mod.notify, mod, message)
    end
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------
local function store_translation(mod, item, text, src)
    local data = data_for(item.mod_id, M.state.lang)
    store.set_entry(data, item.key, item.en, item.hash, text, src)
    mark_dirty(item.mod_id, M.state.lang)

    -- Make it visible right away instead of waiting for the run to finish: the
    -- first pass over ~2500 keys takes tens of minutes.
    if injector and injector.set_live(item.mod_id, item.key, M.state.lang, text) then
        M.state.live = (M.state.live or 0) + 1
    end
end

-- Forward declarations. dispatch() is defined before these two, and without the
-- declaration Lua resolves the names as *globals* inside it: the calls were nil, so any
-- path through them ("the core refused the text", the fully-protected shortcut) would
-- have died with "attempt to call a nil value" instead of doing its job.
local accept_translation
local fail_item

-- Starts a request for one queued item. Returns false when nothing was started.
-- dispatch_lines() is defined further down, next to the accept path it has to use.
local dispatch_lines

local function dispatch(mod)
    local ffi = Mods.lua.ffi
    local item = q_pop()
    if not item then
        return false
    end

    -- A request from a run we already threw away can still be finishing, and its
    -- answer would sit at the head of the result queue. Nothing of ours is in flight
    -- here (dispatch is only reached with inflight == nil), so anything already
    -- queued belongs to the old run: dropping it here means the next poll cannot
    -- mistake it for our own first response and shift every later translation by one.
    -- The job-id check in M.update covers whatever is still running right now.
    drain_results(mod)

    -- The offline engine takes the same shape: throw away whatever the previous run
    -- left in the core's single result slot, then hand over this item.
    if M.state.is_local then
        drain_local(mod)

        if not model_ready() then
            -- Still loading (or failed). Put the item back untouched and let the next
            -- frame decide; M.status().loading drives the on-screen note.
            q_unshift(item)
            if not model_loading() then
                local why = cstr(core.at_model_error())
                util.warn(mod, "the offline model is not ready: %s", tostring(why))
                M.state.last_error = why
                finish(mod, "stopped: the offline model could not be loaded")
            end
            return false
        end

        -- Nothing left but known terms: the official translations are already in the
        -- token list, so the answer is the unmasking itself - deterministically, and
        -- without a request that the model can only get wrong.
        local pre_masked, pre_tokens = glossary.mask(item.en, M.state.lang, true)
        if is_fully_protected(item.en, pre_masked, pre_tokens) then
            local req = { kind = "local", item = item, masked = pre_masked, tokens = pre_tokens }
            local ok, why = accept_translation(mod, req, pre_masked, M.state.engine)
            if ok then
                engines.note_success()
            else
                fail_item(mod, req, why, 0, false, "unsafe")
            end
            return true
        end

        -- A multi-line string never goes into a batch: it is sent one line at a time
        -- and put back together verbatim (see the note above split_lines()).
        if item.line or has_line_break(item.en) then
            return dispatch_lines(mod, item)
        end


        local batch = take_batch(item)
        local parts, tokens = {}, {}
        local joined = {}

        for i, one in ipairs(batch) do
            -- Each item is masked on its own, so its placeholder indices match its own
            -- token list and every part can be restored independently. The model only
            -- has to copy the markers it is given.
            local masked, item_tokens = glossary.mask(one.en, M.state.lang, true)
            parts[i] = masked
            tokens[i] = item_tokens
            joined[i] = string.format("[%d] %s", i, masked)
        end

        local text = table.concat(joined, " ")
        local accepted = core.at_submit(text, M.state.lang)
        if accepted == 0 then
            -- The core is still busy with the previous string; try again next frame.
            if #batch > 1 then
                -- the extra items were popped for this attempt, so put them back in order
                for i = #batch, 2, -1 do
                    q_unshift(batch[i])
                end
            end
            q_unshift(item)
            return false
        end
        if accepted < 0 then
            -- Refused by the core: bad arguments (an item that masks down to
            -- nothing, say). Putting it back would retry it every frame and print a
            -- warning each time, so it is retired as a content problem - the local
            -- counterpart of "this provider will not translate this string".
            local why = cstr(core.at_model_error()) or "the offline engine refused the text"
            for i = #batch, 1, -1 do
                fail_item(mod, { kind = "local", item = batch[i] }, why, 0, false)
            end
            return true
        end

        if #batch > 1 then
            inflight = {
                kind = "local_batch",
                items = batch,
                parts = parts,
                tokens = tokens,
            }
        else
            inflight = {
                kind = "local",
                item = item,
                masked = parts[1],
                tokens = tokens[1],
                src = M.state.engine,
            }
        end
        -- The local model is CPU-bound rather than rate limited: no pacing delay
        -- beyond the frame, which is what keeps a 2500-key pass at ~180 ms apiece.
        next_slot = elapsed
        return true
    end

    local provider = nil
    for i = item.provider_index or 1, #item.providers do
        if not disabled_providers[item.providers[i]] then
            provider = item.providers[i]
            item.provider_index = i
            break
        end
    end

    if not provider then
        -- Every provider this language had was ruled out. Consuming the rest of
        -- the queue here would count hundreds of "refusals" without a single
        -- request (that happened: 252 items drained in two seconds), so stop.
        M.state.last_error = "no usable provider left"
        util.warn(mod, "no online provider is usable for '%s'; stopping with %d key(s) left",
            tostring(M.state.lang), q_count())
        q_unshift(item)
        finish(mod, "stopped: every provider was unreachable")
        return false
    end
    M.state.provider = provider

    local api_key = nil
    if provider_needs_key(provider) then
        api_key = mod:get("online_api_key")
        if type(api_key) ~= "string" or api_key == "" then
            M.state.last_error = "no API key"
            M.state.failed = M.state.failed + 1
            return false
        end
    end

    -- Glossary masking: official terms become placeholders so a service cannot
    -- paraphrase them; they are restored from the token list afterwards. Rich-text
    -- markup is masked too, but only for providers that cannot handle it.
    local masked, tokens = glossary.mask(item.en, M.state.lang, not MARKUP_SAFE[provider])

    if core.at_online_host(provider, api_key, host_buf, 512) == 0 then
        M.state.last_error = cstr(core.at_online_error())
        M.state.failed = M.state.failed + 1
        util.warn(mod, "could not build request for %s: %s", provider, tostring(M.state.last_error))
        return false
    end
    if core.at_online_path(provider, api_key, "en", M.state.lang, masked, path_buf, PATH_CAP) == 0 then
        M.state.last_error = cstr(core.at_online_error())
        M.state.failed = M.state.failed + 1
        util.warn(mod, "could not build request path for %s: %s", provider, tostring(M.state.last_error))
        return false
    end

    -- Providers that take their query in the body (DeepL) also need an auth header.
    local job
    if core.at_online_uses_post(provider) == 1 then
        if core.at_online_body(provider, "en", M.state.lang, masked, body_buf, BODY_CAP) == 0 then
            M.state.last_error = cstr(core.at_online_error())
            M.state.failed = M.state.failed + 1
            util.warn(mod, "could not build the request body for %s: %s", provider, tostring(M.state.last_error))
            return false
        end
        if core.at_online_headers(provider, api_key, headers_buf, 1024) == 0 then
            M.state.last_error = cstr(core.at_online_error())
            M.state.failed = M.state.failed + 1
            util.warn(mod, "could not build the request headers for %s: %s", provider, tostring(M.state.last_error))
            return false
        end
        job = core.at_http_post(host_buf, path_buf, core.at_online_content_type(provider),
                                headers_buf, body_buf)
    else
        job = core.at_http_get(host_buf, path_buf)
    end

    if job <= 0 then
        M.state.last_error = cstr(core.at_error())
        M.state.failed = M.state.failed + 1
        util.warn(mod, "request rejected by the native core: %s", tostring(M.state.last_error))
        return false
    end

    inflight = {
        item = item,
        provider = provider,
        job = job,
        masked = masked,
        tokens = tokens,
    }
    next_slot = elapsed + min_interval(M.state.engine)
    return true
end

-- Stores `raw` as the translation of req.item, after undoing the glossary masking
-- and checking that the result is safe to put into a localization table.
--
-- Shared by the HTTP providers and the local model so the rules cannot differ: an
-- engine that skips the format-specifier check or the unchanged tagging would write
-- broken strings or inflate the "translated" count.
function accept_translation(mod, req, raw, src)
    local item = req.item

    local restored, missing = glossary.unmask(raw, req.tokens)
    if missing and missing > 0 then
        -- The code is kept for the log and the refusal budget in fail_item(): a lost
        -- placeholder is the one refusal a *different* engine may well handle.
        return false, string.format("%d glossary term(s) were dropped by the service", missing), false, "tokens"
    end

    -- The service handed the text back unchanged. That is usually a correct answer,
    -- not a failure: font names ("{#font(arial)}Arial{#reset()}"), key labels
    -- ("[F10]") and numbers have nothing to translate, and forcing them through
    -- again would waste a request every run forever.
    --
    -- So it is stored - but tagged, because it is not a translation: the file says
    -- which keys are effectively still English, the summary counts them separately,
    -- and a human translator can find them with a search for src = "unchanged".
    -- (This comparison used to read item.masked, a field the queue item does not
    -- have, so the whole check was dead and the tag was never applied.)
    if restored == req.masked then
        store_translation(mod, item, restored, "unchanged")
        M.state.done = M.state.done + 1
        M.state.unchanged = M.state.unchanged + 1
        util.log(mod, "unchanged %s:%s -> %s", item.mod_id, item.key, restored)

        if M.state.done % LOG_EVERY == 0 then
            M.flush(mod)
            util.info(mod, "progress: %d done (%d translated, %d unchanged), %d failed, %d refused, %d left",
                M.state.done, M.state.done - M.state.unchanged, M.state.unchanged,
                M.state.failed, M.state.refused, q_count())
        end
        return true
    end

    local safe, why = M.text_is_safe(item.en, restored)
    if not safe then
        return false, why, false, "unsafe"
    end

    store_translation(mod, item, restored, src)
    M.state.done = M.state.done + 1

    util.log(mod, "translated %s:%s -> %s", item.mod_id, item.key, restored)
    if M.state.done % LOG_EVERY == 0 then
        -- persist as we go: a crash or a quit mid-run must not lose the work
        local written = M.flush(mod)
        util.info(mod, "progress: %d translated (%d live), %d failed, %d refused, %d left (%d file(s) saved)",
            M.state.done, M.state.live, M.state.failed, M.state.refused, q_count(), written)
    end
    return true
end

-- Parses a response and stores the result.
-- Returns true, or false plus a reason and whether this was a transport problem.
local function handle_response(mod, req, body)
    local ffi = Mods.lua.ffi
    local item = req.item

    local n = core.at_online_parse(req.provider, body, out_buf, SMALL_CAP)
    if n < 0 then
        -- A response we cannot read is a problem with *this text* or with the
        -- reply, not with the connection: it must not count towards disabling the
        -- provider or tripping the circuit breaker. (Google answers [null,...]
        -- for text it will not translate, which used to take a healthy provider
        -- offline after three keys.)
        local why = cstr(core.at_online_error()) or "unreadable response"
        util.warn(mod, "%s could not be read from %s: %s", item.key, req.provider, tostring(why))
        return false, why, false
    end

    return accept_translation(mod, req, ffi.string(out_buf, n), req.provider)
end

-- Records one refusal of an item by the engine in use and returns the running total.
-- Written straight to the store (and marked dirty) so the budget survives a crash, a
-- restart or a reload - a count that lived only in memory would be reset by exactly the
-- events that make a player reload the translations.
local function note_local_refusal(mod, item)
    local data = data_for(item.mod_id, M.state.lang)
    local total = store.note_refusal(data, item.key, item.en, item.hash, M.state.engine)
    mark_dirty(item.mod_id, M.state.lang)
    return total
end

-- How many times the offline model may refuse one string before the key is parked.
--
-- A refusal is a content problem: the same model asked the same way will answer the same
-- way, so the alternative to a budget is either retrying it on every launch forever or
-- dropping it silently. Three tries, then the refusal is written to the store
-- (store.note_refusal) and the scanner leaves the key alone *for that engine*: switching
-- to the API - or to the other model - picks it up again, which is exactly when a retry
-- can produce something better.
local MAX_LOCAL_REFUSALS = 3

-- Whether the local engine should try this string again after `refusals` refusals.
local function retry_after_refusal(refusals)
    return (tonumber(refusals) or 0) < MAX_LOCAL_REFUSALS
end

M.retry_after_refusal_for_tests = retry_after_refusal
M.max_local_refusals = MAX_LOCAL_REFUSALS
M.is_fully_protected_for_tests = is_fully_protected

-- Retries the current item on the next provider, or gives up on it.
-- `transport` marks a genuine engine problem (network/HTTP), which is what the
-- provider health tracker and the circuit breaker count; a refused translation is
-- a content problem and must not pause the engine.
-- `code` says *why* it failed, because one reason is worth a different second attempt:
-- "tokens" means the glossary placeholders went missing, and the same sentence without
-- masking may well come back translated.
function fail_item(mod, req, reason, http_status, transport, code)
    local item = req.item

    -- The offline engine has no provider to blame and no quota to respect. A string it
    -- cannot translate is a content problem - the same category as a service refusing
    -- one - so it is counted as refused, which deliberately does not pause anything. A
    -- model that is actually broken is caught in dispatch() (not ready -> finish), so
    -- this cannot spin forever.
    if req.kind == "local" then
        -- Count the refusal (in the store, so it survives the run) and try again until the
        -- budget is used up. What is *not* done any more is translating the string again
        -- without the glossary masking: measured, that mostly traded a missing term for a
        -- wrong script variant and lost the official terminology, and a refusal is the
        -- honest outcome for a string this model cannot do.
        local refusals = note_local_refusal(mod, item)
        if retry_after_refusal(refusals) then
            util.info(mod, "%s:%s was refused (%d of %d); trying it again",
                item.mod_id, item.key, refusals, MAX_LOCAL_REFUSALS)
            q_unshift(item)
            return
        end

        M.state.last_error = reason
        M.state.refused = M.state.refused + 1
        M.state.parked = (M.state.parked or 0) + 1
        util.info(mod, "%s:%s refused %d times by '%s' (%s); parked until another engine translates this language",
            item.mod_id, item.key, refusals, tostring(M.state.engine), tostring(reason))
        return
    end

    if http_status == 429 or http_status == 403 then
        cooldown_until = elapsed + QUOTA_COOLDOWN
        util.warn(mod, "service is rate limiting (HTTP %d); pausing translation for %d s",
            http_status, QUOTA_COOLDOWN)
        q_unshift(item) -- retried once the cooldown expires
        M.state.provider = nil
        return
    end

    if transport then
        note_provider_transport_failure(mod, req.provider, reason)
    else
        note_provider_success(req.provider)
    end

    -- advance to the next provider that this session has not given up on
    local next_index = nil
    local index = item.provider_index or 1
    while item.providers[index + 1] do
        index = index + 1
        if not disabled_providers[item.providers[index]] then
            next_index = index
            break
        end
    end

    if next_index then
        item.provider_index = next_index
        util.log(mod, "provider %s failed (%s); retrying with %s",
            req.provider, tostring(reason), item.providers[next_index])
        q_unshift(item)
        return
    end

    M.state.last_error = reason

    if transport then
        M.state.failed = M.state.failed + 1
        util.warn(mod, "could not translate %s:%s (%s)", item.mod_id, item.key, tostring(reason))
        engines.note_failure(mod, reason)
        if engines.is_paused() then
            M.state.running = false
        end
    else
        M.state.refused = M.state.refused + 1
        util.info(mod, "refused %s:%s (%s)", item.mod_id, item.key, tostring(reason))
    end
end

-- Puts items back at the head of the queue, marked so that take_batch() leaves them
-- alone. Used when a batch answer cannot be attributed to individual items: the same
-- items must not be grouped again, or the retry would fail the same way forever.
local function requeue_no_batch(items)
    for i = #items, 1, -1 do
        local one = items[i]
        one.no_batch = true
        q_unshift(one)
    end
end

-- Why a part of a batch answer cannot be used as it stands, or nil when it can.
--
-- Two reasons, both measured against the real model:
--   * the placeholders are gone, so the part cannot be restored safely;
--   * the model handed the label back unchanged. Inside a numbered list that is how it
--     says "nothing to translate here", and it is not to be trusted: the very same
--     strings, translated on their own, came back as "退出" for "EXIT" and "購買" for
--     "BUY", while the batch left both in English. A batch is only allowed to be
--     *better* than a solo request, never worse, so an unchanged part is refused here
--     and the item is retried on its own.
local function batch_part_refusal(item, masked, part, tokens)
    local restored, missing = glossary.unmask(part, tokens)
    if missing and missing > 0 then
        return string.format("%d glossary term(s) were dropped", missing)
    end
    if restored == masked then
        return "the batch left it unchanged"
    end
    local safe, why = M.text_is_safe(item.en, restored)
    if not safe then
        return why
    end
    return nil
end

-- Exposed for tools/smoke_online.lua: this is a rule, not plumbing, and it is the rule
-- that decides whether a batch is allowed to replace a solo answer.
M.batch_part_refusal_for_tests = batch_part_refusal

-- Stores the answer to a batched local request.
--
-- Each part is restored and checked on its own, exactly like a solo answer, and the
-- parts that come back clean are stored. A part that does not is retried on its own -
-- never dropped - because a batch that half-failed is still a batch whose answer
-- covers several strings, and guessing which text belongs to which key is the one
-- failure this module must not make. The retried item carries no_batch, so a second
-- failure ends in the usual refusal instead of an endless regroup.
local function handle_local_batch(mod, req, raw)
    local parts = split_batch(raw, #req.items)

    if not parts then
        util.info(mod, "the offline model did not keep the batch markers; %d item(s) go through one at a time",
            #req.items)
        requeue_no_batch(req.items)
        return
    end

    local stored, retry = 0, {}
    for i, item in ipairs(req.items) do
        local why = batch_part_refusal(item, req.parts[i], parts[i], req.tokens[i])

        if not why then
            -- accept_translation() repeats the same checks and stores; it cannot fail
            -- here, but a false answer is still treated as a reason to retry rather
            -- than to drop the item.
            local ok, failed = accept_translation(mod, {
                kind = "local",
                item = item,
                masked = req.parts[i],
                tokens = req.tokens[i],
            }, parts[i], M.state.engine)
            if ok then
                stored = stored + 1
            else
                why = failed
            end
        end

        if why then
            retry[#retry + 1] = item
            util.log(mod, "%s:%s came back unusable from a batch (%s); retrying it on its own",
                item.mod_id, item.key, tostring(why))
        end
    end

    if stored > 0 then
        engines.note_success()
    end
    if #retry > 0 then
        requeue_no_batch(retry)
    end
end

-- The loaded native library, for modules that need the same DLL (the model downloader).
function M.core()
    return core
end

-- The offline engine has three inflight shapes: "local" for one string, "local_batch"
-- for several, "local_line" for one line of a multi-line string. All three are collected
-- from the core's single result slot.
local function is_local_request(kind)
    return kind == "local" or kind == "local_batch" or kind == "local_line"
end


-- Sends the next line of a multi-line item, or stores the item once every line is in.
-- The state lives on the item (item.line), so an item can go back into the queue between
-- two lines without losing what was already translated.
function dispatch_lines(mod, item)
    local state = item.line
    if not state then
        local masked, tokens = glossary.mask(item.en, M.state.lang, true)
        local segments, separators = split_lines(masked)
        state = {
            masked = masked,
            tokens = tokens,
            segments = segments,
            separators = separators,
            done = {},
            index = 1,
        }
        item.line = state
    end

    local index, segment = next_line_segment(state, M.state.lang)
    if not index then
        -- Every line is translated (or did not need translating). The answer goes through
        -- the same accept path as a single-line one, so the format-specifier, placeholder
        -- and truncation guards see the whole string.
        local req = {
            kind = "local",
            item = item,
            masked = state.masked,
            tokens = state.tokens,
            src = M.state.engine,
        }
        local ok, why, transport, code = accept_translation(mod, req, assemble_lines(state), req.src)
        if ok then
            engines.note_success()
        else
            fail_item(mod, req, why, 0, transport, code)
        end
        return true
    end

    local accepted = core.at_submit(segment, M.state.lang)
    if accepted == 0 then
        -- The core is still busy with the previous line; try again next frame. The item
        -- keeps its state, so nothing already translated is lost.
        q_unshift(item)
        return false
    end
    if accepted < 0 then
        local why = cstr(core.at_model_error()) or "the offline engine refused the text"
        fail_item(mod, { kind = "local", item = item }, why, 0, false, "core")
        return true
    end

    inflight = { kind = "local_line", item = item, index = index }
    next_slot = elapsed
    return true
end

-- ---------------------------------------------------------------------------
-- Per-frame driver
-- ---------------------------------------------------------------------------
function M.update(mod, dt)
    if not M.state.running then
        return
    end
    if not core then
        M.state.running = false
        return
    end

    local ffi = Mods.lua.ffi
    elapsed = elapsed + (dt or 0)

    -- 1. collect a finished response
    if inflight and is_local_request(inflight.kind) then
        local n = core.at_poll(out_buf, SMALL_CAP)

        if n == 0 then
            -- still working; one request at a time
            return
        end

        local req = inflight
        inflight = nil

        if n < 0 then
            local why = cstr(core.at_model_error()) or "the offline model failed"
            local reason = "offline model: " .. tostring(why)
            if req.kind == "local_batch" then
                -- The failure belongs to the combined request (a result that does not
                -- fit the buffer, say), not to the individual strings, so they are asked
                -- again one at a time instead of being written off as refused.
                M.state.last_error = reason
                util.warn(mod, "the offline model failed on a batch of %d (%s); retrying them one at a time",
                    #req.items, tostring(why))
                requeue_no_batch(req.items)
            else
                fail_item(mod, req, reason, 0, false, req.code)
            end
        elseif req.kind == "local_batch" then
            handle_local_batch(mod, req, ffi.string(out_buf, n))
        elseif req.kind == "local_line" then
            -- One line of a multi-line string: keep it and go back into the queue for
            -- the next one. The item is only stored once every line is in (dispatch_lines).
            req.item.line.done[req.index] = ffi.string(out_buf, n)
            req.item.line.index = req.index + 1
            q_unshift(req.item)
        else
            local ok, why, transport, code = accept_translation(mod, req, ffi.string(out_buf, n), req.src or M.state.engine)
            if ok then
                engines.note_success()
            else
                fail_item(mod, req, why, 0, transport, code)
            end
        end
    elseif inflight then
        local rc = core.at_http_poll(id_buf, result_buf, code_buf, body_buf, BODY_CAP, len_buf, win_buf)

        if rc == 1 then
            local got_id = id_buf[0]

            -- The answer must belong to the request we are waiting for. A response
            -- from a queue we already discarded would otherwise be attributed to the
            -- item in hand, and every later translation would be off by one.
            if got_id ~= inflight.job then
                util.info(mod, "discarding stale response %d (waiting for %d)", got_id, inflight.job)
                return
            end

            local req = inflight
            inflight = nil
            local result = result_buf[0]   -- 0 = completed, <0 = transport failure
            local http_code = code_buf[0]  -- only meaningful when result == 0

            if result == 0 and http_code >= 200 and http_code < 300 then
                local len = len_buf[0]
                local body = len > 0 and ffi.string(body_buf, len) or ""
                local ok, why, transport = handle_response(mod, req, body)
                if ok then
                    engines.note_success()
                else
                    fail_item(mod, req, why, 0, transport)
                end
            elseif result == 0 then
                -- completed, but the service answered with an error status
                fail_item(mod, req, string.format("HTTP %d", http_code), http_code, true)
            else
                local win = win_buf[0]
                local text = win ~= 0 and cstr(core.at_win_error_text(win)) or nil
                local reason = string.format("network error %d (%s)", result, text or "no detail")
                -- This is the moment the proxy note is actually worth showing.
                if (win == 12029 or win == 12007 or win == 12185) and M.proxy_hint ~= "" then
                    reason = reason .. " - " .. M.proxy_hint
                end
                fail_item(mod, req, reason, 0, true)
            end
        elseif rc < 0 then
            local req = inflight
            inflight = nil
            fail_item(mod, req, "native core poll failed", 0, true)
        else
            -- still waiting; one request in flight at a time
            return
        end
    end

    -- 2. pacing and cooldown
    if elapsed < next_slot then
        return
    end
    if cooldown_until > 0 and elapsed < cooldown_until then
        return
    end
    cooldown_until = 0

    -- 3. nothing left to do
    if q_count() <= 0 then
        finish(mod, "finished")
        return
    end

    -- 4. start the next request
    dispatch(mod)
end

-- Progress snapshot for the HUD and for the options buttons.
function M.status()
    local disabled = {}
    for name, reason in pairs(disabled_providers) do
        disabled[#disabled + 1] = name .. " (" .. tostring(reason) .. ")"
    end

    return {
        running = M.state.running,
        finished = M.state.finished,
        lang = M.state.lang,
        engine = M.state.engine,
        provider = M.state.provider,
        local_engine = M.state.is_local == true,
        -- The offline model loads in the background at the start of a run; the HUD
        -- says so instead of leaving the player wondering why nothing is happening.
        loading = M.state.is_local == true and model_loading(),
        queued = M.state.queued,
        left = q_count(),
        done = M.state.done,
        failed = M.state.failed,
        refused = M.state.refused,
        skipped = M.state.skipped,
        live = M.state.live or 0,
        unchanged = M.state.unchanged or 0,
        cooldown = math.max(0, math.floor(cooldown_until - elapsed)),
        last_error = M.state.last_error,
        disabled_providers = table.concat(disabled, ", "),
    }
end

return M
