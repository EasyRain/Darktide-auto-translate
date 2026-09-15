-- engines.lua — translation engines.
--
-- This framework build only ships the "library" path: translations that already
-- exist in the local files are injected by the injector. The actual machine
-- translation engines are registered here in a later step:
--   manual      - hand written entries (always used, never overwritten)
--   local_small - NLLB-200 distilled 600M, CTranslate2 int8, ~600 MB
--   local_large - NLLB-200 1.3B, CTranslate2 int8, ~1.3 GB
--   online_free - free public endpoints (Google gtx / MyMemory), rate limited
--   online_api  - official API with a user supplied key
local M = {}

local util
local store

function M.init(u, s)
    util = u
    store = s
end

M.ENGINES = {
    manual = { name = "manual", implemented = true },
    local_small = { name = "local_small", implemented = false },
    local_large = { name = "local_large", implemented = false },
    online_free = { name = "online_free", implemented = false },
    online_api = { name = "online_api", implemented = false },
}

-- ---------------------------------------------------------------------------
-- Local model directories (CTranslate2 layout — the same four files Lingua ships):
--     models/small/   NLLB-200 distilled 600M int8
--     models/large/   NLLB-200 1.3B int8
-- ---------------------------------------------------------------------------
local MODEL_SUBDIR = {
    local_small = "small",
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
-- Online providers and what they can actually produce.
--
-- The "free" engine is a list of providers, tried in this order:
--
--   google_clients5  clients5.google.com — the only free endpoint verified
--                    reachable from mainland China, and it answers zh-CN in
--                    Simplified and zh-TW in Traditional (verified 2026-09-15).
--   google_gtx       translate.googleapis.com — same engine, but this host is
--                    reset during the TLS handshake in China (SNI filtering),
--                    so it is the second choice rather than the first.
--   mymemory         reachable in China, but always answers in Traditional
--                    Chinese whatever you ask for — the Lingua Imperialis author
--                    confirmed this is a MyMemory limitation, not a caller bug
--                    ("If you want to translate your outgoing messages to Chinese
--                    Simplified, use either Google Translate or the offline NLLB").
--
-- So a provider that cannot produce the requested language is removed *before*
-- any request is made, and a wrong-but-present translation is never stored: it
-- would be silently shipped to the player as if it were correct.
--
-- Endpoint behaviour was measured, not assumed — see at_cli.exe selftest and the
-- notes in src/at_online.c.
-- ---------------------------------------------------------------------------
M.FREE_PROVIDERS = { "google_clients5", "google_gtx", "mymemory" }

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

function M.resolve(mod, lang)
    local wanted = mod:get("engine") or "auto"
    if wanted ~= "auto" then
        return wanted
    end

    -- both models downloaded -> prefer the one with more parameters
    if M.model_available("local_large") then
        return "local_large"
    end
    if M.model_available("local_small") then
        return "local_small"
    end

    -- No local model. If the free service cannot produce this language at all,
    -- a configured API key is the only way to get a correct result, so it wins
    -- over a free provider that would answer in the wrong language.
    if M.gap("online_free", lang) then
        local key = mod:get("online_api_key")
        if type(key) == "string" and key ~= "" then
            return "online_api"
        end
    end

    return "online_free"
end

function M.is_implemented(name)
    local e = M.ENGINES[name]
    return e ~= nil and e.implemented == true
end

-- Placeholder runner: reports what would be translated.
function M.run(mod, report, lang)
    local engine = M.resolve(mod, lang)
    local pending = report.stats.pending

    if pending == 0 then
        util.info(mod, "nothing to translate (engine: %s, target: %s)", engine, tostring(lang))
        return
    end

    -- Guard as well as report: callers must not be able to reach a request that
    -- would come back in the wrong language.
    local gap = M.gap(engine, lang)
    if gap then
        util.warn(mod, "engine '%s' has no provider for '%s' (would return '%s')", engine, tostring(lang), tostring(gap.actual))
        return
    end

    if not M.is_implemented(engine) then
        util.info(mod, "%d key(s) awaiting translation into '%s'; engine '%s' is not implemented in this framework build", pending, tostring(lang), engine)
        return
    end

    util.info(mod, "%d key(s) pending (target: %s)", pending, tostring(lang))
end

return M
