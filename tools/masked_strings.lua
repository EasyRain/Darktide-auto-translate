-- Print the exact masked text the mod sends for the refused keys, with the placeholder legend.
--
-- The user wants to paste these into the services themselves to see which one keeps every placeholder.
-- The masked text is what goes on the wire (mask_breaks() replaces line breaks too, and the reply log
-- shows the services dropping one token), so it is reproduced here with the real glossary and the real
-- masking path.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local ffi = require("ffi")
Mods = { lua = { ffi = setmetatable({}, { __index = function(_, k)
    if k == "load" then return function() error("no core") end end
    return ffi[k]
end }) } }
package.path = here .. "/../scripts/mods/auto_translate/modules/?.lua;" .. package.path

local glossary = require("glossary")
local function slurp(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("*a"); h:close(); return s
end
local MOD_DIR = [[D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate]]
glossary.init({
    MOD_DIR = MOD_DIR,
    file_exists = function(path) return slurp(path) ~= nil end,
    load_lua_file = function(path)
        local f = loadfile(path)
        if not f then return nil, "load failed" end
        return f()
    end,
    info = function() end, warn = function() end, error = function() end,
    get = function() return false end, log = function() end,
})
assert(glossary.load())

local OPEN, CLOSE = "\226\159\166", "\226\159\167"     -- byte-wise: Lua 5.1 has no \u escapes

-- The sources come from tools/find_masked_sources.py (a Lua process cannot list a directory here:
-- io.popen is blocked in this sandbox), and this file does the masking, which needs the real glossary.
local sources = dofile(here .. "/masked-input.lua")

-- The store's `en` is the exact text the online path sends (it includes the {#color(..)} wrapper the mod
-- adds at runtime, which the localisation file does not have). The generated list is the fallback for a
-- key that has no store entry (the user deletes the ja store to re-run).
local function store_en(mod, key)
    local text = slurp(MOD_DIR .. "/translations/ja/" .. mod .. ".lua")
    if not text then return nil end
    local body = text:match('%["' .. key .. '%"] = {(.-)\n        },')
    if not body then return nil end
    local en = body:match('en = "((?:[^"\\]|\\.)*)"')
    if not en then return nil end
    local f = loadstring('return "' .. en .. '"')
    return f and f() or nil
end

for _, want in ipairs(sources) do
    want.en = store_en(want.mod, want.key) or want.en
end

local out = io.open(here .. "/masked-strings.md", "wb")
out:write("# The exact masked text sent for the refused keys\n\n")
out:write("Paste a masked line into a service and count the `" .. OPEN .. "n" .. CLOSE .. "` tokens that survive.\n")
out:write("Each one stands for text the mod puts back afterwards; a missing token is a refusal.\n\n")

for _, want in ipairs(sources) do
    local en = want.en
    if en then
        local masked, tokens = glossary.mask(en, "ja", true)
        -- the same step the online path takes (see mask_breaks in online.lua)
        local all = {}
        for i = 1, #tokens do all[i] = tokens[i] end
        masked = masked:gsub("\n", function()
            all[#all + 1] = { term = "\\n", raw = true }
            return OPEN .. (#all - 1) .. CLOSE
        end)
        out:write("## " .. want.mod .. ":" .. want.key .. "\n\n")
        out:write("source (" .. #en .. " bytes)\n\n```\n" .. en .. "\n```\n\n")
        out:write("masked (" .. #all .. " placeholders)\n\n```\n" .. masked .. "\n```\n\n")
        out:write("| placeholder | stands for |\n|---|---|\n")
        for i, token in ipairs(all) do
            local term = token.term
            if term == "\\n" or term == "\n" then term = "(line break)" end
            local ja = token.ja or token["ja"]
            out:write(string.format("| `%s%d%s` | %s%s |\n", OPEN, i - 1, CLOSE, term,
                ja and (" -> " .. ja) or ""))
        end
        out:write("\n")
        print("  " .. want.mod .. ":" .. want.key .. "  -> " .. #all .. " placeholders")
    else
        print("  " .. want.mod .. ":" .. want.key .. "  -> source not found")
    end
end
out:close()
print("  written to " .. here .. "/masked-strings.md")
