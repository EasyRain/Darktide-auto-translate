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

-- Merge our translations into a localization table that DMF is about to register.
--
-- This is the important one: DMF loads each mod's resources in the order
-- localization -> data -> script, and the option texts are localized (and cached
-- as plain strings) while `data` is initialized. So the translation has to be
-- inside the table BEFORE DMF stores it — the on_all_mods_loaded path is too late
-- for option texts.
function M.merge(mod, name, loc_table)
    if type(name) ~= "string" or name == "" or name == "auto_translate" then
        return 0
    end
    if type(loc_table) ~= "table" then
        return 0
    end

    local data = store.load(name)
    if not data then
        return 0
    end
    if data.enabled == false then
        util.log(mod, "translation file for %s is disabled; skipped", name)
        return 0
    end

    local applied = 0
    local backfilled = 0

    for key, value in pairs(loc_table) do
        if type(value) == "table" and type(value["en"]) == "string" and value["en"] ~= "" then
            local existing = value["zh-cn"]
            if not (type(existing) == "string" and existing ~= "") then
                local hash = util.hash(value["en"])
                local zh, src, needs_backfill = store.lookup(data, key, value["en"], hash)
                if zh then
                    value["zh-cn"] = zh
                    applied = applied + 1
                    if needs_backfill then
                        store.set_entry(data, key, value["en"], hash, zh, src)
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
        util.info(mod, "merged %d key(s) into %s (backfilled %d)", applied, name, backfilled)
    else
        util.log(mod, "merge %s: nothing to apply", name)
    end
    return applied
end

-- Persist translation files that were enriched during merging.
function M.flush(mod)
    local saved = 0
    for name, data in pairs(dirty) do
        if data.manual_cleared then
            util.info(mod, "%s: machine translations were added, 'manual' flag cleared (add manual = true back to protect hand written text)", name)
            data.manual_cleared = nil
        end
        local ok = store.save(name, data)
        if ok then
            saved = saved + 1
        else
            util.warn(mod, "could not save translation file for %s", name)
        end
        dirty[name] = nil
    end
    return saved
end

-- Injects everything that is ready for this mod. Returns the number injected.
local function inject_mod(mod, dmf, entry)
    if not entry.tbl or #entry.ready == 0 then
        return 0
    end

    local injected = 0
    for _, item in ipairs(entry.ready) do
        local bucket = entry.tbl[item.key]
        if type(bucket) == "table" then
            bucket["zh-cn"] = item.zh
            injected = injected + 1
        end
    end

    if injected == 0 then
        return 0
    end

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

    return injected
end

function M.apply(mod, report)
    local dmf = get_mod("DMF")
    if not dmf then
        util.warn(mod, "DMF not found; nothing injected")
        return 0
    end

    local total = 0
    for _, entry in ipairs(report.mods) do
        local n = inject_mod(mod, dmf, entry)
        if n > 0 then
            total = total + n
            util.log(mod, "injected %d key(s) into %s", n, entry.name)
        end
    end

    util.info(mod, "injected %d translated key(s) across %d mod(s)", total, #report.mods)
    return total
end

return M
