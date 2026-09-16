-- store.lua — the local translation library.
--
-- One file per translated mod **and target language**, at:
--     ../mods/auto_translate/translations/<language>/<modid>.lua
-- e.g. translations/zh-cn/ability_timer.lua, translations/ja/ability_timer.lua
--
-- Format (hand editable on purpose):
--     return {
--         enabled = false,         -- false = skip this mod completely (always written, so it is
--         manual  = false,         -- one word to flip: true = "I have hand checked this file")
--         entries = {
--             ["some_key"] = { text = "译文" },                              -- hand written
--             ["other"]    = { en = "...", hash = "1a2b3c4d", text = "...", src = "deepl", ts = 0 },
--         },
--     }
--
-- `manual = true` is an instruction, not a state: on load the mod reads it as "every entry in this
-- file has been hand checked", drops the engine marker (`src`) from all of them, writes the file
-- back and puts the flag to false again - so nobody has to delete the markers by hand. From then on
-- the marker is what tells the two apart:
--     no `src`   hand written: a machine translation never overwrites it while its source matches
--     `src = X`  written by engine X, and it is the entry's history (the engine re-writes it when
--                the mod's source text changes, which is also how a hand written entry becomes a
--                machine one again: it goes stale, gets re-translated and comes back with a marker)
-- `text_prev` keeps an out of date hand written translation (with `text_prev_src` saying where it
-- came from) when the mod's source text changed under it.
local M = {}

local util
function M.init(u)
    util = u
end

function M.dir_for(lang)
    return util.TRANSLATIONS_DIR .. "/" .. tostring(lang or "en")
end

function M.path_for(mod_id, lang)
    return M.dir_for(lang) .. "/" .. tostring(mod_id) .. ".lua"
end

local function normalize(data)
    if type(data) ~= "table" then
        data = {}
    end
    if type(data.entries) ~= "table" then
        data.entries = {}
    end
    if data.enabled == nil then
        data.enabled = true
    end
    if data.manual == nil then
        data.manual = false
    end
    return data
end

-- Is this entry protected from machine translation?
--
-- No marker at all means hand written: that is the format the file header documents (`{ text = "…" }`),
-- and it is what every entry looks like after `manual = true` has been carried out. The entry has to
-- carry text for that to hold: a parked key (an engine's refusal record) has neither text nor marker,
-- and treating it as hand written would block the translation that ends its refusal story.
local function is_manual(data, entry)
    if data and data.manual == true then
        return true
    end
    if type(entry) ~= "table" then
        return false
    end
    if entry.src == "manual" then
        return true
    end
    return (entry.src == nil or entry.src == "")
        and type(entry.text) == "string" and entry.text ~= ""
end

-- Returns true when the entry carries a machine marker (the value to write back to the file).
local function machine_src(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local src = entry.src
    if type(src) == "string" and src ~= "" and src ~= "manual" then
        return src
    end
    return nil
end

-- Carries out a `manual = true` instruction: every entry in the file has been hand checked, so the
-- engine markers go. Returns how many were removed (0 = nothing to do, no write needed).
local function strip_markers(data)
    local stripped = 0
    for _, entry in pairs(data.entries) do
        if type(entry) == "table" and machine_src(entry) then
            entry.src = nil
            entry.text_prev_src = nil
            stripped = stripped + 1
        end
    end
    return stripped
end

function M.load(mod_id, lang)
    local path = M.path_for(mod_id, lang)
    if not util.file_exists(path) then
        return nil
    end
    local data, err = util.load_lua_file(path)
    if not data then
        return nil, err
    end
    data = normalize(data)

    -- The hand-checking instruction is carried out here rather than at the next save, so the file
    -- the player opens is already free of markers, and the flag goes back to false: leaving it set
    -- would strip the marker off every entry the engine re-writes later, which is exactly the
    -- distinction this is for.
    if data.manual == true then
        local stripped = strip_markers(data)
        data.manual = false
        data.manual_stripped = stripped
        if stripped > 0 then
            M.save(mod_id, lang, data)
        end
    end
    return data
end

local function lua_quote(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "")
    return "\"" .. s .. "\""
end

-- Serializes a store table back to Lua source (stable ordering, human editable).
function M.serialize(mod_id, lang, data)
    data = normalize(data)

    local out = {}
    out[#out + 1] = "-- Auto Translate translations for mod: " .. tostring(mod_id) .. "  (language: " .. tostring(lang) .. ")"
    out[#out + 1] = "-- enabled = false : skip this mod completely"
    out[#out + 1] = "-- manual  = true  : \"I have hand checked this file\": the engine markers below are"
    out[#out + 1] = "--                   removed on the next start and the flag goes back to false."
    out[#out + 1] = "-- An entry without a 'src' line is hand written (and never overwritten while its source"
    out[#out + 1] = "-- text is unchanged); one with 'src' was written by that engine. Both flags are always"
    out[#out + 1] = "-- written out, so there is one word to flip."
    out[#out + 1] = "return {"
    out[#out + 1] = string.format("    enabled = %s,", tostring(data.enabled == true))
    out[#out + 1] = string.format("    manual = %s,", tostring(data.manual == true))
    out[#out + 1] = "    entries = {"

    local keys = {}
    for k in pairs(data.entries) do
        keys[#keys + 1] = k
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local e = data.entries[k]
        if type(e) == "table" and type(e.text) == "string" and e.text ~= "" then
            out[#out + 1] = "        [" .. lua_quote(k) .. "] = {"
            if type(e.en) == "string" and e.en ~= "" then
                out[#out + 1] = "            en = " .. lua_quote(e.en) .. ","
            end
            if type(e.hash) == "string" and e.hash ~= "" then
                out[#out + 1] = "            hash = " .. lua_quote(e.hash) .. ","
            end
            out[#out + 1] = "            text = " .. lua_quote(e.text) .. ","
            if type(e.text_prev) == "string" and e.text_prev ~= "" then
                out[#out + 1] = "            text_prev = " .. lua_quote(e.text_prev) .. ", -- previous hand translation (source changed)"
            end
            -- Only a real machine marker is written: an entry that has none is hand written, and
            -- inventing `src = "local"` for it (which this used to do) made the two indistinguishable.
            local src = machine_src(e)
            if src then
                out[#out + 1] = "            src = " .. lua_quote(src) .. ","
            end
            if tonumber(e.ts) and tonumber(e.ts) > 0 then
                out[#out + 1] = "            ts = " .. tostring(math.floor(e.ts)) .. ","
            end
            out[#out + 1] = "        },"
        elseif type(e) == "table" and type(e.refused_by) == "string" and e.refused_by ~= "" then
            -- A key an engine gave up on: no text, but the refusal count has to survive
            -- the run or every launch would try the same strings again.
            out[#out + 1] = "        [" .. lua_quote(k) .. "] = {"
            if type(e.en) == "string" and e.en ~= "" then
                out[#out + 1] = "            en = " .. lua_quote(e.en) .. ","
            end
            if type(e.hash) == "string" and e.hash ~= "" then
                out[#out + 1] = "            hash = " .. lua_quote(e.hash) .. ","
            end
            out[#out + 1] = "            refused_by = " .. lua_quote(e.refused_by) .. ","
            out[#out + 1] = "            refusals = " .. tostring(math.floor(tonumber(e.refusals) or 0)) .. ","
            if tonumber(e.ts) and tonumber(e.ts) > 0 then
                out[#out + 1] = "            ts = " .. tostring(math.floor(e.ts)) .. ","
            end
            out[#out + 1] = "        },"
        end
    end

    out[#out + 1] = "    },"
    out[#out + 1] = "}"
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

function M.save(mod_id, lang, data)
    util.ensure_dir(M.dir_for(lang))
    local path = M.path_for(mod_id, lang)
    return util.write_file_atomic(path, M.serialize(mod_id, lang, data))
end

-- Returns the usable translation for a source text, or nil.
-- A manual entry always wins; a machine entry is dropped when the source changed.
-- Third return value is true when the entry lacks bookkeeping (en/hash) and the
-- caller should backfill it on the next save.
function M.lookup(data, key, en, hash)
    if type(data) ~= "table" or type(data.entries) ~= "table" then
        return nil
    end
    local e = data.entries[key]
    if type(e) ~= "table" or type(e.text) ~= "string" or e.text == "" then
        return nil
    end

    -- No marker means hand written (see the file header): that is how the engine tells its own work
    -- from the player's, and it is what keeps a hand written entry from being overwritten.
    local src = e.src
    if src == nil or src == "" then
        src = "manual"
    end

    if e.hash == nil or e.hash == "" then
        return e.text, src, true
    end
    if e.hash ~= hash then
        return nil, "source changed"
    end
    return e.text, src
end

local function now()
    local oslib = (Mods and Mods.lua and Mods.lua.os) or os
    return (oslib and oslib.time and oslib.time()) or 0
end

-- Adds or updates an entry.
--
-- Manual entries are protected while they still match the source text. When the
-- source hash changed the hand written text is out of date, so the new translation
-- is accepted and the old one is kept in `text_prev`. Missing bookkeeping is always
-- filled in.
--
-- The file level `manual` flag is deliberately left alone here: it is the player's instruction
-- ("I have hand checked this file") and store.load is what carries it out. Clearing it on the first
-- machine write is how an instruction set while the game runs used to be dropped silently.
function M.set_entry(data, key, en, hash, text, src, ts)
    data = normalize(data)
    local prev = data.entries[key]

    if type(prev) == "table" then
        local protected = is_manual(data, prev)
        local stale = type(prev.hash) == "string" and prev.hash ~= "" and prev.hash ~= hash

        if protected and not stale then
            if (prev.en == nil or prev.en == "") and en then
                prev.en = en
            end
            if (prev.hash == nil or prev.hash == "") and hash then
                prev.hash = hash
            end
            return true
        end

        if protected and stale then
            prev.text_prev = prev.text
            prev.text_prev_src = prev.src or "manual"
        end

        prev.en = en
        prev.hash = hash
        prev.text = text
        prev.src = src or prev.src or "local"
        prev.ts = ts or now()
        -- A stored translation ends the key's history as a failure: whatever engine gave
        -- up on it before, this text is what the player sees now.
        prev.refused_by = nil
        prev.refusals = nil
        return true
    end

    data.entries[key] = {
        en = en,
        hash = hash,
        text = text,
        src = src or "local",
        ts = ts or now(),
    }
    return true
end

function M.count(data)
    local n = 0
    if type(data) == "table" and type(data.entries) == "table" then
        for _, e in pairs(data.entries) do
            if type(e) == "table" and type(e.text) == "string" and e.text ~= "" then
                n = n + 1
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Keys an engine gave up on
--
-- A refusal is a content problem: the model cannot translate this string, and asking
-- again does not help. Retrying it on every run forever wastes the only thing the queue
-- has (time) and keeps the "refused" counter meaningless. So the count is written to the
-- file: after the third refusal the key is *parked* for that engine, and it is picked up
-- again by any other engine - which is what makes switching to the API redo the work
-- instead of silently keeping the old result.
--
-- The marker lives on an entry with no `text`, so lookup() keeps treating the key as
-- untranslated; only the scanner reads the marker, and only to decide "pending" versus
-- "parked for the engine in use".
-- ---------------------------------------------------------------------------

-- Records one refusal of `key` by `engine` and returns the total for that engine.
-- The count restarts when a different engine refuses the same key.
function M.note_refusal(data, key, en, hash, engine)
    data = normalize(data)
    if type(key) ~= "string" or key == "" or type(engine) ~= "string" or engine == "" then
        return 0
    end

    local entry = data.entries[key]
    if type(entry) ~= "table" then
        entry = {}
        data.entries[key] = entry
    end

    if entry.refused_by ~= engine then
        entry.refused_by = engine
        entry.refusals = 0
    end
    entry.refusals = (tonumber(entry.refusals) or 0) + 1
    entry.en = en or entry.en
    entry.hash = hash or entry.hash
    entry.ts = now()
    return entry.refusals
end

-- The engine that gave up on this key, or nil. Only reported while the entry has no
-- usable translation and the source text is unchanged: a changed source deserves a fresh
-- attempt, and a stored translation is not a failure any more.
function M.parked_for(data, key, hash)
    if type(data) ~= "table" or type(data.entries) ~= "table" then
        return nil
    end
    local e = data.entries[key]
    if type(e) ~= "table" then
        return nil
    end
    if type(e.text) == "string" and e.text ~= "" then
        return nil
    end
    if type(e.hash) == "string" and e.hash ~= "" and e.hash ~= hash then
        return nil
    end
    if type(e.refused_by) == "string" and e.refused_by ~= "" then
        return e.refused_by, tonumber(e.refusals) or 0
    end
    return nil
end

return M
