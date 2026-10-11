-- Two steps of the sampled pipeline, driven by a shell loop.
--
-- A full run is impractical (2000+ keys, and the free tier does not hand out a whole round), so a handful
-- of risky shapes are driven through the real modules instead - mask, the line-break pass, the wire form,
-- a real request, the decode, the unmask and the real guards:
--
--   luajit tools/sample_step.lua wire    <index> <lang> <out-file>
--       writes the exact text a provider would receive (the wire form)
--   luajit tools/sample_step.lua verdict <index> <lang> <answer-file>
--       runs decode -> unmask -> text_is_safe on the answer and prints "ok" or "FAIL <reason>"
--
-- The request itself is made by tools/smoke_bing.lua (which owns the bing session) or by at_cli for the
-- endpoints that need none, so this file never speaks HTTP.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."

local ffi = require("ffi")
Mods = { lua = { ffi = setmetatable({}, { __index = function(_, key)
    if key == "load" then return function() error("no native core") end end
    return ffi[key]
end }) } }
package.path = repo .. "/scripts/mods/auto_translate/modules/?.lua;" .. package.path

local function slurp(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

local glossary = require("glossary")
local MOD_DIR = [[D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate]]
glossary.init({
    MOD_DIR = MOD_DIR,
    file_exists = function(path) return slurp(path) ~= nil end,
    load_lua_file = function(path)
        local chunk = loadfile(path)
        if not chunk then return nil, "load failed" end
        return chunk()
    end,
    info = function() end, warn = function() end, error = function() end,
    get = function() return false end, log = function() end,
})
assert(glossary.load())
local online = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/online.lua"))()

local OPEN, CLOSE = "\226\159\166", "\226\159\167"     -- byte-wise: Lua 5.1 has no \u escapes

-- the online path's line-break pass (see mask_breaks in online.lua): each break becomes its own token
local function mask_breaks(text, tokens)
    if not text:find("\n", 1, true) then
        return text, tokens
    end
    local out = {}
    for i = 1, #tokens do out[i] = tokens[i] end
    text = text:gsub("\n", function()
        out[#out + 1] = { term = "\n", raw = true }
        return OPEN .. (#out - 1) .. CLOSE
    end)
    return text, out
end

local function mask_sample(index, lang)
    local samples = dofile(here .. "/sample-input.lua")
    local item = samples[index]
    if not item then
        return nil, nil, nil
    end
    local masked, tokens = glossary.mask(item.en, lang, true)
    masked, tokens = mask_breaks(masked, tokens)
    return item, masked, tokens
end

local mode, index, lang, path = arg[1], tonumber(arg[2]), arg[3], arg[4]
assert(mode == "wire" or mode == "verdict" or mode == "retry",
    "usage: wire|verdict|retry <index> <lang> <file> [out]")
local item, masked, tokens = mask_sample(index, lang)
if not item then
    print("FAIL no such sample: " .. tostring(index))
    os.exit(1)
end

-- A string the run never sends is not a sample: the decoration rule (a marquee title, a swatch) skips it
-- before any request, so measuring it here would invent failures for strings that cost nothing.
if online.is_asset_entry_for_tests(item.en) then
    if mode == "wire" then
        local handle = assert(io.open(path, "wb"))
        handle:write("")
        handle:close()
    end
    print("skip " .. item.shape .. " (the decoration rule leaves it in English)")
    os.exit(0)
end

if mode == "wire" then
    -- exactly what the request carries: the same two conversions the online paths apply
    local text = glossary.to_wire(masked, tokens)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
    print("wire " .. item.shape .. " " .. #tokens .. " token(s)")
    os.exit(0)
end

if mode == "retry" then
    -- Plan A as the run applies it: the tokens the service dropped are sent as plain text instead.
    local raw = slurp(path) or ""
    local internal = glossary.to_internal(raw, tokens)
    local rest, missing = glossary.unmask(internal, tokens, masked)
    local relax = {}
    local added = 0
    for i = 1, #tokens do
        local placeholder = OPEN .. (i - 1) .. CLOSE
        if not internal:find(placeholder, 1, true) then
            relax[i] = true
            added = added + 1
        end
    end
    local relaxed, kept = online.relax_mask_for_tests(masked, tokens, relax)
    local handle = assert(io.open(arg[5] or path, "wb"))
    handle:write(glossary.to_wire(relaxed, kept))
    handle:close()
    -- The answer that comes back is judged against the *relaxed* expectation, not the original one: the
    -- relaxed terms are deliberately no longer placeholders, so counting them as missing would be wrong.
    -- (The first version of this harness did exactly that and reported plan A as useless.)
    local side = assert(io.open((arg[5] or path) .. ".relax", "wb"))
    side:write("return {")
    for i = 1, #tokens do
        if relax[i] then side:write(i .. ", ") end
    end
    side:write("}\n")
    side:close()
    print(string.format("retry %d token(s) relaxed, %d kept", added, #kept))
    os.exit(0)
end

local raw = slurp(path)
if not raw then
    print("FAIL could not read the answer: " .. tostring(path))
    os.exit(1)
end

-- the reply side of the real pipeline
local internal = glossary.to_internal(raw, tokens)
-- A retry's expectation: the same relaxation the request applied
local side = loadfile(path .. ".relax")
if side then
    local relax_list = side()
    local relax = {}
    for _, i in ipairs(relax_list) do relax[i] = true end
    masked, tokens = online.relax_mask_for_tests(masked, tokens, relax)
end
local restored, missing = glossary.unmask(internal, tokens, masked)
if missing and missing > 0 then
    print(string.format("FAIL %s: %d placeholder(s) missing", item.shape, missing))
    os.exit(0)
end
if restored == masked then
    print(string.format("FAIL %s: the answer is unchanged", item.shape))
    os.exit(0)
end
local safe, why = online.text_is_safe(item.en, restored, lang)
if not safe then
    print(string.format("FAIL %s: %s", item.shape, tostring(why)))
else
    print(string.format("ok   %s", item.shape))
end
