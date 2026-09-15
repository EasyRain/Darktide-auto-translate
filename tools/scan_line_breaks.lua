-- scan_line_breaks.lua -- how many English sources actually contain a line break?
--
-- The queue has to translate text like "first line\nsecond line", and a model can
-- easily drop the break, merge the two lines or translate the two-character escape
-- "\n" as if the letter n were a word. Before splitting lines apart it is worth
-- knowing which form really occurs in the deployed data:
--
--   * a real newline character            (Lua source: "a\nb")
--   * a literal backslash + n             (Lua source: "a\\nb") - the game expands it
--     later, so it must survive translation exactly as written
--   * a literal backslash + r + backslash + n
--
--   luajit tools/scan_line_breaks.lua <translations-dir> [lang ...]
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local util = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/util.lua"))()
util.MOD_DIR = here .. "/.."

local root = arg[1]
if not root then
    io.stderr:write("usage: luajit tools/scan_line_breaks.lua <translations-dir> [lang ...]\n")
    os.exit(1)
end

local function list_dir(path)
    local names = {}
    local p = io.popen('dir /b "' .. path .. '" 2>nul')
    if p then
        for line in p:lines() do
            names[#names + 1] = line
        end
        p:close()
    end
    return names
end

local langs = {}
for i = 2, #arg do
    langs[#langs + 1] = arg[i]
end
if #langs == 0 then
    for _, name in ipairs(list_dir(root)) do
        if name:match("^%a%a") then
            langs[#langs + 1] = name
        end
    end
end

local counts = { newline = 0, escape_n = 0, escape_rn = 0, cr = 0 }
local examples, total = {}, 0
local seen = {}

for _, lang in ipairs(langs) do
    for _, name in ipairs(list_dir(root .. "/" .. lang)) do
        if name:match("%.lua$") then
            local data = util.load_lua_file(root .. "/" .. lang .. "/" .. name)
            if type(data) == "table" and type(data.entries) == "table" then
                for _, entry in pairs(data.entries) do
                    if type(entry) == "table" and type(entry.en) == "string" and entry.en ~= "" then
                        total = total + 1
                        local en = entry.en
                        local kind = nil
                        if en:find("\n", 1, true) then
                            kind = "newline"
                        elseif en:find("\\r\\n", 1, true) then
                            kind = "escape_rn"
                        elseif en:find("\\n", 1, true) then
                            kind = "escape_n"
                        elseif en:find("\r", 1, true) then
                            kind = "cr"
                        end
                        if kind then
                            counts[kind] = counts[kind] + 1
                            local key = kind .. "\0" .. en
                            if not seen[key] and #examples < 15 then
                                seen[key] = true
                                examples[#examples + 1] = string.format("[%s] %s", kind,
                                    en:gsub("\r", "\\r"):gsub("\n", "\\n"))
                            end
                        end
                    end
                end
            end
        end
    end
end

print(string.format("%d English string(s) across %d language dir(s)", total, #langs))
for _, kind in ipairs({ "newline", "escape_n", "escape_rn", "cr" }) do
    print(string.format("  %-10s %d", kind, counts[kind]))
end
print("\nexamples:")
for _, line in ipairs(examples) do
    print("  " .. line)
end
