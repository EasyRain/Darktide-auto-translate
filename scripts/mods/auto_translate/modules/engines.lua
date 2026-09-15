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

function M.resolve(mod)
    local wanted = mod:get("engine") or "auto"
    if wanted == "auto" then
        -- later: pick local model if downloaded, else online
        return "local_small"
    end
    return wanted
end

function M.is_implemented(name)
    local e = M.ENGINES[name]
    return e ~= nil and e.implemented == true
end

-- Placeholder runner: reports what would be translated.
function M.run(mod, report, lang)
    local engine = M.resolve(mod)
    local pending = report.stats.pending

    if pending == 0 then
        util.info(mod, "nothing to translate (engine: %s, target: %s)", engine, tostring(lang))
        return
    end

    if not M.is_implemented(engine) then
        util.info(mod, "%d key(s) awaiting translation into '%s'; engine '%s' is not implemented in this framework build", pending, tostring(lang), engine)
        return
    end

    util.info(mod, "%d key(s) pending (target: %s)", pending, tostring(lang))
end

return M
