-- Run the real is_asset_entry over the real strings of the installed mods.
--
-- Not invented samples: the user pointed at Alfs_DMF_Extensions as the main source of the extra colour
-- material, and 48 files across the mods carry {#color}/{#font} markup. This asks what the rule does
-- with them - what is skipped as an asset name, and whether anything swatch-shaped is still being sent
-- to a service (which is what got refused and parked in the run that stopped).
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local modules = here .. "/../scripts/mods/auto_translate/modules"

local ffi = require("ffi")
Mods = { lua = { ffi = setmetatable({}, { __index = function(_, key)
    if key == "load" then return function() error("no native core") end end
    return ffi[key]
end }) } }
local online = assert(loadfile(modules .. "/online.lua"))()

local is_asset = online.is_asset_entry_for_tests
local MODS = arg[1] or [[D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods]]
local OUT = here .. "/asset-check.txt"

local function popen_lines(command)
    local pipe = io.popen(command)
    if not pipe then return {} end
    local out = {}
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
    return out
end

-- every .lua under the mods folder except this mod's own
local files = popen_lines('dir /b /s "' .. MODS .. '\\*.lua"')
local report, total, skipped_total, sent_total = {}, 0, 0, 0
local still_sent = {}

for _, path in ipairs(files) do
    if not path:find("auto_translate", 1, true) and not path:find("dsh", 1, true) then
        local handle = io.open(path, "rb")
        if handle then
            local text = handle:read("*a")
            handle:close()
            local strings = {}
            for en in text:gmatch('en%s*=%s*"((?:[^"\\]|\\.)*)"') do
                strings[#strings + 1] = en
            end
            if #strings > 0 then
                local skipped, sent, tagged = 0, 0, 0
                for _, en in ipairs(strings) do
                    total = total + 1
                    if is_asset(en) then
                        skipped = skipped + 1
                        skipped_total = skipped_total + 1
                    else
                        sent = sent + 1
                        sent_total = sent_total + 1
                        if en:find("{#color") or en:find("{#font") then
                            tagged = tagged + 1
                            still_sent[#still_sent + 1] = en
                        end
                    end
                end
                if skipped > 0 or tagged > 0 then
                    report[#report + 1] = { path = path, skipped = skipped, sent = sent, tagged = tagged }
                end
            end
        end
    end
end

table.sort(report, function(a, b) return a.tagged > b.tagged end)

local out = io.open(OUT, "w")
out:write(string.format(
    "strings seen: %d  |  skipped as asset: %d  |  sent: %d  |  of the sent, still carry a tag: %d\n\n",
    total, skipped_total, sent_total, #still_sent))
out:write("== files with something to say (tagged_but_sent desc) ==\n")
for i = 1, math.min(20, #report) do
    local r = report[i]
    out:write(string.format("  skipped=%-4d sent=%-4d tagged_but_sent=%-4d %s\n",
        r.skipped, r.sent, r.tagged, r.path:sub(-70)))
end
out:write("\n== still sent and tagged (first 60) ==\n")
for i = 1, math.min(60, #still_sent) do
    out:write(string.format("  %s\n", still_sent[i]:sub(1, 120)))
end
out:close()
print("  total=%d skipped=%d sent=%d tagged_but_sent=%d"):format(total, skipped_total, sent_total, #still_sent)
print("  report -> " .. OUT)
