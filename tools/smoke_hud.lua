-- smoke_hud.lua -- the progress HUD's line splitting, outside the game.
--
-- The HUD draws into a box the engine wraps inside, but the cursor below only advances one row: a
-- line that wrapped drew over the next one. A player saw the warning line do that ("last error: the
-- translation dropped most of the text (17 of 97 characters, target zh-cn)", about 90 characters in
-- a 330-wide box). The box is wider now and a line that is still too long is split into rows of our
-- own, where each row is drawn as its own line.
--
-- This is the pure part of that: budget in "Latin character widths", 1.8 for a Han/kana/Hangul glyph.
--
--   luajit tools/smoke_hud.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local hud = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/progress_hud.lua"))()

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-52s got %-30s want %s", pass and "ok" or "FAIL", label,
        tostring(actual), tostring(expected)))
end

local function check_true(label, value)
    check(label, value and true or false, true)
end

-- The measured case: a 90-character warning in a box that fits 60 Latin widths.
local warning = "last error: the translation dropped most of the text (17 of 97 characters, target zh-cn)"

-- The module's own rule, mirrored: a 3-byte character costs 1.8, everything else 1.
local function weight(text)
    local total = 0
    for i = 1, #text do
        local b = text:byte(i)
        if b >= 0xE0 and b < 0xF0 then
            total = total + 1.8
        elseif b < 0x80 or (b >= 0xC0 and b < 0xE0) then
            total = total + 1
        end
    end
    return total
end

local rows = hud.split_line_for_tests(warning, 60)
check_true("a long warning is split", #rows >= 2)
check_true("no row is over the budget",
    (function()
        for _, row in ipairs(rows) do
            if weight(row) > 60 then
                return false
            end
        end
        return true
    end)())
check_true("and nothing is lost", table.concat(rows, " ") == warning)

-- Short lines are left exactly as they are (the common case: progress and counts).
rows = hud.split_line_for_tests("25 translated, 149 left", 88)
check("a short line is untouched", #rows, 1)
check("and unchanged", rows[1], "25 translated, 149 left")

-- CJK counts by width, not by character: each 测试 pair is 1.8 Latin widths per glyph.
local cjk = string.rep("\230\181\139\232\175\149", 20)   -- 测试 × 20 = 40 glyphs
rows = hud.split_line_for_tests(cjk, 40)
check_true("a CJK line is split by width", #rows >= 2)
check_true("and no row is over the budget",
    (function()
        for n, row in ipairs(rows) do
            -- The last row may carry the ellipsis that says the text was cut off (MAX_ROWS).
            local limit = (n == #rows) and 41.5 or 40
            if weight(row) > limit then
                return false
            end
        end
        return true
    end)())

-- Breaking prefers a space, so words stay whole.
rows = hud.split_line_for_tests("alpha beta gamma delta epsilon zeta eta theta iota kappa", 20)
check("the first row is whole words", rows[1], "alpha beta gamma")
check_true("and does not end in a space", rows[1]:sub(-1) ~= " ")
check_true("the next row starts with the word that did not fit",
    rows[2]:sub(1, 5) == "delta")

-- A wall of text cannot grow down the screen: three rows and an ellipsis.
rows = hud.split_line_for_tests(string.rep("word ", 200), 40)
check("at most three rows", #rows, 3)
check_true("and the last one says there is more", rows[3]:find("\226\128\166", 1, true) ~= nil)

-- Degenerate input stays safe.
check("an empty line is one empty row", #hud.split_line_for_tests("", 40), 1)
check("a missing line is one empty row", #hud.split_line_for_tests(nil, 40), 1)
check("a tiny budget leaves the line alone", #hud.split_line_for_tests(warning, 2), 1)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_hud: all checks passed")
