-- engines.lua — translation engines.
--
-- The engines a player can pick, in the order 'auto' prefers them:
--   manual      - hand written entries (always used, never overwritten)
--   online_api  - official API with a user supplied key (best quality)
--   local_base  - NLLB-200 1.3B, CTranslate2 int8, ~1.4 GB (needs no network)
--   online_free - the keyless public endpoints (Google's translate hosts, MyMemory)
--
-- Only *one* offline model is shipped, and both bigger and smaller ones were tried:
--
--   * NLLB-200 distilled 600M was dropped first. Measured against the 1.3B on the same
--     68 real strings (tools/model_probe.ps1): it lost the batch markers in 5 of 15
--     batches against 1 of 15, and its answers were the worse ones in 34 cases - it is
--     the model behind 汽車 for "AUTO", 沒有任何問題 for "(auto)" and 發明方式 for
--     "INVENTORY MODE".
--   * NLLB-200 3.3B was dropped after that measurement: three times the memory
--     (3,813 MB against 1,663 MB) and ~2.2x the time per string (~1.36 s against
--     ~0.60 s), for answers that differ but are not *better* - while it lost the batch
--     markers in 10 of 15 batches, which pushes every short label back to a single-string
--     request, the case these models handle worst. Twice the cost for no step change is
--     not a tier worth downloading, so the local engine is the 1.3B and nothing else.
local M = {}

local util
local store

function M.init(u, s)
    util = u
    store = s
end

M.ENGINES = {
    manual = { name = "manual", implemented = true },
    -- The local model runs through modules/online.lua exactly like the API engines do -
    -- same queue, same pacing, same anti-misalignment guards - and differs only in
    -- transport: a submit/poll pair in the core instead of an HTTP job.
    local_base = { name = "local_base", implemented = true },
    -- The free public endpoints (no key, no download). They were implemented from the start
    -- and taken out of the options because they are rate limited and blocked easily - but they
    -- are the only thing left for a player with no key and no model, so they are a real
    -- choice again, and 'auto' falls back to them after the other two.
    online_free = { name = "online_free", implemented = true },
    online_api = { name = "online_api", implemented = true },
}

-- ---------------------------------------------------------------------------
-- Local model directory (CTranslate2 layout - the same four files Lingua ships):
--     models/         the four files sit directly in the mod's models folder
--
-- There used to be a subdirectory per size (models/small, models/large, models/base).
-- With one model left, a folder with one folder in it is just a thing to get wrong, so
-- the files belong in models/ itself. The old subdirectories are still *read* when the
-- flat layout is not complete, so an installation made before this change keeps working.
-- ---------------------------------------------------------------------------
local MODEL_SUBDIR = {
    local_base = "",
}

local LEGACY_MODEL_DIRS = { "base", "large", "small" }

local REQUIRED_MODEL_FILES = {
    "model.bin",
    "config.json",
    "shared_vocabulary.json",
    "sentencepiece.bpe.model",
}

-- Settings files written before the tiers were trimmed still contain the old ids:
-- "local_small" (the 600M) and "local_large" (the 3.3B). Both have to keep meaning
-- something usable, or a saved choice selects an engine that no longer exists and
-- translation quietly never starts; the 1.3B is the only offline engine left, so both
-- map to it.
local LEGACY_ENGINES = {
    local_small = "local_base",
    local_large = "local_base",
}

function M.canonical(name)
    if type(name) ~= "string" then
        return name
    end
    return LEGACY_ENGINES[name] or name
end

local function dir_complete(dir)
    if type(dir) ~= "string" or dir == "" then
        return false
    end
    for _, file in ipairs(REQUIRED_MODEL_FILES) do
        if not util.file_exists(dir .. "/" .. file) then
            return false
        end
    end
    return true
end

-- Where the files *should* be.
function M.model_dir(name)
    local sub = MODEL_SUBDIR[M.canonical(name)]
    if sub == nil then
        return nil
    end
    if sub == "" then
        return util.MOD_DIR .. "/models"
    end
    return util.MOD_DIR .. "/models/" .. sub
end

-- Where they are: the flat folder when it is complete, otherwise the first legacy
-- subdirectory that is. The second return value says whether that was a legacy location,
-- so the caller can tell the player to move the files.
function M.model_dir_in_use(name)
    local canonical = M.model_dir(name)
    if not canonical then
        return nil, false
    end
    if dir_complete(canonical) then
        return canonical, false
    end
    for _, legacy in ipairs(LEGACY_MODEL_DIRS) do
        local dir = util.MOD_DIR .. "/models/" .. legacy
        if dir_complete(dir) then
            return dir, true
        end
    end
    return canonical, false
end

function M.model_available(name)
    local dir = M.model_dir_in_use(name)
    return dir_complete(dir)
end

function M.is_local_engine(name)
    return MODEL_SUBDIR[M.canonical(name)] ~= nil
end

-- ---------------------------------------------------------------------------
-- Online providers.
--
-- Two kinds, and they answer different needs:
--
--   * the official API (needs a key) - best quality, and what 'auto' picks when a key is set
--   * the free public endpoints (no key, no download) - the only thing left for a player who
--     has neither a key nor a model, so they are a selectable engine again and the last tier
--     of 'auto'. They are rate limited and easily blocked, which is why they are not the
--     first choice; see src/at_online.c for the request shapes.
--
--     google_clients5  clients5.google.com — measured reachable (and answering correctly)
--                      when translate.googleapis.com was not, so it is tried first. It was
--                      also the only free endpoint that answered zh-CN in Simplified at the
--                      time; MyMemory does that too now (see PROVIDER_GAPS).
--     google_gtx       translate.googleapis.com — the endpoint most other tools use. Its TLS
--                      handshake is reset by network filtering on many networks, and whether
--                      it is reachable depends on the route taken (measured on one machine:
--                      direct = reset, through a proxy with a rule for the host = answers).
--     mymemory         mymemory.translated.net — reachable, but it is a translation *memory*
--                      rather than a machine translator, so answers can be human segments
--                      that do not fit: measured "Reload Speed" -> "ユーザーのリロード速度:"
--                      (ja) and "Keystone" -> 梯形 (zh-cn). Last on purpose.
--
--     bing             cn.bing.com — the one that works where the others do not: Google's
--                      hosts are filtered on many networks (China especially) and MyMemory
--                      answers with dictionary junk, while this endpoint answered all twelve
--                      targets from a China residential IP. It is placed after Google and
--                      before MyMemory because it is slower to start (one page load hands out
--                      a key, a token and an IG, and every request carries them back — see
--                      ensure_session() in online.lua) but far better than a translation
--                      memory: measured, it keeps the glossary placeholders, the [n] markers,
--                      %s specifiers and line breaks, and it survived 15 requests at one per
--                      second without a refusal.
--
--                      Tencent's transmart endpoint was measured too and is *not* here: it
--                      needs no session and batches natively, but its engine rewrites the
--                      placeholder ("⟦0⟧ unlocked" came back as a 70-digit number, "⟦0⟧,⟦1⟧"
--                      as "2010年,2011年"), which the masking cannot survive. Baidu answers
--                      errno 1022 without its signed token flow, from a China IP and a hosting
--                      IP alike. Neither is worth a provider that would refuse every string
--                      containing a known term.
-- ---------------------------------------------------------------------------
M.FREE_PROVIDERS = { "google_clients5", "google_gtx", "bing", "mymemory" }

-- Official APIs. DeepL is the default because it is reachable directly on most
-- networks (verified without a proxy); translation.googleapis.com is not.
-- The services the "Online API" engine can talk to. Google Cloud is *not* offered: it is
-- unreachable on many networks (the TLS handshake to translation.googleapis.com is reset
-- there, verified) and its sign-up is the most involved of the three. Its code is still in
-- at_online.c and passes its offline tests, so it can be brought back by adding one line
-- here - but it is not a setting any more.
M.API_PROVIDERS = {
    deepl = "deepl",
    custom = "custom",
}

-- A settings file written before Google was dropped still says api_provider = "google".
-- DeepL is the only shipped service left, so that value maps to it instead of selecting a
-- provider the options no longer offer.
local LEGACY_PROVIDERS = {
    google = "deepl",
}

-- provider -> { requested language = language it returns instead }
--
-- Empty on purpose now. MyMemory used to be listed here for zh-cn ("always answers in
-- Traditional Chinese"), which excluded the only free provider that worked on networks where
-- Google's hosts were filtered. Measured again: it answers zh-cn in Simplified (库存 / 设置 /
-- 伤害 / 装弹速度), so the entry was stale and cost the player a provider. The mechanism stays:
-- a provider that really cannot produce a language belongs here, and it is enforced in one
-- place (providers_for).
local PROVIDER_GAPS = {}

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
--
-- A gap means *every* free provider is known to answer in another language for this target,
-- so there is nothing to try; the language it would hand back comes from the last such
-- provider instead of naming one by hand (the old version assumed MyMemory, which is only one
-- of three).
function M.gap(engine, lang)
    if engine ~= "online_free" or lang == nil or #M.FREE_PROVIDERS == 0 then
        return nil
    end
    local actual = nil
    for _, provider in ipairs(M.FREE_PROVIDERS) do
        local gap = M.provider_gap(provider, lang)
        if not gap then
            return nil          -- at least one provider can produce this language
        end
        actual = gap
    end
    return {
        engine = engine,
        target = lang,
        actual = actual,
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
        util.warn(mod, "engine paused after %d consecutive failures (last: %s)", breaker.failures, tostring(reason))
        util.popup(mod, "engine_paused_failures")
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
    if type(wanted) == "string" then
        wanted = LEGACY_PROVIDERS[wanted] or wanted
        if M.API_PROVIDERS[wanted] then
            return M.API_PROVIDERS[wanted]
        end
    end
    return M.API_PROVIDERS.deepl
end

-- Resolves the engine to use. Returns nil when nothing is usable, so the caller
-- can say so instead of quietly picking something the player did not ask for.
--
-- 'auto' is a preference order, not a guess:
--
--   1. the official API, when a key is set. A key wins over a downloaded model, which is the
--      opposite of the first version of this rule. Measured on the real models: the 600M
--      conversion truncated a 102 character description to 13 characters and read "curios" as
--      "curiosity", while DeepL gets the same string right - so a player who has a key should
--      get the better engine by default.
--   2. the offline model, when it is downloaded. It needs no network at all, so it beats the
--      free endpoints for anyone who has it (those are rate limited and can be filtered).
--   3. the free public endpoints - no key, no 1.4 GB download. This is the tier that makes
--      "no key and no model" translate at all, which is why it is in this chain and in the
--      options again; it is last because it is the least reliable of the three.
--
-- There is exactly one offline model to fall back to now (see the note at the top of the
-- file): a bigger model was measured and did not earn its cost, and a smaller one was
-- measured and was not good enough.
function M.resolve(mod, lang)
    local wanted = mod:get("engine") or "auto"
    if wanted ~= "auto" then
        return M.canonical(wanted)
    end

    local key = mod:get("online_api_key")
    if type(key) == "string" and key ~= "" then
        return "online_api"
    end

    if M.model_available("local_base") then
        return "local_base"
    end

    if #M.providers_for("online_free", lang) > 0 then
        return "online_free"
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
