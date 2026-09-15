-- auto_translate.lua — main entry point.
--
-- Pipeline on startup (and on demand):
--   1. scan every loaded mod's localization table (DMF's registry)
--   2. look up our local translation library
--   3. inject the merged table back into DMF (in memory — original mod files untouched)
--   4. hand the remaining keys to the selected translation engine (later step)
local mod = get_mod("auto_translate")

local BASE = "auto_translate/scripts/mods/auto_translate/modules/"
local util = mod:io_dofile(BASE .. "util")

local store = mod:io_dofile(BASE .. "store")
store.init(util)

local scanner = mod:io_dofile(BASE .. "scanner")
scanner.init(util, store)

local injector = mod:io_dofile(BASE .. "injector")
injector.init(util, store)

local engines = mod:io_dofile(BASE .. "engines")
engines.init(util, store)

local function run_pipeline(reason)
    if not mod:get("apply_translation") then
        util.info(mod, "translations disabled by master switch (%s)", reason)
        return
    end

    local report = scanner.scan(mod)
    local st = report.stats

    if report.error then
        util.warn(mod, "scan failed: %s", report.error)
        return
    end

    util.info(
        mod,
        "scan (%s): mods=%d keys=%d already=%d ready=%d pending=%d skipped=%d",
        reason, st.mods_total, st.keys_total, st.already, st.ready, st.pending, st.skipped
    )

    injector.apply(mod, report)

    if mod:get("auto_translate_enabled") then
        engines.run(mod, report)
    else
        util.info(mod, "auto translation paused by setting; %d key(s) left pending", st.pending)
    end
end

-- DMF calls this once every mod has finished loading (localization registry ready).
function mod.on_all_mods_loaded()
    local ok, err = pcall(run_pipeline, "startup")
    if not ok then
        util.warn(mod, "startup pipeline error: %s", tostring(err))
    end
end

-- Mod options: "Reload translation files"
function mod.reload_translations()
    local ok, err = pcall(run_pipeline, "manual reload")
    if not ok then
        util.warn(mod, "reload error: %s", tostring(err))
    end
end

-- Mod options: "Clear local translations"
function mod.clear_cache()
    local oslib = (Mods and Mods.lua and Mods.lua.os) or os
    local report = scanner.scan(mod)
    local removed = 0
    for _, entry in ipairs(report.mods) do
        local path = store.path_for(entry.name)
        if util.file_exists(path) then
            pcall(oslib.remove, path)
            removed = removed + 1
        end
    end
    util.info(mod, "cleared %d translation file(s); they will be rebuilt on demand", removed)
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "download_model_small" or setting_id == "download_model_large" then
        util.info(mod, "model download toggles are registered but the downloader is not implemented yet")
    elseif setting_id == "engine" then
        util.info(mod, "engine set to: %s", tostring(mod:get("engine")))
    elseif setting_id == "apply_translation" then
        util.info(mod, "master switch changed; use 'Reload translation files' to re-apply")
    end
end

util.log(mod, "framework loaded (v0.1.0)")
