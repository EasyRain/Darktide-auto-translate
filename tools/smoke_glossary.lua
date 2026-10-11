-- The real glossary module, exercised on the shapes the online path depends on.
--
-- smoke_online.lua stubs the glossary (it tests the request and reply plumbing), so nothing was checking
-- the masking rules themselves - which is how a term appearing twice in one string could share a single
-- placeholder, have one of the two dropped by a service, and pass the existence test unnoticed.
--
-- The module reads its terms from translations/glossary.lua, so this points MOD_DIR at the repository and
-- needs nothing from the installed game.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."

local ffi = require("ffi")
Mods = { lua = { ffi = setmetatable({}, { __index = function(_, key)
    if key == "load" then return function() error("no native core") end end
    return ffi[key]
end }) } }
package.path = repo .. "/scripts/mods/auto_translate/modules/?.lua;" .. package.path

local failures = 0
local function check(what, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(string.format("  %-4s %-46s got %-14s want %s", ok and "ok" or "FAIL", what,
        tostring(got):sub(1, 14), tostring(want):sub(1, 14)))
end

local function slurp(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

local glossary = require("glossary")
glossary.init({
    MOD_DIR = repo,
    file_exists = function(path) return slurp(path) ~= nil end,
    load_lua_file = function(path)
        local chunk = loadfile(path)
        if not chunk then return nil, "load failed" end
        return chunk()
    end,
    info = function() end, warn = function() end, error = function() end,
    get = function() return false end, log = function() end,
})

local ok, why = glossary.load()
check("the terms load from the repository", ok, true)
check("and there are some", glossary.total() > 1000, true)

local OPEN, CLOSE = "\226\159\166", "\226\159\167"     -- byte-wise: Lua 5.1 has no \u escapes
local function placeholders(text)
    local _, count = text:gsub(OPEN .. "%s*%d+%s*" .. CLOSE, "")
    return count
end

-- a term that appears twice shares one placeholder ("Reload Speed" is in the table; the smoke test for
-- the request plumbing uses the same one)
local masked, tokens = glossary.mask("Reload Speed or Reload Speed", "ja", true)
check("a repeated term masks to two placeholders", placeholders(masked), 2)
check("but only one token", #tokens, 1)
-- unmask puts the table's own target-language wording back, not the English source
local restored, restored_missing = glossary.unmask(masked, tokens, masked)
check("the answer is restored with the table wording",
    restored == tokens[1].term .. " or " .. tokens[1].term, true)
check("and nothing is missing", restored_missing, 0)

-- the new rule: one of two occurrences missing is a loss
local twice = OPEN .. "0" .. CLOSE .. " x " .. OPEN .. "0" .. CLOSE
local once = OPEN .. "0" .. CLOSE .. " x lost"
local _, missing_with_source, indices = glossary.unmask(once, { { term = "Manual" } }, twice)
check("a partially dropped duplicate is missing (with the source)", missing_with_source, 1)
check("and the index is named", indices[1], 1)
local _, missing_full = glossary.unmask(twice, { { term = "Manual" } }, twice)
check("both occurrences present is fine", missing_full, 0)
local _, missing_old = glossary.unmask(once, { { term = "Manual" } })
check("without the source the existence rule stays (old behaviour)", missing_old, 0)

-- whitespace inside a placeholder is tolerated (a machine translation re-spaces what it does not know)
local spaced = OPEN .. " 0 " .. CLOSE .. " x " .. OPEN .. " 0 " .. CLOSE
local _, missing_spaced = glossary.unmask(spaced, { { term = "Manual" } }, twice)
check("a re-spaced placeholder is still recognised", missing_spaced, 0)

-- a raw token (a masked line break) comes back as itself, untouched by the CJK spacing rules
local breaks = OPEN .. "0" .. CLOSE .. "first" .. OPEN .. "1" .. CLOSE .. OPEN .. "1" .. CLOSE .. "second"
local restored, missing_break = glossary.unmask(breaks, { { term = "x" }, { term = "\n", raw = true } }, nil)
check("a break token is restored", restored, "xfirst\n\nsecond")
check("and counts as present", missing_break, 0)

print(string.format("%d failure(s) in total", failures))
os.exit(failures == 0 and 0 or 1)
