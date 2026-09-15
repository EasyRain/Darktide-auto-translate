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

local progress_hud = mod:io_dofile(BASE .. "progress_hud")
progress_hud.init(mod, util, online)
progress_hud.install(mod)

local options_refresh = mod:io_dofile(BASE .. "options_refresh")
options_refresh.init(util)
options_refresh.install_hook(mod)

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

-- Scan options.
--
-- `engine` is always passed: a key the engine in use has already refused three times is
-- *parked* rather than pending, so it stops being retried on every launch (see the refusal
-- budget in modules/online.lua and store.note_refusal). Any other engine - the API, or the
-- other model - picks the key up again, which is what makes switching engines redo the work.
--
-- `redo_local` is the extra step for entries the offline model already *translated*: with
-- an online engine in use, and the option ticked, they are scanned as pending again.
-- Ticking it while a local model is selected would make the model re-translate its own
-- output on every run, so the engine being online is part of the condition, not just the box.
local function scan_opts(lang)
    local engine = engines.resolve(mod, lang)
    local opts = { engine = engine }

    if mod:get("retranslate_local") == true and engine ~= nil and not engines.is_local_engine(engine) then
        opts.redo_local = true
    end

    return opts
end

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
        -- The path is part of the message: with no automatic download yet, copying the
        -- files there is the only thing the player can do.
        local message = mod:localize("model_missing", tostring(engines.model_dir(engine)))
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

    local report = scanner.scan(mod, lang, scan_opts(lang))
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
    if st.redo > 0 then
        -- Say it out loud: these are requests against the API quota, and the number is
        -- the whole reason the option exists.
        util.info(mod, "%d key(s) translated by the offline model will be translated again by '%s'",
            st.redo, tostring(engines.resolve(mod, lang)))
    end

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
            -- One queue driver for every engine. The offline model goes through
            -- online.start() as well; only the way a string travels differs (a
            -- submit/poll pair in the core instead of an HTTP job). Keeping both on
            -- one path is what keeps the anti-misalignment guards in one place.
            if not online.start(mod, report, lang) then
                util.info(mod, "translation was not started (see the warnings above)")
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
    -- The same options as the run that fills the queue, or an entry marked for a redo
    -- would look "ready" here and never be injected while it is being translated.
    local report = scanner.scan(mod, lang, scan_opts(lang))
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
        -- Pick up the mod names / settings texts the run produced. The options
        -- screen is only asked to rebuild when one of them really changed: a run
        -- that only touched text a mod looks up at runtime needs no rebuild at all,
        -- and once the work is finished nothing here fires again.
        local refreshed = 0
        pcall(function()
            refreshed = options_refresh.reapply(mod)
        end)
        if refreshed > 0 then
            options_refresh.mark_stale(mod)
            util.info(mod, "%d option string(s) refreshed; close and reopen the options screen to see them", refreshed)
        end
    end
end

-- DMF calls this once every mod has finished loading (localization registry ready).
function mod.on_all_mods_loaded()
    local ok, err = pcall(run_pipeline, "startup")
    if not ok then
        util.warn(mod, "startup pipeline error: %s", tostring(err))
    end

    -- The whole-language terminology collection is done: translations/export/
    -- holds all 12 languages. It used to run here and announce itself on every
    -- launch ("already collected", "progress 12/12"), which was pure noise. The
    -- module is kept in case the game adds terms or a language: call
    --   exporter.run(mod, current_lang())
    -- from here (or from a button) to collect again.
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
        return
    end

    -- DMF turned the option titles into plain strings while the game was starting,
    -- so re-localise them from the keys recorded at that moment. Only ask for a
    -- rebuild when something actually changed - with nothing new to show, clearing
    -- the cached options would be pure waste.
    local refreshed = options_refresh.reapply(mod)
    if refreshed > 0 then
        options_refresh.mark_stale(mod)
        util.info(mod, "re-applied %d option string(s); close and reopen the options screen to see them", refreshed)
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, mod:localize("reload_done", refreshed))
        end
    else
        util.info(mod, "no option text needed re-applying; the options screen is left as it is")
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
    util.info(mod, "queue: %d queued, %d left, %d translated (%d live), %d unchanged, %d failed, %d refused, %d skipped",
        s.queued, s.left, s.done, s.live, s.unchanged, s.failed, s.refused, s.skipped)
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

    -- What would be used, and whether it can actually produce the target language.
    -- This is what the old "test engine routing" button was for; with one engine
    -- and one provider the per-language table it printed had become the same row
    -- thirteen times, so only the check that can still fail is kept.
    local lang = current_lang()
    util.info(mod, "engine setting: %s -> %s", tostring(mod:get("engine")), tostring(s.engine or "(nothing available)"))

    if mod:get("engine") == "online_api" or s.engine == "online_api" then
        local key = mod:get("online_api_key")
        local has_key = type(key) == "string" and key ~= ""
        util.info(mod, "api service: %s, key: %s", tostring(mod:get("api_provider")), has_key and "set" or "MISSING")

        -- The language codes differ per provider (DeepL wants ZH-HANS where Google
        -- wants zh-CN), and an unsupported pair fails at request time - worth
        -- catching here instead.
        local ffi = Mods and Mods.lua and Mods.lua.ffi
        local handle = online.load_core(mod)
        if handle and ffi and ffi.new then
            local buffer = ffi.new("char[?]", 16)
            local ok, supported = pcall(function()
                return handle.at_online_lang_code_for(engines.api_provider(mod), lang, buffer, 16)
            end)
            if ok then
                util.info(mod, "provider language code for '%s': %s", lang,
                    supported == 1 and ("supported (" .. tostring(ffi.string(buffer)) .. ")")
                        or "NOT SUPPORTED - pick another target language or API service")
            end
        end
    end

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

mod.on_setting_changed = function(setting_id)
    if setting_id == "download_model_base" or setting_id == "download_model_large" then
        -- The downloader is not written yet. Logging that only was the wrong call: the
        -- player flips the switch, nothing happens, and there is no way to tell whether
        -- it is broken or simply absent. So the notice is player-visible and says what
        -- to do instead.
        local which = setting_id == "download_model_large" and "large" or "base"
        local dir = util.MOD_DIR .. "/models/" .. which
        util.warn(mod, "the automatic model download is not implemented yet; place the 4 model files in %s", dir)
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, mod:localize("model_download_missing", dir))
        end
        if type(mod.echo) == "function" then
            pcall(mod.echo, mod, mod:localize("model_download_missing", dir))
        end
    elseif setting_id == "model_threads" then
        -- The thread count is fixed when the model is loaded (CTranslate2 takes it in the
        -- replica pool), so this one cannot be rebuilt into effect like the others: the
        -- model has to be loaded again, which only happens on the next launch. Saying that
        -- is the difference between "the setting did nothing" and "the setting is right,
        -- it needs a restart".
        if online.model_in_memory() then
            local message = mod:localize("model_restart_needed", tostring(mod:get("model_threads")))
            util.info(mod, "the core count applies after a restart (models keep their thread pool)")
            if type(mod.notify) == "function" then
                pcall(mod.notify, mod, message)
            end
            if type(mod.echo) == "function" then
                pcall(mod.echo, mod, message)
            end
        end
    elseif setting_id == "target_language" or setting_id == "engine"
        or setting_id == "online_api_key" or setting_id == "proxy"
        or setting_id == "retranslate_local" then
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
