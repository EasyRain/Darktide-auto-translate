-- check_zh_variants.lua -- how much simplified Chinese leaked into a zh-tw/zh-hk store?
--
-- NLLB (and every other model we have looked at) is inconsistent about Chinese
-- variants: the same run produced 自動馬克斯掌握 for one key and 自动犧牲武器 for the
-- next, even though the target was zh-tw. That is worth measuring rather than
-- remembering, because it is the one translation defect a converter (OpenCC's
-- s2twp) can fix exactly, with no model swap and no network.
--
-- The check is deliberately conservative: it looks for characters that exist in the
-- simplified set but not in traditional Chinese, so punctuation, proper nouns and
-- characters shared by both (后/後, 只/隻 ...) never count. Every hit is therefore a
-- real simplified character, and the true number of affected entries is higher.
--
--   luajit tools/check_zh_variants.lua <translations/zh-tw>
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local util = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/util.lua"))()
util.MOD_DIR = here .. "/.."

-- The character set lives in its own file so the model comparison uses exactly the
-- same definition of "simplified leaked in" as this tool.
local SIMPLIFIED = {}
for _, c in ipairs(assert(loadfile(here .. "/zh_simplified_chars.lua"))()) do
    SIMPLIFIED[c] = true
end

local dir = arg[1]
if not dir then
    io.stderr:write("usage: luajit tools/check_zh_variants.lua <translations/zh-tw>\n")
    os.exit(1)
end

local function list_files(path)
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

local files, total, affected, missing = 0, 0, 0, 0
local examples = {}

for _, name in ipairs(list_files(dir)) do
    if name:match("%.lua$") then
        local data, err = util.load_lua_file(dir .. "/" .. name)
        if type(data) == "table" and type(data.entries) == "table" then
            files = files + 1
            local hit, seen = 0, 0
            for key, entry in pairs(data.entries) do
                if type(entry) == "table" and type(entry.text) == "string" then
                    total = total + 1
                    seen = seen + 1
                    -- Character by character through find(): Lua 5.1 strings are bytes,
                    -- so text:sub(i, i) would compare a single byte and never match.
                    local bad, chars = false, {}
                    for c in pairs(SIMPLIFIED) do
                        if entry.text:find(c, 1, true) then
                            chars[#chars + 1] = c
                            bad = true
                        end
                    end
                    if bad then
                        hit = hit + 1
                        affected = affected + 1
                        if #examples < 12 then
                            table.sort(chars)
                            examples[#examples + 1] = string.format("%s [%s] %s -> %s",
                                key, table.concat(chars, " "), entry.en or "", entry.text)
                        end
                    end
                end
            end
            print(string.format("%-40s %4d entr%s, %4d with simplified characters",
                name, seen, seen == 1 and "y" or "ies", hit))
        elseif err then
            missing = missing + 1
        end
    end
end

print(string.format("\n%d file(s), %d entr%s, %d (%d%%) contain simplified-only characters",
    files, total, total == 1 and "y" or "ies", affected,
    total > 0 and math.floor(affected * 100 / total + 0.5) or 0))
for _, line in ipairs(examples) do
    print("  " .. line)
end
