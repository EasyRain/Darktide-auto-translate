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

    local ok, err = pcall(dmf.initialize_mod_localization, dmf, target, entry.tbl)
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
