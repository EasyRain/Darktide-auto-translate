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

local online = mod:io_dofile(BASE .. "online")
online.init(util, store, glossary, engines, injector)

local exporter = mod:io_dofile(BASE .. "exporter")
exporter.init(util)

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

-- Pauses translation and tells the player when the selected engine is not usable
-- yet: tripped circuit breaker, missing local model, or missing API key.
local function check_engine_settings(lang)
    -- tripped circuit breaker: stop hammering a failing service
    if engines.is_paused() then
        local _, _, reason = engines.failure_state()
        util.info(mod, "translation paused after repeated engine failures (last: %s)", tostring(reason))
        return false
    end

    local engine = engines.resolve(mod, lang)

    -- Nothing configured at all: no downloaded model and no API key.
    if engine == nil then
        util.warn(mod, "no translation engine is available (no model downloaded, no API key set)")
        local message = mod:localize("no_engine_available")
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, message)
        end
        if type(mod.echo) == "function" then
            pcall(mod.echo, mod, message)
        end
        return false
    end

    -- local model selected but its files are not downloaded yet
    if engines.is_local_engine(engine) and not engines.model_available(engine) then
        util.warn(mod, "engine '%s' is selected but its model is not downloaded", engine)
        local message = mod:localize("model_missing")
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, message)
        end
        if type(mod.echo) == "function" then
            pcall(mod.echo, mod, message)
        end
        return false
    end

    -- The engine has no provider that can produce this language. Storing the
    -- wrong script would be worse than storing nothing, so refuse and say why.
    local gap = engines.gap(engine, lang)
    if gap then
        util.warn(mod, "engine '%s' cannot produce '%s' (would return '%s'); nothing will be saved", engine, tostring(lang), tostring(gap.actual))
        local message = mod:localize("engine_language_gap", engine, tostring(gap.actual), tostring(lang), tostring(gap.actual))
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, message)
        end
        if type(mod.echo) == "function" then
            pcall(mod.echo, mod, message)
        end
        return false
    end

    if engine ~= "online_api" then
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

    -- The total alone does not say whether a run will take a minute or an hour, so
    -- name the mods the work actually sits in.
    local waiting = {}
    for _, entry in ipairs(report.mods) do
        if #entry.pending > 0 then
            waiting[#waiting + 1] = { name = entry.name, n = #entry.pending }
        end
    end
    table.sort(waiting, function(a, b)
        return a.n > b.n
    end)

    if #waiting > 0 then
        local parts = {}
        for i = 1, math.min(#waiting, 12) do
            parts[#parts + 1] = string.format("%s=%d", waiting[i].name, waiting[i].n)
        end
        util.info(mod, "pending by mod (%d mod(s)): %s%s",
            #waiting, table.concat(parts, ", "),
            #waiting > 12 and string.format(", ... and %d more", #waiting - 12) or "")
    end

    injector.apply(mod, report, lang)

    local saved = injector.flush(mod, lang)
    if saved > 0 then
        util.info(mod, "saved %d translation file(s) with backfilled source hashes", saved)
    end

    if mod:get("auto_translate_enabled") then
        if check_engine_settings(lang) then
            local engine = engines.resolve(mod, lang)
            if engines.is_local_engine(engine) then
                -- the local model path is still a stub; it reports what it would do
                engines.run(mod, report, lang)
            elseif not online.start(mod, report, lang) then
                util.info(mod, "online translation was not started (see the warnings above)")
            end
        else
            util.info(mod, "translation paused: the selected engine is not usable yet")
        end
    else
        util.info(mod, "auto translation paused by setting; %d key(s) left pending", st.pending)
    end
end

-- Per-frame driver for the translation queue (one request in flight at a time).
-- DMF calls this every frame once the mod is loaded.
local injected_upto = 0

local function reinject_finished()
    local lang = current_lang()
    local report = scanner.scan(mod, lang)
    if report.error then
        return
    end
    injector.apply(mod, report, lang)
    injector.flush(mod, lang)
    util.info(mod, "re-injected %d newly translated key(s); no restart needed", report.stats.ready)
end

function mod.update(dt)
    local ok, err = pcall(online.update, mod, dt)
    if not ok then
        util.warn(mod, "online update error: %s", tostring(err))
        return
    end

    -- Newly translated keys only reach the game once the merged table is pushed
    -- back into DMF again, so do that when the queue drains.
    local status = online.status()
    if status.finished and status.done > injected_upto then
        injected_upto = status.done
        local iok, ierr = pcall(reinject_finished)
        if not iok then
            util.warn(mod, "could not re-inject finished translations: %s", tostring(ierr))
        end
    end
end

-- DMF calls this once every mod has finished loading (localization registry ready).
function mod.on_all_mods_loaded()
    local ok, err = pcall(run_pipeline, "startup")
    if not ok then
        util.warn(mod, "startup pipeline error: %s", tostring(err))
    end

    -- Collect the current language's official terminology (independent of the
    -- translation switches: it only writes a file, so it is always safe).
    local eok, eerr = pcall(exporter.run, mod, current_lang())
    if not eok then
        util.warn(mod, "term export failed: %s", tostring(eerr))
    end
end

-- Mod options: "Reload translation files"
function mod.reload_translations()
    -- keep whatever has already been translated before tearing the queue down
    local flushed = online.flush(mod)
    online.stop(mod)
    engines.reset(mod) -- give a paused engine another chance
    glossary.load(true)
    if flushed > 0 then
        util.info(mod, "saved %d translation file(s) before reloading", flushed)
    end
    local ok, err = pcall(run_pipeline, "manual reload")
    if not ok then
        util.warn(mod, "reload error: %s", tostring(err))
    end
end

-- Mod options: "Clear local translations" (only the current target language)
function mod.clear_cache()
    local oslib = (Mods and Mods.lua and Mods.lua.os) or os
    local lang = current_lang()
    online.stop(mod)
    online.forget_cache()
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

-- Mod options: "Translation status" — what the queue is doing right now.
function mod.show_status()
    local s = online.status()
    local core_state, core_reason = online.core_status()

    util.info(mod, "status: running=%s finished=%s engine=%s provider=%s target=%s",
        tostring(s.running), tostring(s.finished), tostring(s.engine), tostring(s.provider), tostring(s.lang))
    util.info(mod, "queue: %d queued, %d left, %d translated (%d applied live), %d failed, %d refused, %d skipped",
        s.queued, s.left, s.done, s.live, s.failed, s.refused, s.skipped)
    if s.cooldown > 0 then
        util.info(mod, "rate limited: resuming in %d s", s.cooldown)
    end
    if s.last_error then
        util.info(mod, "last error: %s", tostring(s.last_error))
    end
    if s.disabled_providers ~= "" then
        util.info(mod, "providers dropped this session: %s", s.disabled_providers)
    end
    util.info(mod, "native core: %s (%s)", core_state, tostring(core_reason or "-"))

    local message = string.format("Auto Translate: %d/%d translated, %d left", s.done, s.queued, s.left)
    if mod.echo then
        pcall(mod.echo, mod, message)
    end
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

-- Mod options: "Test engine routing" — shows, per target language, which engine
-- and which online providers would actually be used. Makes the "MyMemory only
-- returns Traditional" rule visible without reading the code or starting a
-- translation run.
function mod.test_engines()
    local selected = mod:get("engine") or "auto"
    local has_key = type(mod:get("online_api_key")) == "string" and mod:get("online_api_key") ~= ""

    util.info(mod, "engine routing test (setting: %s, api key: %s):", selected, has_key and "set" or "none")
    for _, lang in ipairs(util.LANGUAGES) do
        local engine = engines.resolve(mod, lang)
        if engine == nil then
            util.info(mod, "  %-6s -> (nothing available: no model, no API key)", lang)
        else
            local providers = engines.providers_for(engine, lang)
            local gap = engines.gap(engine, lang)

            if gap then
                util.info(mod, "  %-6s -> %s  [NO PROVIDER: would return '%s']", lang, engine, tostring(gap.actual))
            elseif #providers > 0 then
                util.info(mod, "  %-6s -> %s  [%s]", lang, engine, table.concat(providers, ", "))
            else
                util.info(mod, "  %-6s -> %s", lang, engine)
            end
        end
    end

    if mod.echo then
        pcall(mod.echo, mod, string.format("engine: %s (see log for the per-language table)",
            tostring(engines.resolve(mod, current_lang()))))
    end
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "download_model_small" or setting_id == "download_model_large" then
        util.info(mod, "model download toggles are registered but the downloader is not implemented yet")
    elseif setting_id == "target_language" or setting_id == "engine"
        or setting_id == "online_api_key" or setting_id == "proxy" then
        -- These all change what the queue should even contain, so stopping is not
        -- enough: the pipeline has to be rebuilt. (Previously this only stopped the
        -- queue and told the player to press "Reload", which looked like nothing
        -- happened at all.)
        if setting_id == "target_language" then
            util.info(mod, "target language set to: %s", tostring(mod:get("target_language")))
        elseif setting_id == "engine" then
            util.info(mod, "engine set to: %s", tostring(mod:get("engine")))
        elseif setting_id == "online_api_key" then
            -- a new key deserves a fresh attempt after a failure streak
            engines.reset(mod)
        end

        online.flush(mod)
        online.stop(mod)

        if mod:get("auto_translate_enabled") then
            local ok, err = pcall(run_pipeline, "setting changed")
            if not ok then
                util.warn(mod, "could not restart after the setting change: %s", tostring(err))
            end
        else
            check_engine_settings(current_lang())
        end
    elseif setting_id == "auto_translate_enabled" then
        online.flush(mod)
        online.stop(mod)
        if mod:get("auto_translate_enabled") then
            -- turning it on should start work, not wait for another button
            local ok, err = pcall(run_pipeline, "enabled")
            if not ok then
                util.warn(mod, "could not start translation: %s", tostring(err))
            end
        else
            util.info(mod, "translation stopped by setting; %d key(s) already stored", online.status().done)
        end
    elseif setting_id == "apply_translation" then
        local ok, err = pcall(run_pipeline, "master switch")
        if not ok then
            util.warn(mod, "could not re-apply: %s", tostring(err))
        end
    end
end

util.log(mod, "framework loaded (v0.1.0, online engine wired)")
