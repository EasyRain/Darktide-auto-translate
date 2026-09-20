-- store.lua — the local translation library.
--
-- One file per translated mod **and target language**, at:
--     ../mods/auto_translate/translations/<language>/<modid>.lua
-- e.g. translations/zh-cn/ability_timer.lua, translations/ja/ability_timer.lua
--
-- Format (hand editable on purpose). The same explanation is written into every file's header, in
-- full, because the file is what a player hands to an editor - or to an AI - and the one field that
-- looks like a setting but is not is `src`:
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
-- file has been hand checked", drops the `src` line from all of them (whatever it says - an engine
-- name, or "manual" as an outside editor writes it), writes the file back and puts the flag to
-- false again - so nobody has to delete the markers by hand. From then on
-- the marker is what tells the two apart:
--     no `src`   hand written: a machine translation never overwrites it while its source matches
--     `src = X`  written by engine X, and it is the entry's history (the engine re-writes it when
--                the mod's source text changes, which is also how a hand written entry becomes a
--                machine one again: it goes stale, gets re-translated and comes back with a marker)
-- `text_prev` keeps an out of date hand written translation (with `text_prev_src` saying where it
-- came from) when the mod's source text changed under it.
--
-- An outside editor that writes `src = "manual"` on every entry is a real case (it happened on the
-- first file a player sent to an AI): those entries are treated as hand written either way, but the
-- file then no longer says which lines a machine wrote, which is the whole point of the field. The
-- file header therefore documents `src` as bookkeeping and asks an AI editor to leave it alone.
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

-- Does this entry carry text at all?
local function entry_has_text(entry)
    return type(entry) == "table" and type(entry.text) == "string" and entry.text ~= ""
end

-- Is this entry hand written, ignoring the file level flag? One rule, used by the two things that
-- ask the question - is_manual() when a translation comes back, and drop_machine_entries() when the
-- player asks for the machine work to be thrown away - so "Clear machine translations" can never
-- delete what is_manual() calls the player's.
local function entry_is_manual(entry)
    if type(entry) ~= "table" then
        return false
    end
    if entry.src == "manual" then
        return true
    end
    return (entry.src == nil or entry.src == "") and entry_has_text(entry)
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
    return entry_is_manual(entry)
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
-- markers go. Returns how many were removed.
--
-- Any value counts, not just a real engine: a file that came back from an outside calibration pass
-- (an AI, an editor) carries `src = "manual"`, and an editor that wrote `src = ""` is no different.
-- The state the header documents for a hand written entry is *no* src line, so leaving "manual"
-- behind made the instruction look like it had done nothing - reported by a player whose file still
-- had all 80 markers after flipping the flag.
local function strip_markers(data)
    local stripped = 0
    for _, entry in pairs(data.entries) do
        if type(entry) == "table" and type(entry.src) == "string" and entry.src ~= "" then
            entry.src = nil
            entry.text_prev_src = nil
            stripped = stripped + 1
        end
    end
    return stripped
end

-- Told about a store whose `manual = true` instruction was carried out (see load). Set by the mod so
-- the player hears about it from whichever caller happened to read the file first.
local notifier = nil
function M.set_notifier(fn)
    notifier = fn
end

-- The comment block every file starts with. It is built here rather than inline in serialize() so
-- that a file written by an older version can be compared against it and brought up to date (see
-- refresh_header): the explanation is the part a player reads - and hands to an AI - and a stale one
-- is worse than none. Changing the prose is therefore enough; there is no version number to forget.
local HEADER_MARK = "-- Auto Translate translations for mod:"

local function header_lines(mod_id, lang)
    return {
        HEADER_MARK .. " " .. tostring(mod_id) .. "  (language: " .. tostring(lang) .. ")",
        "--",
        "-- This file is the mod's translation memory: one entry per string the mod translates, for one",
        "-- mod and one language. It is plain Lua on purpose, so it can be edited by hand; the mod also",
        "-- writes it back whenever it translates something new, so keep the shape and edit the entries.",
        "--",
        "--   enabled = false   skip this mod completely (none of it gets translated)",
        "--   manual  = true    \"I have hand checked this file\". On the next start the mod removes the",
        "--                     src line from every entry, writes the file back, and sets the flag to",
        "--                     false again. One shot: set it, start the game, done.",
        "--",
        "-- The fields of an entry:",
        "--",
        "--   en     the source text (English). The mod finds an entry by key *and* compares this text,",
        "--          so changing it detaches the entry from the game's string - it then counts as \"the",
        "--          source changed\" and is translated again.",
        "--   hash   a fingerprint of en. Same meaning as en, cheap to keep.",
        "--   text   the translation the game shows. This is the field to edit.",
        "--   src    bookkeeping: the name of the engine that wrote text (deepl, local_base, bing, ...).",
        "--          An entry with NO src line is hand written, and hand written text is never",
        "--          overwritten while en is unchanged. src is not a setting: writing it on every entry",
        "--          marks nothing as hand written, it only throws away the record of which lines a",
        "--          machine wrote. Leave it alone (or use the flag above).",
        "--   ts     when the entry was last written, unix time. Informational.",
        "--",
        "-- If this file is handed to an AI to improve the translations: edit `text` only, and keep",
        "-- Warhammer 40,000: Darktide's official terminology exactly as the game shows it - the game's",
        "-- own words for weapons, talents, abilities, enemies, places. Never replace a game term with a",
        "-- generic synonym, never translate a proper noun the game leaves in English, and leave `en`,",
        "-- `hash`, `src` and `ts` as they are.",
    }
end

-- The text of that block, ending exactly where the table begins.
local function header_text(mod_id, lang)
    return table.concat(header_lines(mod_id, lang), "\n") .. "\n"
end

-- Brings the comment block of a file up to date. Returns true when the file was rewritten.
--
-- Two shapes have to end the same way - the file carries today's explanation - and neither may touch
-- a single byte the player wrote:
--
--   * an older header of ours: the block above `return {` is ours by definition, so it is replaced,
--     and everything from `return {` on is written back byte for byte (a note inside an entry, a
--     different order, whatever an external editor left there);
--   * no header at all - an editor or an AI that "cleaned up the comments" - : ours is *prepended*,
--     so the player's own note at the top survives underneath it.
--
-- The file has already parsed by the time this runs, so prepending comments is always safe.
local function refresh_header(mod_id, lang, path)
    local raw = util.read_file(path)
    if type(raw) ~= "string" or raw == "" then
        return false
    end
    local header = header_text(mod_id, lang)
    if raw:sub(1, #header) == header then
        return false                                   -- already current
    end
    if raw:sub(1, #HEADER_MARK) ~= HEADER_MARK then
        return util.write_file_atomic(path, header .. raw) and true or false
    end
    local body_at = raw:find("\nreturn {", 1, true)
    if not body_at then
        return false
    end
    return util.write_file_atomic(path, header .. raw:sub(body_at + 1)) and true or false
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
    local wrote = false
    if data.manual == true then
        local stripped = strip_markers(data)
        data.manual = false
        data.manual_stripped = stripped
        -- Written back even when there was no marker to remove: the flag itself has to reach the
        -- file. Skipping the write when nothing was stripped left `manual = true` in a file that
        -- had already been cleaned by hand, so the instruction stayed armed for the next start -
        -- and then stripped the marker off whatever the engine wrote in between.
        M.save(mod_id, lang, data)
        wrote = true
        if stripped > 0 and notifier then
            pcall(notifier, mod_id, lang, stripped)
        end
    end

    -- A file an older version wrote keeps that version's explanation until something rewrites it, and
    -- a file an editor or an AI stripped the comments from has none at all. Both get today's - "the
    -- player reads this, and hands it to an AI" is exactly why it has to be there. Skipped when the
    -- instruction above already wrote the file, which writes the header too.
    if not wrote then
        data.header_refreshed = refresh_header(mod_id, lang, path) or nil
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

    local out = header_lines(mod_id, lang)
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

-- Throws away everything an engine wrote and keeps the hand written entries. Returns how many
-- entries were dropped and how many were kept; the caller decides what to do with a file whose kept
-- count is zero (the mod's "Clear machine translations" button removes it).
--
-- This exists because "clear the translations" must not be the one path in the mod that destroys a
-- player's own text: everywhere else a hand written entry is protected (set_entry), and the button's
-- job is to have the *machine* work redone. The rule is exactly the one set_entry uses, so an entry
-- an outside editor marked `src = "manual"` counts as hand written here too. A parked key (a refusal
-- record) has no text and no marker, and it *is* machine bookkeeping - it goes, or a cleared key
-- would stay parked for the engine that gave up on it.
--
-- An entry that an engine rewrote keeps its old hand written text in `text_prev`, and that goes with
-- the machine entry: the entry as a whole is the engine's now, and restoring a translation for a
-- source text it no longer matches would be worse.
function M.drop_machine_entries(data)
    if type(data) ~= "table" or type(data.entries) ~= "table" then
        return 0, 0
    end
    local removed, kept = 0, 0
    for key, entry in pairs(data.entries) do
        if entry_is_manual(entry) and entry_has_text(entry) then
            kept = kept + 1
        else
            data.entries[key] = nil
            removed = removed + 1
        end
    end
    return removed, kept
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
