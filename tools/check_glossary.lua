-- check_glossary.lua -- load the generated glossary and verify it is usable.
--
-- The file is generated Lua, so the only honest check is to load it with LuaJIT and
-- look at what came out: a stray quote or a bad escape produces a mod that silently
-- has no glossary at all.
local path = arg[1] or "../repos/auto_translate/translations/glossary.lua"

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("glossary does not parse: ", tostring(err), "\n")
    os.exit(1)
end

local ok, data = pcall(chunk)
if not ok or type(data) ~= "table" or type(data.terms) ~= "table" then
    io.stderr:write("glossary has no terms table: ", tostring(data), "\n")
    os.exit(1)
end

local terms = data.terms
print(string.format("%s: %d terms", path, #terms))

local by_lang, with_ar, ui = {}, 0, 0
local wanted = { "Right", "Left", "Center", "Top", "Bottom", "Apply", "Cancel", "Settings", "Hotkey" }
local seen = {}

for _, item in ipairs(terms) do
    if type(item) == "table" and type(item.en) == "string" then
        seen[item.en] = item
        local langs = 0
        for k, v in pairs(item) do
            if k ~= "en" and type(v) == "string" and v ~= "" then
                langs = langs + 1
                by_lang[k] = (by_lang[k] or 0) + 1
            end
        end
        if item.ar then with_ar = with_ar + 1 end
    end
end

local missing = 0
for _, word in ipairs(wanted) do
    local item = seen[word]
    if not item then
        missing = missing + 1
        print(string.format("MISSING %s", word))
    else
        print(string.format("%-10s zh-tw=%-8s ja=%-6s ar=%-8s",
            word, item["zh-tw"] or "-", item.ja or "-", item.ar or "-"))
    end
end

print("languages present: " .. table.concat((function()
    local keys = {}
    for k in pairs(by_lang) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end)(), ", "))
print(string.format("terms with Arabic: %d, missing expected: %d", with_ar, missing))
os.exit(missing == 0 and 0 or 1)
