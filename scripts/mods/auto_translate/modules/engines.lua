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
function M.run(mod, report)
    local engine = M.resolve(mod)
    local pending = report.stats.pending

    if pending == 0 then
        util.info(mod, "nothing to translate (engine: %s)", engine)
        return
    end

    if not M.is_implemented(engine) then
        util.info(mod, "%d key(s) awaiting translation; engine '%s' is not implemented in this framework build", pending, engine)
        return
    end

    util.info(mod, "%d key(s) pending", pending)
end

return M
