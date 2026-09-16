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

-- Tells the player how many languages are collected and which ones are still missing.
function M.notify_progress(mod)
    local _, missing, done, total = M.progress()
    local missing_text = (#missing > 0) and table.concat(missing, ", ") or mod:localize("term_export_all_done")
    notify(mod, "term_export_progress", done, total, missing_text)
end

return M
