-- auto_translate.lua — main entry point.
--
-- Pipeline on startup (and on demand):
--   1. scan every loaded mod's localization table (DMF's registry) for the target language
--   2. look up our local translation library (translations/<language>/<modid>.lua)
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

local glossary = mod:io_dofile(BASE .. "glossary")
glossary.init(util)

-- Language we translate INTO (configured, or the game's current language).
local function current_lang()
    return util.target_language(mod)
end

-- ---------------------------------------------------------------------------
-- Early hook: every mod loaded AFTER us passes through here.
--
-- DMF loads a mod's resources as localization -> data -> script, and localizes
-- the option titles/tooltips while initializing `data` (caching them as plain
-- strings). So we merge our translations into the table right before DMF stores
-- it — otherwise option texts would stay in the source language forever.
-- This is why auto_translate must be the FIRST entry in mod_load_order.txt.
-- ---------------------------------------------------------------------------
local hooked = false

local function install_hook()
    if hooked then
        return true
    end

    local dmf = get_mod("DMF")
    if not (dmf and type(dmf.hook) == "function") then
        util.warn(mod, "DMF hook API unavailable; early merge disabled")
        return false
    end

    local handler = function(next_func, target_mod, loc_table)
        local name
        if target_mod and target_mod.get_name then
            name = target_mod:get_name()
        end

        local ok, err = pcall(injector.merge, mod, name, loc_table, current_lang())
        if not ok then
            util.warn(mod, "merge error (%s): %s", tostring(name), tostring(err))
        end

        return next_func(target_mod, loc_table)
    end

    -- dmf:hook(obj, method, handler) is a colon method: use colon syntax so the
    -- implicit self (dmf) and obj (also dmf) are both passed correctly.
    local ok, err = pcall(function()
        dmf:hook(dmf, "initialize_mod_localization", handler)
    end)
    if not ok then
        util.warn(mod, "could not hook initialize_mod_localization: %s", tostring(err))
        return false
    end

    hooked = true
    util.info(mod, "early merge hook installed")
    return true
end

install_hook()

-- The online API engine needs a key. Warn the player and pause translation when it
-- is selected without one (the setting may be left empty otherwise).
local function check_engine_settings()
    -- tripped circuit breaker: stop hammering a failing service
    if engines.is_paused() then
        local _, _, reason = engines.failure_state()
        util.info(mod, "translation paused after repeated engine failures (last: %s)", tostring(reason))
        return false
    end

    if engines.resolve(mod) ~= "online_api" then
        return true
    end

    local key = mod:get("online_api_key")
    if type(key) == "string" and key ~= "" then
        return true
    end

    local message = mod:localize("api_key_missing")
    util.warn(mod, "engine 'online_api' is selected but no API key is set")
    if type(mod.notify) == "function" then
        pcall(mod.notify, mod, message)
    end
    if type(mod.echo) == "function" then
        pcall(mod.echo, mod, message)
    end
    return false
end

local function glossary_report(lang)
    local ok, err = glossary.load()
    if not ok then
        util.warn(mod, "glossary unavailable: %s", tostring(err))
        return
    end
    util.info(
        mod,
        "glossary: %d term(s) total, %d usable for '%s'",
        glossary.total(), glossary.count(lang), lang
    )
end

local function run_pipeline(reason)
    if not mod:get("apply_translation") then
        util.info(mod, "translations disabled by master switch (%s)", reason)
        return
    end

    local lang = current_lang()
    if lang == "en" then
        util.info(mod, "target language is English; installed mods are English already, nothing to do")
        return
    end

    glossary_report(lang)

    local report = scanner.scan(mod, lang)
    local st = report.stats

    if report.error then
        util.warn(mod, "scan failed: %s", report.error)
        return
    end

    util.info(
        mod,
        "scan (%s) [%s]: mods=%d keys=%d already=%d ready=%d pending=%d stale=%d skipped=%d",
        reason, lang, st.mods_total, st.keys_total, st.already, st.ready, st.pending, st.stale, st.skipped
    )

    injector.apply(mod, report, lang)

    local saved = injector.flush(mod, lang)
    if saved > 0 then
        util.info(mod, "saved %d translation file(s) with backfilled source hashes", saved)
    end

    if mod:get("auto_translate_enabled") then
        if check_engine_settings() then
            engines.run(mod, report, lang)
        else
            util.info(mod, "translation paused: the selected engine is not usable yet")
        end
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
    engines.reset(mod) -- give a paused engine another chance
    glossary.load(true)
    local ok, err = pcall(run_pipeline, "manual reload")
    if not ok then
        util.warn(mod, "reload error: %s", tostring(err))
    end
end

-- Mod options: "Clear local translations" (only the current target language)
function mod.clear_cache()
    local oslib = (Mods and Mods.lua and Mods.lua.os) or os
    local lang = current_lang()
    local report = scanner.scan(mod, lang)
    local removed = 0
    for _, entry in ipairs(report.mods) do
        local path = store.path_for(entry.name, lang)
        if util.file_exists(path) then
            pcall(oslib.remove, path)
            removed = removed + 1
        end
    end
    util.info(mod, "cleared %d translation file(s) for '%s'; they will be rebuilt on demand", removed, lang)
end

-- Mod options: "Test glossary" — shows what the term masking does.
function mod.test_glossary()
    local lang = current_lang()
    local sample = "Keystone: Blitz — Veteran, Ogryn, Psyker, Skitarii"
    local masked, tokens = glossary.mask(sample, lang)
    local restored, missing = glossary.unmask(masked, tokens)

    util.info(mod, "glossary test [%s]:", lang)
    util.info(mod, "  source  : %s", sample)
    util.info(mod, "  masked  : %s", masked)
    util.info(mod, "  restored: %s  (missing placeholders: %d)", restored, missing)
    if mod.echo then
        pcall(mod.echo, mod, string.format("[%s] %s", lang, restored))
    end
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "download_model_small" or setting_id == "download_model_large" then
        util.info(mod, "model download toggles are registered but the downloader is not implemented yet")
    elseif setting_id == "target_language" then
        util.info(mod, "target language set to: %s (press 'Reload translation files' to apply now)", tostring(mod:get("target_language")))
    elseif setting_id == "engine" or setting_id == "online_api_key" then
        if setting_id == "engine" then
            util.info(mod, "engine set to: %s", tostring(mod:get("engine")))
        else
            -- a new key deserves a fresh attempt after a failure streak
            engines.reset(mod)
        end
        check_engine_settings()
    elseif setting_id == "apply_translation" then
        util.info(mod, "master switch changed; use 'Reload translation files' to re-apply")
    end
end

util.log(mod, "framework loaded (v0.1.0)")
