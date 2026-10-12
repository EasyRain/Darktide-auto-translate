-- injector.lua — merges our translations into a mod's localization table and
-- writes the merged table back into DMF's registry (in memory only; the mod's
-- own files are never touched).
local M = {}

local util
local store

function M.init(u, s)
    util = u
    store = s
end

-- store tables that gained bookkeeping fields (en/hash) and should be saved back
local dirty = {}

-- What we wrote into other mods' tables, so it can be taken back out again: DMF's toggle can be
-- flipped at runtime, and a mod that has been switched off should stop being translated.
-- name -> { [key] = { lang = ..., text = ... } }
local written = {}

local function remember(name, key, lang, text)
    local per_mod = written[name]
    if not per_mod then
        per_mod = {}
        written[name] = per_mod
    end
    per_mod[key] = { lang = lang, text = text }
end

-- The localization table each mod is actually being served from, keyed by mod id.
-- DMF stores the very table we merged into, and mod scripts read it on every
-- lookup, so writing into it later makes a new translation visible immediately —
-- no restart, and no full re-scan of every mod.
M.tables = {}

-- Puts one freshly translated key straight into the live table.
-- Returns true when it landed (false means the mod's table is not registered, e.g.
-- the mod loaded before us or has no localization).
function M.set_live(mod_id, key, lang, text)
    local tbl = M.tables[mod_id]
    if type(tbl) ~= "table" then
        return false
    end
    local bucket = tbl[key]
    if type(bucket) ~= "table" then
        return false
    end
    bucket[lang] = text
    -- Recorded as ours for the same reason merge() records what it writes: see M.is_ours.
    remember(mod_id, key, lang, text)
    return true
end

-- True when the text currently sitting in a mod's `value[lang]` was written by this mod *in this session*,
-- rather than shipped by the mod's own author.
--
-- The distinction matters when the player deletes a translation file to have another engine redo it: the
-- scanner reads the mod's localization table from disk, finds `value[lang]` already filled - with the previous
-- engine's text, injected earlier in this same session - and counts the key as "the mod already ships this
-- language", so the new engine never sees it and the old translation is written back into the fresh file. That
-- is the report that produced this function ("even after switching to DeepL the file still had Baidu's text").
--
-- Across a restart the table comes from the mod's own Lua again, so nothing here is needed then; within a
-- session this is the only record of what was ours.
function M.is_ours(name, key)
    local per_mod = written[name]
    return per_mod ~= nil and per_mod[key] ~= nil
end

-- Merge our translations into a localization table that DMF is about to register.
--
-- This is the important one: DMF loads each mod's resources in the order
-- localization -> data -> script, and the option texts are localized (and cached
-- as plain strings) while `data` is initialized. So the translation has to be
-- inside the table BEFORE DMF stores it — the on_all_mods_loaded path is too late
-- for option texts.
--
-- `remember_only` records the table without translating anything into it. The mod uses it while it is
-- switched off: this hook is the only moment DMF hands us a mod's localization table, and holding on to
-- it is what lets the translations be written in later without registering the file a second time -
-- which DMF answers with "(localization): overwritting already loaded localization file", one warning
-- per mod, shown to the player as a popup.
function M.merge(mod, name, loc_table, lang, remember_only)
    if type(name) ~= "string" or name == "" or name == "auto_translate" then
        return 0
    end
    if type(loc_table) ~= "table" then
        return 0
    end

    -- Remember it before any early return: on a first run most mods have no
    -- translation file at all, and those are exactly the ones that need live
    -- updates as the engine produces text for them.
    M.tables[name] = loc_table

    if remember_only then
        return 0
    end

    local data = store.load(name, lang)
    if not data then
        -- No translation file for this mod and language: nothing to apply, and nothing is cleared either.
        -- A deleted file is how a player asks for *this* mod to be redone (possibly with another engine), and
        -- the rebuilding happens by itself - the keys simply have no entry, so the next scan calls them pending.
        -- What must NOT happen is any effect on the other mods: switching the engine redoes nothing on its own,
        -- and the text already on screen stays until its replacement arrives.
        return 0
    end

    local applied = 0
    local backfilled = 0

    for key, value in pairs(loc_table) do
        if type(value) == "table" and type(value["en"]) == "string" and value["en"] ~= "" then
            local existing = value[lang]
            -- A value that is already filled stays untouched - unless this mod put it there itself. That is
            -- the "delete the file, switch engine, reload" path: our own text from earlier in the session must
            -- not stop the store's (new engine's) text from taking its place. See M.is_ours.
            local ours = M.is_ours(name, key)
            if not (type(existing) == "string" and existing ~= "") or ours then
                local hash = util.hash(value["en"])
                local text, src, needs_backfill = store.lookup(data, key, value["en"], hash)
                if text then
                    value[lang] = text
                    remember(name, key, lang, text)
                    applied = applied + 1
                    if needs_backfill then
                        store.set_entry(data, key, value["en"], hash, text, src)
                        backfilled = backfilled + 1
                    end
                end
            end
        end
    end

    if backfilled > 0 then
        dirty[name] = data
    end

    if applied > 0 then
        util.info(mod, "merged %d key(s) into %s [%s] (backfilled %d)", applied, name, lang, backfilled)
    else
        util.log(mod, "merge %s [%s]: nothing to apply", name, lang)
    end
    return applied
end

-- Persist translation files that were enriched during merging.
function M.flush(mod, lang)
    local saved = 0
    for name, data in pairs(dirty) do
        local ok = store.save(name, lang, data)
        if ok then
            saved = saved + 1
        else
            util.warn(mod, "could not save translation file for %s [%s]", name, lang)
        end
        dirty[name] = nil
    end
    return saved
end

-- Injects everything that is ready for this mod. Returns the number injected.
local function inject_mod(mod, dmf, entry, lang)
    if #entry.ready == 0 then
        return 0
    end

    -- Write into the table DMF is actually serving, when we have it.
    --
    -- M.tables[name] is the table our load hook merged into, and DMF keeps that
    -- reference rather than a copy, so writing into it takes effect immediately.
    -- entry.tbl is a SEPARATE table: the scanner loaded the file from disk again.
    -- Handing that one to DMF replaces the registered table, which (a) makes DMF
    -- log "(localization): overwritting already loaded localization file" as a
    -- warning popup and (b) silently breaks set_live() afterwards, because live
    -- updates write into the table DMF no longer uses.
    local live = M.tables[entry.name]
    local tbl = live or entry.tbl
    if type(tbl) ~= "table" then
        return 0
    end

    local injected = 0
    for _, item in ipairs(entry.ready) do
        local bucket = tbl[item.key]
        if type(bucket) == "table" then
            bucket[lang] = item.text
            remember(entry.name, item.key, lang, item.text)
            injected = injected + 1
        end
    end

    if injected == 0 then
        return 0
    end

    if live then
        -- Already registered during load; nothing to hand over.
        return injected
    end

    -- No table of ours (the mod loaded before us, or has no localization we saw),
    -- so this copy does need registering.
    local target = (dmf.mods and dmf.mods[entry.name]) or get_mod(entry.name)
    if not target then
        return 0
    end

    -- NOTE: dmf.initialize_mod_localization is a plain function field defined as
    -- function (mod, localization_table) — no self, so pass exactly two arguments.
    local ok, err = pcall(dmf.initialize_mod_localization, target, entry.tbl)
    if not ok then
        util.warn(mod, "inject failed for %s: %s", entry.name, tostring(err))
        return 0
    end

    -- Remember it, so later live updates write into the table DMF now holds.
    M.tables[entry.name] = entry.tbl

    return injected
end

function M.apply(mod, report, lang)
    local dmf = get_mod("DMF")
    if not dmf then
        util.warn(mod, "DMF not found; nothing injected")
        return 0
    end

    local total = 0
    for _, entry in ipairs(report.mods) do
        local n = inject_mod(mod, dmf, entry, lang)
        if n > 0 then
            total = total + n
            util.log(mod, "injected %d key(s) into %s [%s]", n, entry.name, lang)
        end
    end

    util.info(mod, "injected %d translated key(s) across %d mod(s) [%s]", total, #report.mods, lang)
    return total
end

-- Takes back everything this mod wrote into other mods' localization tables.
--
-- Only entries whose value is still exactly the text we put there are removed: if the mod itself (or
-- a later translation) replaced it, that text is not ours to delete. Called when DMF's toggle is
-- switched off, so a mod that is disabled stops being translated without needing a restart.
function M.unapply(mod)
    local removed, kept = 0, 0
    for name, per_mod in pairs(written) do
        local tbl = M.tables[name]
        if type(tbl) == "table" then
            for key, item in pairs(per_mod) do
                local bucket = tbl[key]
                if type(bucket) == "table" and bucket[item.lang] == item.text then
                    bucket[item.lang] = nil
                    removed = removed + 1
                else
                    kept = kept + 1
                end
            end
        end
        written[name] = nil
    end
    if mod then
        util.info(mod, "took back %d injected key(s); %d had already been replaced", removed, kept)
    end
    return removed, kept
end

return M
