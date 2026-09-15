-- engines.lua — translation engines.
--
-- This framework build only ships the "library" path: translations that already
-- exist in the local files are injected by the injector. The actual machine
-- translation engines are registered here in a later step:
--   manual      - hand written entries (always used, never overwritten)
--   local_base  - NLLB-200 1.3B, CTranslate2 int8, ~1.4 GB  (the offline default)
--   local_large - NLLB-200 3.3B, CTranslate2 int8, ~3.4 GB  (optional, slower)
--   online_free - free public endpoints (Google gtx / MyMemory), rate limited
--   online_api  - official API with a user supplied key
--
-- The 600M model is gone on purpose. Measured against the 1.3B on the same 68 real
-- strings (tools/model_probe.ps1): the 600M needed a fallback for 5 of 15 batches
-- because it lost the batch markers, and its answers were the worse ones in 34 cases
-- - it is the model behind 汽車 for "AUTO", 沒有任何問題 for "(auto)" and 發明方式 for
-- "INVENTORY MODE". A model that has to be rescued by the glossary and the guards is
-- not a cheaper engine, it is a source of wrong text.
local M = {}

local util
local store

function M.init(u, s)
    util = u
    store = s
end

M.ENGINES = {
    manual = { name = "manual", implemented = true },
    -- The local models run through modules/online.lua exactly like the API engines
    -- do - same queue, same pacing, same anti-misalignment guards - and differ only
    -- in transport: a submit/poll pair in the core instead of an HTTP job.
    local_base = { name = "local_base", implemented = true },
    local_large = { name = "local_large", implemented = true },
    online_free = { name = "online_free", implemented = false },
    online_api = { name = "online_api", implemented = true },
}

-- ---------------------------------------------------------------------------
-- Local model directories (CTranslate2 layout — the same four files Lingua ships):
--     models/base/    NLLB-200 1.3B int8
--     models/large/   NLLB-200 3.3B int8
-- ---------------------------------------------------------------------------
local MODEL_SUBDIR = {
    local_base = "base",
    local_large = "large",
}

local REQUIRED_MODEL_FILES = {
    "model.bin",
    "config.json",
    "shared_vocabulary.json",
    "sentencepiece.bpe.model",
}

function M.model_dir(name)
    local sub = MODEL_SUBDIR[name]
    if not sub then
        return nil
    end
    return util.MOD_DIR .. "/models/" .. sub
end

function M.model_available(name)
    local dir = M.model_dir(name)
    if not dir then
        return false
    end
    for _, file in ipairs(REQUIRED_MODEL_FILES) do
        if not util.file_exists(dir .. "/" .. file) then
            return false
        end
    end
    return true
end

function M.is_local_engine(name)
    return MODEL_SUBDIR[name] ~= nil
end

-- ---------------------------------------------------------------------------
-- Online providers.
--
-- The mod offers two engines now: the official API (with a key) and the local
-- model. The free public endpoints are still implemented and still pass their
-- offline tests, and they can still be selected by hand, but they are no longer
-- offered in the options and 'auto' never falls back to them: they get rate
-- limited and blocked too easily to build on. Google's translate.* hosts in
-- particular are reset during the TLS handshake in mainland China.
--
-- Kept here rather than deleted because they are the only zero-setup path and are
-- handy for testing; see src/at_online.c for the reachability notes.
--
--   google_clients5  clients5.google.com — reachable from mainland China, and the
--                    only free endpoint verified to answer zh-CN in Simplified.
--   google_gtx       translate.googleapis.com — reset during the TLS handshake in
--                    China (SNI filtering).
--   mymemory         reachable, but always answers in Traditional Chinese whatever
--                    you ask for — a MyMemory limitation, not a caller bug.
-- ---------------------------------------------------------------------------
M.FREE_PROVIDERS = { "google_clients5", "google_gtx", "mymemory" }

-- Official APIs. DeepL is the default because it is reachable from mainland
-- China (verified); translation.googleapis.com is not.
M.API_PROVIDERS = {
    deepl = "deepl",
    google = "google_api",
}

-- provider -> { requested language = language it returns instead }
local PROVIDER_GAPS = {
    mymemory = {
        ["zh-cn"] = "zh-tw",
    },
}

-- Language a provider cannot produce, or nil when it is fine.
function M.provider_gap(provider, lang)
    local gaps = PROVIDER_GAPS[provider]
    if not gaps then
        return nil
    end
    return gaps[lang]
end

-- Providers this engine may use for `lang`, in preference order. A provider that
-- would answer in the wrong language for `lang` is filtered out here, which is
-- the single enforcement point for the rule above: if this list runs empty there
-- is simply no way to translate into `lang` with this engine.
function M.providers_for(engine, lang)
    local out = {}
    if engine ~= "online_free" then
        return out
    end
    for _, provider in ipairs(M.FREE_PROVIDERS) do
        if not M.provider_gap(provider, lang) then
            out[#out + 1] = provider
        end
    end
    return out
end

-- Reason the engine cannot serve `lang`, or nil when it can.
function M.gap(engine, lang)
    if engine ~= "online_free" or lang == nil then
        return nil
    end
    if #M.providers_for(engine, lang) > 0 then
        return nil
    end
    return {
        engine = engine,
        target = lang,
        -- the language it would hand back instead, if any provider is known to differ
        actual = M.provider_gap("mymemory", lang),
    }
end

-- ---------------------------------------------------------------------------
-- Circuit breaker for translation engines.
--
-- A bad API key (or an unreachable service) would otherwise fail on every single
-- key forever. After MAX_FAILURES consecutive failures the engine is paused for
-- the rest of the session and the player is told. Any success resets the counter;
-- changing the relevant setting or reloading translations resets it manually.
-- ---------------------------------------------------------------------------
M.MAX_FAILURES = 3

local breaker = { failures = 0, paused = false, last_reason = nil }

function M.is_paused()
    return breaker.paused
end

function M.failure_state()
    return breaker.failures, breaker.paused, breaker.last_reason
end

function M.reset(mod)
    if breaker.failures > 0 or breaker.paused then
        if mod then
            util.info(mod, "engine failure counter reset")
        end
    end
    breaker.failures = 0
    breaker.paused = false
    breaker.last_reason = nil
end

-- Record a failed request. Returns true when this failure tripped the breaker.
function M.note_failure(mod, reason)
    if breaker.paused then
        return true
    end

    breaker.failures = breaker.failures + 1
    breaker.last_reason = reason

    util.log(mod, "engine failure %d/%d (%s)", breaker.failures, M.MAX_FAILURES, tostring(reason))

    if breaker.failures >= M.MAX_FAILURES then
        breaker.paused = true
        local message = mod:localize("engine_paused_failures")
        util.warn(mod, "engine paused after %d consecutive failures (last: %s)", breaker.failures, tostring(reason))
        if type(mod.notify) == "function" then
            pcall(mod.notify, mod, message)
        end
        if type(mod.echo) == "function" then
            pcall(mod.echo, mod, message)
        end
        return true
    end

    return false
end

-- Record a successful request.
function M.note_success()
    if breaker.failures > 0 or breaker.paused then
        breaker.failures = 0
        breaker.paused = false
        breaker.last_reason = nil
    end
end

-- The official API provider the player chose ("deepl" or "google").
function M.api_provider(mod)
    local wanted = mod and mod:get("api_provider")
    if type(wanted) == "string" and M.API_PROVIDERS[wanted] then
        return M.API_PROVIDERS[wanted]
    end
    return M.API_PROVIDERS.deepl
end

-- Resolves the engine to use. Returns nil when nothing is usable, so the caller
-- can say so instead of quietly picking something the player did not ask for.
--
-- A key wins over a downloaded model, which is the opposite of the first version of
-- this rule. Measured on the real models: the 600M conversion truncated a 102
-- character description to 13 characters and read "curios" as "curiosity", while
-- DeepL gets the same string right - so a player who has a key should get the better
-- engine by default. The models stay as the fallback for players who do not.
--
-- Between the two local models the larger one wins, because it makes fewer mistakes:
-- with neither downloaded nothing is chosen, and the caller says so instead of
-- silently running on a model the player never picked.
function M.resolve(mod, lang)
    local wanted = mod:get("engine") or "auto"
    if wanted ~= "auto" then
        return wanted
    end

    local key = mod:get("online_api_key")
    if type(key) == "string" and key ~= "" then
        return "online_api"
    end

    if M.model_available("local_large") then
        return "local_large"
    end
    if M.model_available("local_base") then
        return "local_base"
    end

    return nil
end

function M.is_implemented(name)
    local e = M.ENGINES[name]
    return e ~= nil and e.implemented == true
end

-- Reports what a local-model engine would do. Kept as a diagnostic: the pipeline no
-- longer calls it, because every engine now runs through online.start().
function M.run(mod, report, lang)
    local engine = M.resolve(mod, lang)
    local pending = report.stats.pending

    if pending == 0 then
        util.info(mod, "nothing to translate (engine: %s, target: %s)", tostring(engine), tostring(lang))
        return
    end

    if engine == nil then
        util.info(mod, "%d key(s) awaiting translation into '%s', but no engine is available", pending, tostring(lang))
        return
    end

    -- Guard as well as report: callers must not be able to reach a request that
    -- would come back in the wrong language.
    local gap = M.gap(engine, lang)
    if gap then
        util.warn(mod, "engine '%s' has no provider for '%s' (would return '%s')", engine, tostring(lang), tostring(gap.actual))
        return
    end

    util.info(mod, "%d key(s) pending (target: %s, engine: %s)", pending, tostring(lang), tostring(engine))
end

return M
