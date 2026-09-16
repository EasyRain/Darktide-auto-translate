-- exporter.lua — collects official terminology for the current game language.
--
-- Why: the game can only be switched to another language through Steam + a
-- restart, so instead of asking for that repeatedly, every launch writes out the
-- terms of the CURRENT language (once per language / key list version). The player
-- closes the game, switches language, launches again — and after a few rounds all
-- languages are collected.
--
-- Output: ../mods/auto_translate/translations/export/<language>.lua
--     return { lang = "ja", version = 1, exported_at = 0, terms = { ["loc_key"] = "…" } }
local M = {}

local util
function M.init(u)
    util = u
end

-- Languages the game ships (used for the "what is still missing" progress note).
local TRACKED_LANGS = { "en", "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br" }

local function export_path(lang)
    return util.MOD_DIR .. "/translations/export/" .. tostring(lang) .. ".lua"
end

-- Returns done[], missing[], done_count, total
function M.progress()
    local done, missing = {}, {}
    for _, lang in ipairs(TRACKED_LANGS) do
        if util.file_exists(export_path(lang)) then
            done[#done + 1] = lang
        else
            missing[#missing + 1] = lang
        end
    end
    return done, missing, #done, #TRACKED_LANGS
end

-- Number of terms in an existing export file (for the "already collected" note).
local function existing_count(lang)
    local data = util.load_lua_file(export_path(lang))
    if type(data) ~= "table" or type(data.terms) ~= "table" then
        return nil
    end
    local n = 0
    for _ in pairs(data.terms) do
        n = n + 1
    end
    return n
end

-- One visible notice per event (see util.popup): this used to send the same sentence to
-- both the toast and the chat box.
local function notify(mod, key, ...)
    util.popup(mod, key, ...)
end

local function load_key_list()
    local path = util.MOD_DIR .. "/translations/term_keys.lua"
    if not util.file_exists(path) then
        return nil, "term_keys.lua not found"
    end
    local data, err = util.load_lua_file(path)
    if type(data) ~= "table" or type(data.keys) ~= "table" then
        return nil, "term_keys.lua has no 'keys' table (" .. tostring(err) .. ")"
    end
    return data
end

-- Reads a localization key in the current game language.
-- Returns nil when the key does not exist (the game hands back the key itself).
local function lookup(key)
    local localize = rawget(_G, "Localize")
    if type(localize) ~= "function" then
        return nil
    end
    local ok, text = pcall(localize, key)
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    if text == key or text:sub(1, 1) == "<" then
        return nil
    end
    return text
end

-- Keeps non-ASCII text readable (unlike string.format("%q", ...)).
local function quote(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "")
    return "\"" .. s .. "\""
end

local function now()
    local oslib = (Mods and Mods.lua and Mods.lua.os) or os
    return (oslib and oslib.time and oslib.time()) or 0
end

local function serialize(lang, version, terms)
    local out = {}
    out[#out + 1] = "-- Auto Translate term export for language: " .. tostring(lang)
    out[#out + 1] = "-- Generated automatically from the game's own localisation; safe to delete."
    out[#out + 1] = "return {"
    out[#out + 1] = "    lang = " .. quote(lang) .. ","
    out[#out + 1] = string.format("    version = %d,", version or 0)
    out[#out + 1] = string.format("    exported_at = %d,", now())
    out[#out + 1] = "    terms = {"

    local keys = {}
    for k in pairs(terms) do
        keys[#keys + 1] = k
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        out[#out + 1] = "        [" .. quote(k) .. "] = " .. quote(terms[k]) .. ","
    end

    out[#out + 1] = "    },"
    out[#out + 1] = "}"
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

-- Returns true when this run exported something.
-- Is there a way to dump *everything* instead of a key list?
--
-- The strings live in the game's bundles, so a key list is the only handle we have - unless the
-- localization manager keeps its table somewhere reachable, in which case one launch per language
-- would collect every string the game has and no later key list would ever need another collection.
-- This logs the shape of that object (field names, types, and how many entries a table field
-- holds), once, at most fifteen fields, wrapped in pcall. It writes nothing and changes nothing:
-- the point is to answer the question from a log instead of guessing at field names.
function M.describe_localization(mod)
    local ok, report = pcall(function()
        local manager = Managers and Managers.localization
        if type(manager) ~= "table" then
            return "Managers.localization is " .. type(manager)
        end

        local fields = {}
        for name, value in pairs(manager) do
            fields[#fields + 1] = { name = tostring(name), kind = type(value), value = value }
        end
        table.sort(fields, function(a, b) return a.name < b.name end)

        local lines = { string.format("%d field(s) on Managers.localization", #fields) }
        for i = 1, math.min(#fields, 15) do
            local field = fields[i]
            local detail = field.kind
            if field.kind == "table" then
                local count = 0
                for _ in pairs(field.value) do count = count + 1 end
                detail = string.format("table(%d entry/entries)", count)
                -- One sample key, so a table of translations can be told from a table of settings.
                for key, sample in pairs(field.value) do
                    detail = detail .. string.format(", e.g. %s = %s", tostring(key),
                        type(sample) == "string" and ("\"" .. sample:sub(1, 24) .. "\"") or type(sample))
                    break
                end
            end
            lines[#lines + 1] = string.format("  %s = %s", field.name, detail)
        end
        return table.concat(lines, "\n")
    end)

    if ok and type(report) == "string" then
        util.info(mod, "localization manager shape:\n%s", report)
    else
        util.log(mod, "could not describe Managers.localization: %s", tostring(report))
    end
end

function M.run(mod, lang)
    local list, err = load_key_list()
    if not list then
        util.warn(mod, "term export skipped: %s", tostring(err))
        return false
    end

    local path = export_path(lang)

    -- already collected for this language at the current key list version?
    if util.file_exists(path) then
        local existing = util.load_lua_file(path)
        if type(existing) == "table" and existing.version == list.version then
            local count = existing_count(lang) or 0
            -- Log only, no popup: this path runs on every launch, and a notice that nothing
            -- happened is the noise that got the automatic call removed in the first place. A
            -- collection that actually writes still announces itself (term_export_done).
            util.log(mod, "term export for '%s' is up to date (version %s, %d term(s))",
                tostring(lang), tostring(list.version), count)
            return false
        end
    end

    local terms = {}
    local missing = 0
    for _, key in ipairs(list.keys) do
        local text = lookup(key)
        if text then
            terms[key] = text
        else
            missing = missing + 1
        end
    end

    local count = 0
    for _ in pairs(terms) do
        count = count + 1
    end

    if count == 0 then
        util.warn(mod, "term export: no key resolved (is Localize() available? language '%s')", tostring(lang))
        return false
    end

    util.ensure_dir(util.MOD_DIR .. "/translations/export")
    local ok = util.write_file_atomic(path, serialize(lang, list.version, terms))
    if not ok then
        util.warn(mod, "term export: could not write %s", path)
        return false
    end

    util.info(mod, "exported %d term(s) for '%s' (skipped %d unknown keys) -> translations/export/%s.lua",
        count, tostring(lang), missing, tostring(lang))

    -- Note: placeholders are ordered %d then %s in every translation of these keys.
    notify(mod, "term_export_done", count, tostring(lang))
    M.notify_progress(mod)

    return true
end

-- ---- string cache harvest ----
--
-- The export above can only ask for key names somebody wrote down, and the game answers with the
-- ones it has: 701 of the 1459 names in translations/term_keys.lua resolve and the rest do not exist
-- (the log line says "skipped 758 unknown keys"). A term whose key nobody guessed therefore stays
-- invisible - the abilities of a class added after the key list was written, for instance, which is
-- why "Rampage" (Hive Scum) had no official wording protecting it.
--
-- The manager's string cache points the other way: it is a memo of every string this session has
-- resolved, keyed by its loc key, so it contains key names no key list has. Reading it while the
-- player browses the talent tree or the menus is how those names are found. Only term-shaped values
-- are kept (one short line) and keys the key list already has are dropped, so what is written is a
-- list of NEW candidate keys, ready to be merged into translations/term_keys.lua and collected
-- properly for all twelve languages by the usual round.
--
-- Output: translations/export/cache_<language>.lua (same shape as the term export).
local CACHE_TERM_CHARS = 48   -- a value longer than this is a sentence, not a term

local function cache_path(lang)
    return util.MOD_DIR .. "/translations/export/cache_" .. tostring(lang) .. ".lua"
end

-- LuaJIT has no utf8 library and #s counts bytes, so count characters by UTF-8 lead bytes.
local function char_len(s)
    local n, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        i = i + ((b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1)
        n = n + 1
    end
    return n
end

local function known_key_set(list)
    local set = {}
    if type(list) == "table" and type(list.keys) == "table" then
        for _, key in ipairs(list.keys) do
            set[key] = true
        end
    end
    return set
end

-- Returns the number of new candidate keys written; 0 means there was nothing new to write.
function M.harvest_cache(mod, lang, list)
    local manager = Managers and Managers.localization
    local cache = (type(manager) == "table") and rawget(manager, "_string_cache") or nil
    if type(cache) ~= "table" then
        return 0
    end

    if not M._known_keys then
        M._known_keys = known_key_set(list or load_key_list())
    end

    local terms, count = {}, 0
    for key, text in pairs(cache) do
        if type(key) == "string" and type(text) == "string"
            and key:match("^loc_[%w_]+$") and not M._known_keys[key]
            and text ~= "" and text ~= key and text:sub(1, 1) ~= "<"
            and not text:find("\n", 1, true) and char_len(text) <= CACHE_TERM_CHARS
        then
            terms[key] = text
            count = count + 1
        end
    end

    -- The cache only grows, so an unchanged count means a previous look already wrote this.
    if count == 0 or count <= (M._harvested or 0) then
        return 0
    end
    M._harvested = count

    util.ensure_dir(util.MOD_DIR .. "/translations/export")
    if not util.write_file_atomic(cache_path(lang), serialize(lang, 1, terms)) then
        util.warn(mod, "cache harvest: could not write %s", cache_path(lang))
        return 0
    end

    util.info(mod, "cache harvest: %d candidate key(s) the key list does not have -> translations/export/cache_%s.lua",
        count, tostring(lang))
    return count
end

-- Tells the player how many languages are collected and which ones are still missing.
function M.notify_progress(mod)
    local _, missing, done, total = M.progress()
    local missing_text = (#missing > 0) and table.concat(missing, ", ") or mod:localize("term_export_all_done")
    notify(mod, "term_export_progress", done, total, missing_text)
end

return M
