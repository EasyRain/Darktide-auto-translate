-- check_languages.lua -- the recent fixes, in every language the mod can translate into.
--
-- Why: each bug behind the last releases was fixed and verified in one pair, English to Chinese -
-- markup masked before terms (0.2.7), placeholder and format-specifier parity, the truncation bar,
-- punctuation-ended terms. A fix that only holds for zh-cn is exactly what a player in German or
-- Japanese hits next, and those languages were never exercised.
--
-- This drives the *real* modules against the *real* generated data, per target language:
--
--   1. markup: "{#color(...)}Term{#reset()}" is masked and unmasked again - the tag has to survive
--      byte for byte, and the term has to come back in that language's official wording;
--   2. specifiers: a source with %s / %d / %% keeps every one of them, in order;
--   3. the guard: the string the pipeline produces passes online.text_is_safe(source, result, lang)
--      - the function that decides whether a translation is stored, whose length bar is per language;
--   4. the sweep: every term that has a value in that language goes through the same round trip.
--
-- mask() resolves a term to the target language's wording itself (that is what a token holds), so
-- "the engine echoed the placeholders back" is the normal path and needs no simulation here.
--
--   luajit tools/check_languages.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."
local mods = repo .. "/scripts/mods/auto_translate/modules"

local failures = 0
local function fail(lang, label, detail)
    failures = failures + 1
    print(string.format("FAIL %-6s %-46s %s", lang, label, tostring(detail)))
end

-- ---- the real glossary data, straight from the generated file ----
local data = assert(loadfile(repo .. "/translations/glossary.lua"))()
local terms = data.terms or {}
local by_en = {}
for _, entry in ipairs(terms) do
    if entry.en then by_en[entry.en:lower()] = entry end
end

-- ---- the real modules ----
local glossary = assert(loadfile(mods .. "/glossary.lua"))()
glossary.init({
    MOD_DIR = repo,
    file_exists = function(p)
        local f = io.open(p, "rb")
        if f then f:close() return true end
        return false
    end,
    load_lua_file = function(p)
        local c = assert(loadfile(p))
        return c()
    end,
})
local loaded, why = glossary.load(true)
if not loaded then
    io.stderr:write("the module could not load the glossary: ", tostring(why), "\n")
    os.exit(1)
end

-- online.lua is loaded for text_is_safe(); loading it needs the environment the game provides.
local ffi = require("ffi")
Mods = {
    lua = {
        ffi = setmetatable({}, {
            __index = function(_, key)
                if key == "load" then
                    return function() error("no native core in this check") end
                end
                return ffi[key]
            end,
        }),
    },
}
local online = assert(loadfile(mods .. "/online.lua"))()

-- English is not in this list: it is the language the glossary is keyed by (its "en" is the source
-- word the table matches), so it has no values to restore and nothing to test as a target.
local LANGUAGES = { "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br", "uk" }

local function value_for(entry, lang)
    if not entry then return nil end
    if lang == "zh-cn" then return entry["zh-cn"] end
    if lang == "zh-tw" then return entry["zh-tw"] end
    if lang == "pt-br" then return entry["pt-br"] end
    return entry[lang]
end

local function specifiers(text)
    local counts = {}
    for spec in text:gmatch("%%[%d%.]*[%a%%]") do
        counts[spec] = (counts[spec] or 0) + 1
    end
    return counts
end

local function same_specifiers(a, b)
    local left, right = specifiers(a), specifiers(b)
    for spec, count in pairs(left) do
        if right[spec] ~= count then return false, spec end
    end
    for spec, count in pairs(right) do
        if left[spec] ~= count then return false, spec end
    end
    return true
end

-- A Lua pattern that matches the term's text whatever its case: the glossary stores "Damage" while
-- the source text says "damage", and matching ignores case, so the expectation has to as well.
local function ci_pattern(text)
    local out = {}
    for i = 1, #text do
        local char = text:sub(i, i)
        if char:match("%a") then
            out[#out + 1] = "[" .. char:upper() .. char:lower() .. "]"
        elseif char:match("%p") or char:match("%s") then
            out[#out + 1] = "%" .. char
        else
            out[#out + 1] = char
        end
    end
    return table.concat(out)
end

local function expected_from_tokens(source, tokens)
    local replacements = {}
    for _, token in ipairs(tokens or {}) do
        if token.source and token.term and token.source ~= token.term and not token.markup then
            replacements[#replacements + 1] = token
        end
    end
    table.sort(replacements, function(a, b) return #a.source > #b.source end)
    local out = source
    for _, token in ipairs(replacements) do
        out = out:gsub(ci_pattern(token.source), (token.term:gsub("%%", "%%%%")))
    end
    return out
end

-- Did masking really put a term aside? A case whose markup was masked has masked ~= source even when
-- the term is spelled the same in the target language ("Grimoire" is "Grimoire" in German), so the
-- question has to be asked of the tokens.
local function replaced_a_term(tokens)
    for _, token in ipairs(tokens or {}) do
        if not token.markup and token.source and token.term and token.source ~= token.term then
            return true
        end
    end
    return false
end

-- ---- 1..3: the cases the bug reports were about, per language ----
local CASES = {
    { name = "tag around a term", source = "{#color(240,200,40)}Keystone{#reset()}", term = "Keystone" },
    { name = "tag, term and %d", source = "{#color(9,9,9)}Grimoire{#reset()}: {count:%d} found", term = "Grimoire" },
    { name = "specifiers only", source = "Reload %s for %d%% damage" },
    { name = "punctuation-ended term", source = "Language: Chinese (Simplified)", term = "Chinese (Simplified)" },
    { name = "a sentence around a term", source = "The Mourningstar is yours.", term = "Mourningstar" },
    { name = "two terms and a tag", source = "{#color(1,2,3)}Grimoire{#reset()} and Scripture", term = "Scripture" },
}

print("== the reported cases, per language")
for _, lang in ipairs(LANGUAGES) do
    for _, case in ipairs(CASES) do
        local masked, tokens = glossary.mask(case.source, lang, true)
        -- the placeholders survive masking: the source's own tags became placeholders, so nothing
        -- of the source's markup is left to be translated
        for tag in case.source:gmatch("{#[^}]*}") do
            if masked:find(tag, 1, true) then
                fail(lang, case.name .. " markup not masked", tag)
            end
        end

        -- a well behaved engine echoes the placeholders back
        local translated = masked
        local unmasked = glossary.unmask(translated, tokens)
        local ok, reason = online.text_is_safe(case.source, unmasked, lang)
        if not ok then
            fail(lang, case.name .. " guard", tostring(reason))
        end
        local specs_ok, bad = same_specifiers(case.source, unmasked)
        if not specs_ok then
            fail(lang, case.name .. " specifiers", tostring(bad))
        end
        -- the tags come back byte for byte: the 0.2.7 bug wrote the target language into the tag
        for tag in case.source:gmatch("{#[^}]*}") do
            if not unmasked:find(tag, 1, true) then
                fail(lang, case.name .. " tag lost", tag)
            end
        end
        if case.term then
            local wanted = value_for(by_en[case.term:lower()], lang)
            if wanted and wanted ~= case.term and not replaced_a_term(tokens) then
                fail(lang, case.name .. " nothing replaced", case.term)
            end
        end
        if unmasked ~= expected_from_tokens(case.source, tokens) then
            fail(lang, case.name .. " round trip", string.format("%q -> %q",
                expected_from_tokens(case.source, tokens), unmasked))
        end
    end
    print(string.format("  ok   %-6s %d case(s), %d term(s) usable", lang, #CASES, glossary.count(lang)))
end

-- ---- 4: every term with a value in that language ----
print("== the sweep: every term, in every language it has a value for")
for _, lang in ipairs(LANGUAGES) do
    local checked, guards, skipped = 0, 0, 0
    for _, entry in ipairs(terms) do
        local value = value_for(entry, lang)
        if entry.en and value and value ~= entry.en and #entry.en >= 3 then
            local source = "Use " .. entry.en .. " now"
            local masked, tokens = glossary.mask(source, lang, true)
            if masked ~= source then
                checked = checked + 1
                local unmasked = glossary.unmask(masked, tokens)
                if unmasked:find("⟦", 1, true) then
                    fail(lang, "unresolved placeholder", entry.en)
                end
                if not unmasked:find(value, 1, true) then
                    fail(lang, "wording missing", string.format("%s -> %q", entry.en, value))
                end
                local ok, reason = online.text_is_safe(source, unmasked, lang)
                if ok then
                    guards = guards + 1
                elseif tostring(reason):find("unchanged") or tostring(reason):find("too short") then
                    skipped = skipped + 1
                else
                    fail(lang, "guard rejected " .. entry.en, tostring(reason))
                end
            end
        end
    end
    print(string.format("  ok   %-6s %4d masked, %4d passed the guard, %3d skipped by length/unchanged",
        lang, checked, guards, skipped))
end

-- ---- 5: terms the language has no value for ----
--
-- The sweep above only walks terms that *have* a value in the language, so the other path was never
-- exercised: a term whose entry has no value for the target language (all 131 Ukrainian-less terms,
-- Aquila without German, Scab without Brazilian Portuguese...). The module is supposed to leave
-- those alone - not mask them, not invent a token, not restore an empty string - and this section
-- holds it to that with the real table (2026-09-30).
print("== the missing-value path: terms the language has no wording for")
for _, lang in ipairs(LANGUAGES) do
    local usable, missing, checked = 0, 0, 0
    for _, entry in ipairs(terms) do
        local value = value_for(entry, lang)
        if entry.en and value and value ~= "" then
            usable = usable + 1
        elseif entry.en then
            missing = missing + 1
        end
    end
    if glossary.count(lang) ~= usable then
        fail(lang, "usable count", string.format("module says %d, the file has %d",
            glossary.count(lang), usable))
    end
    for _, entry in ipairs(terms) do
        local value = value_for(entry, lang)
        if entry.en and #entry.en >= 3 and not (value and value ~= "") then
            local source = "Use " .. entry.en .. " now"
            local masked, tokens = glossary.mask(source, lang, true)
            local unmasked = glossary.unmask(masked, tokens)
            for _, token in ipairs(tokens) do
                if not token.term or token.term == "" then
                    fail(lang, "a term resolved to nothing", entry.en)
                end
                -- The bug this guards: a term with no wording for the language gets masked anyway and
                -- is "restored" to its English, which puts an English word into translated text and
                -- looks like it worked. A shorter, usable term may legitimately match inside the
                -- phrase (Attack inside Attack Speed), so the expectation is built from the tokens.
                if token.term:lower() == entry.en:lower() then
                    fail(lang, "a term with no wording was restored to its English", entry.en)
                end
            end
            if unmasked:find("⟦", 1, true) then
                fail(lang, "placeholder left by a term with no wording", entry.en)
            end
            if unmasked ~= expected_from_tokens(source, tokens) then
                fail(lang, "term with no wording round trip",
                    string.format("%q -> %q", source, unmasked))
            end
            checked = checked + 1
        end
    end
    -- one string holding both kinds: the term with a value is translated, the other keeps its English
    local mixed_ok = false
    for _, entry in ipairs(terms) do
        local value = value_for(entry, lang)
        if entry.en and #entry.en >= 4 and value and value ~= "" and value ~= entry.en then
            for _, other in ipairs(terms) do
                local absent = value_for(other, lang)
                if other.en and #other.en >= 4 and other.en ~= entry.en
                   and not (absent and absent ~= "") then
                    local source = "Use " .. entry.en .. " and " .. other.en .. " now"
                    local masked, tokens = glossary.mask(source, lang, true)
                    local unmasked = glossary.unmask(masked, tokens)
                    if unmasked:find("⟦", 1, true) then
                        fail(lang, "mixed string left a placeholder", entry.en .. " + " .. other.en)
                    elseif not unmasked:find(value, 1, true) then
                        fail(lang, "mixed string lost the translated term", entry.en)
                    elseif not unmasked:lower():find(other.en:lower(), 1, true) then
                        fail(lang, "mixed string lost the untranslated term", other.en)
                    end
                    mixed_ok = true
                    break
                end
            end
        end
        if mixed_ok then break end
    end
    print(string.format("  ok   %-6s %4d term(s) without a wording, %4d usable, mixed case %s",
        lang, missing, usable, mixed_ok and "checked" or "not applicable"))
end

-- ---- 6: the shapes a hole can take, on a glossary written for the test ----
--
-- The real table only has one shape of hole (a language key that is simply absent). A generated file
-- can also carry an empty string, and a term whose value is the English word itself - which is what
-- the game does for a proper noun it does not translate (Aquila in German). Both have to behave:
-- empty means "not usable", the same-as-English one is usable and protects the word from the engine.
print("== the shapes of a hole: absent key, empty string, same as English")
local scratch = os.getenv("TEMP") or "."
scratch = scratch .. "\\at_lang_holes"
os.execute('mkdir "' .. scratch .. '" 2>nul')
os.execute('mkdir "' .. scratch .. '\\translations" 2>nul')
local fh = assert(io.open(scratch .. "/translations/glossary.lua", "w"))
fh:write([[
return { terms = {
    { en = "Absent Term", ["zh-cn"] = "缺席术语" },
    { en = "Empty Term",  ["zh-cn"] = "空术语", ["ja"] = "" },
    { en = "Same Term",   ["ja"] = "Same Term", ["zh-cn"] = "同名术语" },
    { en = "Full Term",   ["ja"] = "フル", ["zh-cn"] = "完整术语" },
} }
]])
fh:close()
local holes = assert(loadfile(mods .. "/glossary.lua"))()
holes.init({
    MOD_DIR = scratch,
    file_exists = function(p)
        local f = io.open(p, "rb")
        if f then f:close() return true end
        return false
    end,
    load_lua_file = function(p)
        local c = assert(loadfile(p))
        return c()
    end,
})
local ok, why = holes.load(true)
if not ok then
    fail("-", "the test glossary did not load", tostring(why))
else
    if holes.count("ja") ~= 2 then
        fail("ja", "holes: usable count", string.format(
            "expected 2 (same-as-English + real value; the absent key and the empty string are not usable), got %d",
            holes.count("ja")))
    end
    for _, case in ipairs({
        { lang = "ja", source = "Absent Term", expect = "Absent Term", why = "absent key", masked = false },
        { lang = "ja", source = "Empty Term",  expect = "Empty Term",  why = "empty string", masked = false },
        { lang = "ja", source = "Same Term",   expect = "Same Term",   why = "same as English", masked = true },
        { lang = "ja", source = "Full Term",   expect = "フル",         why = "a real value", masked = true },
        { lang = "de", source = "Full Term",   expect = "Full Term",   why = "language with no values", masked = false },
    }) do
        local masked, tokens = holes.mask(case.source, case.lang, true)
        local unmasked = holes.unmask(masked, tokens)
        if case.masked and #tokens == 0 then
            fail(case.lang, "holes: nothing was masked (" .. case.why .. ")", case.source)
        elseif not case.masked and #tokens > 0 then
            fail(case.lang, "holes: masked what has no wording (" .. case.why .. ")", case.source)
        end
        if unmasked:find("⟦", 1, true) then
            fail(case.lang, "holes: placeholder left (" .. case.why .. ")", case.source)
        elseif unmasked ~= case.expect then
            fail(case.lang, "holes: " .. case.why, string.format("%q -> %q (wanted %q)",
                case.source, unmasked, case.expect))
        end
    end
    local masked, tokens = holes.mask("Full Term and Absent Term", "ja", true)
    local unmasked = holes.unmask(masked, tokens)
    if unmasked ~= "フル and Absent Term" then
        fail("ja", "holes: mixed string", string.format("%q", unmasked))
    end
end

print("")
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print(string.format("all languages behave: %d language(s), %d term(s) in the table", #LANGUAGES, #terms))
