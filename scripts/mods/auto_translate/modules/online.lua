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

-- Returns true when the translation is safe to store, or false plus a reason.
function M.text_is_safe(source, translated)
    if type(source) ~= "string" or type(translated) ~= "string" or translated == "" then
        return false, "empty translation"
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

-- A mod may write `en = Localize("loc_some_game_key")`. That is evaluated when the
-- file loads, so "en" ends up holding the *game's own text in the player's current
-- language* — already Chinese for a Chinese player. Sending that to a translator
-- means translating Chinese into Chinese. (Design note 3 in
-- i18n/AUTO_TRANSLATE_DESIGN.md.)
--
-- Detected by script: one leading byte in E3..ED means a three-byte UTF-8 sequence
-- in U+3000..U+DFFF, which covers CJK ideographs, kana and Hangul.
local CJK_TARGETS = { ["zh-cn"] = true, ["zh-tw"] = true, ja = true, ko = true }

local function contains_cjk(text)
    for i = 1, #text do
        local b = text:byte(i)
        if b and b >= 0xE3 and b <= 0xED then
            return true
        end
    end
    return false
end

local function translatable(text, lang)
    if not has_letters(text) then
        return false
    end
    if CJK_TARGETS[lang] and contains_cjk(text) then
        return false
    end
    return true
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
    queued = 0,
    done = 0,
    failed = 0,
    refused = 0,
    skipped = 0,
    live = 0,
    last_error = nil,
}

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
    if #providers == 0 then
        util.info(mod, "engine '%s' has no online provider for '%s'", engine, tostring(lang))
        return false
    end

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

    if not M.load_core(mod) then
        return false
    end
    if not ensure_buffers() then
        util.warn(mod, "could not allocate FFI buffers; online translation disabled")
        return false
    end

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

    local queued, skipped = 0, 0

    for _, entry in ipairs(report.mods) do
        if not entry.skipped and #entry.pending > 0 then
            for _, item in ipairs(entry.pending) do
                if translatable(item.en, lang) then
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
    M.state.provider = providers[1]
    M.state.queued = queued
    M.state.done = 0
    M.state.failed = 0
    M.state.refused = 0
    M.state.skipped = skipped
    M.state.live = 0
    M.state.last_error = nil

    util.info(mod, "online translation queued: %d key(s) into '%s' via %s [%s]%s",
        queued, tostring(lang), engine, table.concat(providers, ", "),
        skipped > 0 and string.format(" (%d key(s) had nothing to translate)", skipped) or "")

    return queued > 0
end

function M.stop(mod)
    q_clear()
    inflight = nil
    M.state.running = false
    M.state.finished = false
end

local function finish(mod, reason)
    M.state.running = false
    M.state.finished = true
    local written = M.flush(mod)
    util.info(mod,
        "online translation %s: %d translated, %d failed, %d refused, %d skipped, %d file(s) written",
        reason, M.state.done, M.state.failed, M.state.refused, M.state.skipped, written)

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

-- Starts a request for one queued item. Returns false when nothing was started.
local function dispatch(mod)
    local ffi = Mods.lua.ffi
    local item = q_pop()
    if not item then
        return false
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
    -- paraphrase them; they are restored from the token list afterwards.
    local masked, tokens = glossary.mask(item.en, M.state.lang)

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

    local raw = ffi.string(out_buf, n)
    local restored, missing = glossary.unmask(raw, req.tokens)
    if missing and missing > 0 then
        return false, string.format("%d glossary term(s) were dropped by the service", missing), false
    end

    -- Some services hand the source straight back when they cannot help.
    if restored == item.masked then
        return false, "the service returned the source text unchanged", false
    end

    local safe, why = M.text_is_safe(item.en, restored)
    if not safe then
        return false, why, false
    end

    store_translation(mod, item, restored, req.provider)
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

-- Retries the current item on the next provider, or gives up on it.
-- `transport` marks a genuine engine problem (network/HTTP), which is what the
-- provider health tracker and the circuit breaker count; a refused translation is
-- a content problem and must not pause the engine.
local function fail_item(mod, req, reason, http_status, transport)
    local item = req.item

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
    if inflight then
        local rc = core.at_http_poll(id_buf, result_buf, code_buf, body_buf, BODY_CAP, len_buf, win_buf)

        if rc == 1 then
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
        queued = M.state.queued,
        left = q_count(),
        done = M.state.done,
        failed = M.state.failed,
        refused = M.state.refused,
        skipped = M.state.skipped,
        live = M.state.live or 0,
        cooldown = math.max(0, math.floor(cooldown_until - elapsed)),
        last_error = M.state.last_error,
        disabled_providers = table.concat(disabled, ", "),
    }
end

return M
