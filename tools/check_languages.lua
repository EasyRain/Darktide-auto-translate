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

print("")
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print(string.format("all languages behave: %d language(s), %d term(s) in the table", #LANGUAGES, #terms))
