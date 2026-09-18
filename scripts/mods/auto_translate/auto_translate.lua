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

-- "manual = true" is carried out where a store is read, and a store is read from three places (the
-- injector's merge, the scanner and the translation queue). Whoever gets there first does the work,
-- so the notice belongs to the store itself rather than to one of its callers - the first version
-- hung it on the injector and stayed silent when the scanner was the one that read the file.
store.set_notifier(function(mod_id, lang, stripped)
    util.info(mod, "%s [%s]: %d hand checked entr%s - engine markers removed, the file now says manual = false",
        mod_id, lang, stripped, stripped == 1 and "y" or "ies")
end)

local engines = mod:io_dofile(BASE .. "engines")
engines.init(util, store)

local glossary = mod:io_dofile(BASE .. "glossary")
glossary.init(util)

local custom = mod:io_dofile(BASE .. "custom")

local online = mod:io_dofile(BASE .. "online")
online.init(util, store, glossary, engines, injector, custom)

local exporter = mod:io_dofile(BASE .. "exporter")
exporter.init(util)

-- The model downloader: owns the file sequence, the progress state and the notices; the
-- transfer itself is native (src/at_download.c).
local download = mod:io_dofile(BASE .. "download")
download.init(mod, util, online, engines)

local progress_hud = mod:io_dofile(BASE .. "progress_hud")
progress_hud.init(mod, util, online, download)
progress_hud.install(mod)

local options_refresh = mod:io_dofile(BASE .. "options_refresh")
options_refresh.init(util)
options_refresh.install_hook(mod)

-- Language we translate INTO (configured, or the game's current language).
local function current_lang()
    return util.target_language(mod)
end

-- ---------------------------------------------------------------------------
-- Should the mod be doing anything at all?
--
-- Two switches, and the *early merge below has to honour both of them*, because that is where option
-- labels and tooltips are written - before DMF caches the localized strings. A switch that is only
-- consulted later cannot stop what the player sees:
--
--   * `apply_translation` is this mod's own master switch in its options;
--   * DMF's toggle in its mod list. `is_togglable` only adds that switch: DMF keeps loading the mod
--     and calls on_enabled/on_disabled, so respecting it is the mod's own job (dmf/modules/core/
--     events.lua documents exactly that). is_enabled() defaults to true and DMF applies the stored
--     state while it initializes, before any mod is loaded, so asking it here is safe.
--
-- Reported from the mod page: with the switch off, and with the mod disabled in DMF, translations
-- were still applied after a restart - both because this hook never asked.
-- ---------------------------------------------------------------------------
local function active()
    if not mod:get("apply_translation") then
        return false, "master switch off"
    end
    local ok, enabled = pcall(function() return mod:is_enabled() end)
    if ok and enabled == false then
        return false, "disabled in DMF"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Early hook: every mod loaded AFTER us passes through here.
--
-- DMF loads a mod's resources as localization -> data -> script, and localizes
-- the option titles/tooltips while initializing `data` (caching them as plain
-- strings). So we merge our translations into the table right before DMF stores
-- it — otherwise option texts would stay in the source language forever.
--
-- The hook exists from the moment OUR script runs, which is why the load order
-- matters: mods loaded *after* us are covered, mods loaded *before* us are not
-- (their option texts were already localized and cached by the time this line
-- runs). They are still translated - the scan injects their runtime text and
-- options_refresh re-localizes the widgets - but the options screen has to be
-- reopened once to show it. So the right place is the top of mod_load_order.txt,
-- above every other mod. `dmf` and `base` are loaded by the game itself and must
-- not be listed there at all (the file's own header says listing them errors);
-- the descriptor declares load_after = { "dmf" } so that dependency is on record.
-- ---------------------------------------------------------------------------
local hooked = false

-- Was the mod off while the game was loading? The early merge is the only chance to put translations
-- into a mod's localization table before DMF caches the option texts, so a mod that starts disabled
-- cannot catch up in the same session - see run_pipeline. nil means "not seen yet" (treated as on).
local started_disabled = nil
local restart_notice_shown = false

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

        -- The first call is during loading, which is exactly when the switch state decides whether
        -- this session can translate at all: remember it before the state can change under us.
        if started_disabled == nil then
            started_disabled = not active()
        end

        -- Nothing is merged while either switch says no; the table is still handed on untouched, so
        -- the mod plays exactly as it shipped.
        local on = active()
        if not on then
            return next_func(target_mod, loc_table)
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
-- Nothing usable yet: tripped circuit breaker, missing local model, or missing API key.
-- (The free endpoints mean "nothing configured at all" is almost impossible now - they need
-- neither a key nor a download - so the no-engine notice only appears when even they are
-- unavailable for the target language.)
local function check_engine_settings(lang)
    -- tripped circuit breaker: stop hammering a failing service
    if engines.is_paused() then
        local _, _, reason = engines.failure_state()
        util.info(mod, "translation paused after repeated engine failures (last: %s)", tostring(reason))
        return false
    end

    local engine = engines.resolve(mod, lang)

    -- Nothing configured and no free provider either.
    if engine == nil then
        util.log(mod, "no translation engine is available (no model downloaded, no API key set, no free provider for this language)")
        util.popup(mod, "no_engine_available")
        return false
    end

    -- local model selected but its files are not downloaded yet
    if engines.is_local_engine(engine) and not engines.model_available(engine) then
        util.log(mod, "engine '%s' is selected but its model is not downloaded", engine)
        -- The path is part of the message, and the message now names the two ways out: the
        -- download this mod can do, or the free endpoints that need no download at all.
        util.popup(mod, "model_missing", tostring(engines.model_dir_in_use(engine)))
        return false
    end

    -- The engine has no provider that can produce this language. Storing the
    -- wrong script would be worse than storing nothing, so refuse and say why.
    local gap = engines.gap(engine, lang)
    if gap then
        util.log(mod, "engine '%s' cannot produce '%s' (would return '%s')", engine, tostring(lang), tostring(gap.actual))
        util.popup(mod, "engine_language_gap", engine, tostring(gap.actual), tostring(lang), tostring(gap.actual))
        return false
    end

    if engine ~= "online_api" then
        return true
    end

    -- The custom service is configured by fields, not by one key, so what has to be
    -- checked is its own configuration - and a missing URL or response path is as fatal as
    -- a missing key (nothing can be sent, or nothing can be read back).
    if engines.api_provider(mod) == "custom" then
        if not custom then
            return true
        end
        local problem = custom.problem(custom.spec(mod))
        if not problem then
            return true
        end
        local spec = custom.spec(mod)
        util.log(mod, "the custom service is not usable: %s", problem)
        if problem == "custom_url_invalid" then
            util.popup(mod, problem, tostring(spec.url))
        else
            util.popup(mod, problem)
        end
        return false
    end

    local key = mod:get("online_api_key")
    if type(key) == "string" and key ~= "" then
        return true
    end

    util.log(mod, "engine 'online_api' is selected but no API key is set")
    util.popup(mod, "api_key_missing")
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

-- Everything stops, and what was merged into other mods' tables is taken back out. Used by both
-- switches: the mod's own master switch and DMF's toggle. The mods whose option texts the game has
-- already drawn keep them until the screen is rebuilt, which is why the options screen is marked
-- stale (and why the log says so).
local function stand_down(reason)
    online.flush(mod)
    online.stop(mod)
    local ok, removed = pcall(injector.unapply, mod)

    -- Put the original text back on the options screen. The widget titles and tooltips were localised
    -- (and cached as strings) while each mod's data initialized, so removing our values from the
    -- localization tables is not enough on its own: the widgets still hold the finished translation.
    -- options_refresh kept the original keys, so re-localising now resolves to the source language
    -- again (DMF falls back to `en` once the target-language entry is gone). The screen rebuilds on
    -- the next open, because clearing its cached templates while it is open breaks its own callbacks.
    local restored, restored_names = 0, 0
    if ok then
        local rok, count, names = pcall(options_refresh.reapply, mod)
        restored = (rok and tonumber(count)) or 0
        restored_names = (rok and tonumber(names)) or 0
    end
    options_refresh.mark_stale(mod)

    if ok then
        util.info(mod, "translation stopped (%s): took back %s injected key(s), restored %d option string(s) and %d mod name(s) to the original language; reopen the options screen for anything already drawn",
            reason, tostring(removed), restored, restored_names)
    else
        util.warn(mod, "translation stopped (%s), but taking the injected text back failed: %s (a restart clears it)",
            reason, tostring(removed))
    end
end

local function run_pipeline(reason)
    local on, why = active()
    if not on then
        util.info(mod, "nothing to do: %s (%s)", why, reason)
        return
    end

    -- The mod was off while the game loaded, so the early merge never ran: the option texts DMF
    -- cached during loading are English and cannot be replaced in this session (the runtime pass can
    -- only reach text a mod reads later, and the rebuilt options screen only re-localizes widgets).
    -- Running anyway produced a pile of notices for a result that looks broken, so say the one useful
    -- thing instead, once.
    if started_disabled and not restart_notice_shown then
        restart_notice_shown = true
        util.popup(mod, "enable_restart_needed")
        util.info(mod, "started disabled: translation needs a restart (%s)", reason)
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

    local injected = injector.apply(mod, report, lang)

    -- The option widgets are built from strings DMF cached while the mods loaded, so writing the
    -- translations into the localization tables does not reach them: re-localise from the recorded
    -- keys and have the screen rebuilt. Without this, switching the master switch back on translated
    -- plenty of runtime text but the options screen only changed after some other action re-localised
    -- it - which is what made it look like the switch needed a second click.
    if injected > 0 then
        local ok, refreshed = pcall(options_refresh.reapply, mod)
        if ok and tonumber(refreshed) and tonumber(refreshed) > 0 then
            options_refresh.mark_stale(mod)
            util.info(mod, "%d option string(s) re-localised; the options screen rebuilds on the next open",
                tonumber(refreshed))
        end
    end

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

-- How often update() looks at the game's string cache (see exporter.harvest_cache). It only
-- writes when the cache has produced key names the key list does not have, which a browsing
-- player does a handful of times per session, so a minute is often enough and never noisy.
local CACHE_HARVEST_INTERVAL = 60
local harvest_timer = 0

function mod.update(dt)
    -- A mod that has been switched off (its own master switch, or DMF's toggle) does nothing: no
    -- queue to advance, no cache to harvest.
    if not active() then
        return
    end

    local ok, err = pcall(online.update, mod, dt)
    if not ok then
        util.warn(mod, "online update error: %s", tostring(err))
        return
    end

    -- The transfer runs on its own thread in the core; this only advances the file
    -- sequence and the progress the HUD reads.
    local dok, derr = pcall(download.update, mod)
    if not dok then
        util.warn(mod, "download update error: %s", tostring(derr))
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

    -- The game's string cache grows as the player opens talent trees and menus; looking at it
    -- now and then is what names the keys no key list guessed. Writing only happens when there
    -- is something new, so a session that changes nothing costs one table walk a minute - and it
    -- stays out of the way entirely while collecting is switched off.
    harvest_timer = harvest_timer + (dt or 0)
    if harvest_timer >= CACHE_HARVEST_INTERVAL then
        harvest_timer = 0
        if mod:get("collect_terms") then
            pcall(exporter.harvest_cache, mod, util.game_language())
        end
    end
end

-- DMF calls this once every mod has finished loading (localization registry ready).
function mod.on_all_mods_loaded()
    local ok, err = pcall(run_pipeline, "startup")
    if not ok then
        util.warn(mod, "startup pipeline error: %s", tostring(err))
    end

    -- The whole-language terminology collection. Every launch looks the key list up in the CURRENT
    -- game language and writes translations/export/<language>.lua - but only when that file is
    -- missing or older than the key list's version, which is the first check the exporter makes. So
    -- a normal launch does nothing (one log line), and bumping `version` in
    -- translations/term_keys.lua collects once per language: launch, switch language in Steam,
    -- launch again. That is how the game's own wording for equipment, slots, missions and talents
    -- gets in - and it can only be collected from inside the game, because the strings live in the
    -- bundles rather than on disk.
    --
    -- It is behind a switch, off by default: collecting is something you turn on for a round, and
    -- the files it writes are the glossary's input rather than anything the game reads.
    if mod:get("collect_terms") then
        local collected, collect_err = pcall(exporter.run, mod, util.game_language())
        if not collected then
            util.warn(mod, "term export error: %s", tostring(collect_err))
        end

        -- Key names the key list does not have, read from the strings this session has already
        -- resolved. At this point that is mostly what the launch itself did; the timer in update()
        -- picks up the rest as the player opens menus. See exporter.harvest_cache.
        pcall(exporter.harvest_cache, mod, util.game_language())
    else
        util.log(mod, "term collection is off ('Collect terms'): nothing is written to translations/export/")
    end

    -- One line in the log that answers whether a *full* dump is possible: if the game's
    -- localization manager keeps its table reachable, the key list stops mattering and no future
    -- term change ever needs another collection run. Log only; nothing is written - and the answer
    -- is known (it is not), so it only runs with debug logging on.
    if mod:get("debug_logging") then
        pcall(exporter.describe_localization, mod)
    end

    -- exporter.probe_languages() answered its question on 2026-09-16 and is no longer called: the
    -- localizers are bound to the language loaded at startup, so a session cannot collect another
    -- language. See the function's comment for the measurement.
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

-- Mod options: "Test the online engine".
--
-- One sample string through the configured service, with the request, the status and the
-- reply in the chat. A custom endpoint has nine fields and every mistake in them looks the
-- same from the outside ("translation failed"), so this is what makes it configurable at
-- all.
function mod.test_custom_api()
    online.probe(mod, current_lang())
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

-- Mod options: "Delete the model files".
--
-- One model per process means the memory of a loaded model cannot be given back, so the
-- notice says a restart is what frees it - otherwise "deleted 1.4 GB" next to an
-- unchanged memory reading looks like a lie.
function mod.delete_model()
    online.stop(mod)
    download.cancel(mod)
    local removed = download.delete(mod)
    util.info(mod, "%d model file(s) removed from %s", removed, tostring(engines.model_dir("local_base")))
    if online.model_in_memory() then
        util.info(mod, "the model loaded in this session stays in memory until the game restarts")
    end
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

-- DMF's own switch (its mod list). `is_togglable` in the descriptor is what puts it there, and DMF
-- keeps the mod loaded either way, so these two callbacks are what make the switch mean something.
--
-- The startup calls (initial_call = true) need no work: `active()` already refused the early merge
-- and `on_all_mods_loaded` runs its own check, so a mod that starts disabled starts silent.
function mod.on_disabled(initial_call)
    if initial_call then
        return
    end
    stand_down("disabled in DMF")
end

function mod.on_enabled(initial_call)
    if initial_call then
        return
    end
    local ok, err = pcall(run_pipeline, "enabled in DMF")
    if not ok then
        util.warn(mod, "could not start after being enabled in DMF: %s", tostring(err))
    end
end

mod.on_setting_changed = function(setting_id)
    if setting_id == "download_model" then
        -- The switch is the control: on starts (or continues) the transfer, off cancels it
        -- and keeps whatever arrived. Both halves say what happened, because a 1.4 GB
        -- download that appears to do nothing is indistinguishable from a broken one.
        if mod:get("download_model") then
            download.start(mod)
        else
            download.cancel(mod)
        end
    elseif setting_id == "model_mirror" then
        -- Only affects the *next* transfer; a running one keeps the host it started with.
        util.info(mod, "model downloads will start from %s",
            mod:get("model_mirror") == false and "huggingface.co" or "hf-mirror.com")
    elseif setting_id == "model_threads" then
        -- The thread count is fixed when the model is loaded (CTranslate2 takes it in the
        -- replica pool), so this one cannot be rebuilt into effect like the others: the
        -- model has to be loaded again, which only happens on the next launch. Saying that
        -- is the difference between "the setting did nothing" and "the setting is right,
        -- it needs a restart".
        if online.model_in_memory() then
            util.info(mod, "the core count applies after a restart (models keep their thread pool)")
            util.popup(mod, "model_restart_needed", tostring(mod:get("model_threads")))
        end
    elseif setting_id == "target_language" or setting_id == "engine"
        or setting_id == "online_api_key" or setting_id == "proxy"
        or setting_id == "retranslate_local"
        or setting_id:sub(1, 7) == "custom_" or setting_id == "api_provider" then
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
        if mod:get("apply_translation") then
            local ok, err = pcall(run_pipeline, "master switch")
            if not ok then
                util.warn(mod, "could not re-apply: %s", tostring(err))
            end
        else
            stand_down("master switch off")
        end
    elseif setting_id == "collect_terms" then
        if mod:get("collect_terms") then
            -- Switching it on collects straight away rather than at the next launch: the export only
            -- needs the language the game is already running in.
            local lang = util.game_language()
            local ok, err = pcall(exporter.run, mod, lang)
            if not ok then
                util.warn(mod, "term export error: %s", tostring(err))
            end
            pcall(exporter.harvest_cache, mod, lang)
        else
            util.info(mod, "term collection off: nothing more is written to translations/export/ (the files already there stay)")
        end
    end
end

util.log(mod, "framework loaded (v0.1.0, online engine wired)")
