-- glossary.lua — official term protection for machine translation.
--
-- Machine translators mistranslate game terminology ("Keystone" becomes
-- "corner stone", "Blitz" becomes "lightning war"). Known terms are therefore
-- replaced by placeholders before the text is translated, and put back as the
-- official translation of the target language afterwards.
--
-- Data file: ../mods/auto_translate/translations/glossary.lua
--     return {
--         terms = {
--             { en = "Keystone", ["zh-cn"] = "楔石", ja = "キーストーン", ko = "키스톤" },
--         },
--     }
-- A term is only used when the target language has a value for it, so partial
-- tables are fine and nothing is invented.
local M = {}

local util
function M.init(u)
    util = u
end

-- LuaJIT is Lua 5.1: no \u{...} escapes, the placeholder characters are written
-- literally (the file itself is UTF-8).
local PLACEHOLDER_OPEN = "⟦"
local PLACEHOLDER_CLOSE = "⟧"

local WIRE_GLYPHS = {}
do
    local chunks = {
        { 0x2460, 20 },     -- (1) .. (20)   circled digits
        { 0x3251, 15 },     -- (21) .. (35)  circled numbers on black square
        { 0x32B1, 15 },     -- (36) .. (50)  circled numbers on black square, higher
    }
    for _, chunk in ipairs(chunks) do
        for i = 0, chunk[2] - 1 do
            -- Lua 5.1 has no \u escapes: build the UTF-8 bytes by hand
            local code = chunk[1] + i
            local bytes
            if code < 0x800 then
                bytes = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
            else
                bytes = string.char(0xE0 + math.floor(code / 0x1000),
                                    0x80 + math.floor(code / 0x40) % 0x40,
                                    0x80 + code % 0x40)
            end
            WIRE_GLYPHS[#WIRE_GLYPHS + 1] = bytes
        end
    end
end

local WIRE_SET = {}
for i = 1, #WIRE_GLYPHS do
    WIRE_SET[WIRE_GLYPHS[i]] = true
end

-- The glyphs a request must not use as placeholders, because the text itself contains them: a game
-- string with a real circled number in it would otherwise be read back as one of ours on the return
-- trip and substituted with another token's term. Accepts a flat token list or one list per batch part.

-- Terms that are also ordinary English words, and are therefore only masked when the whole string
-- is that label.
--
-- Masking is a global replacement, so a term that doubles as prose turns a sentence into the
-- wording of a button: measured with the full list, "back of the head" became two placeholders
-- ("Back" and "Head") and "close range" two more. Those two were constructed - scanning the real
-- stores (124 entries) found four cases, all of the word "show", and none of them wrong
-- ("Show bubble health" -> 显示气泡生命值 is the label doing its job; "Choose what to show for the
-- timer" reads slightly stiff but says the right thing). So this is insurance for text that has
-- not been written yet, not a repair: the list is short, explicit and about words that a settings
-- screen and a sentence both use.
--
-- A whole label still masks - "Back" alone, "Back:" - and every name (Melee, Armour Piercing,
-- German, Relic) is unaffected: a name means the same thing wherever it stands.
local LABEL_ONLY_WORDS = {}
for _, word in ipairs({
    -- position and direction
    "back", "close", "front", "left", "right", "top", "bottom", "center", "up", "down", "in",
    "out", "above", "below", "near", "far", "over", "under", "inside", "outside",
    -- state and choice
    "on", "off", "all", "none", "default", "done", "applied", "selected", "enabled", "disabled",
    -- "other" and "confirm" came in with the hand written labels for the same three words: real mod
    -- text uses both in prose ("Compared against the other side", "Confirm Name (Enter)"), so they are
    -- masked only where the whole string is the label.
    "other", "confirm",
    -- what a settings row does
    "apply", "cancel", "reset", "save", "load", "open", "show", "hide", "select", "search",
    "sort", "order", "add", "edit", "delete", "remove", "clear", "test", "use", "set", "toggle",
    -- generic labels for other things
    "name", "title", "type", "mode", "size", "value", "level", "key", "head", "range", "count",
    "total", "amount", "number", "text", "info", "help", "unknown",
    -- words the game uses as a label but which also appear in ordinary text. Both came in with the
    -- collected key names: "Space" is the keybind (空格键 - but "Space Marine" is not a keyboard),
    -- and "Blocked" is the game's wording for a blocked player (已屏蔽 - but "damage blocked" is a
    -- number, not a block list). They are masked only where the whole string is the label.
    "space", "blocked",
    -- short words that are also things you do in combat
    "charge", "guard", "block", "push", "pull", "hold", "release", "burst", "delay", "dodge",
}) do
    LABEL_ONLY_WORDS[word] = true
end

-- True when the string is that term and nothing else (surrounding space and one trailing colon are
-- still a label: mods write "Relic:" as readily as "Relic").
local function is_a_label(text, term)
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    trimmed = trimmed:gsub("[:：%.]+$", ""):gsub("%s+$", "")
    return trimmed:lower() == term:lower()
end

local terms = nil
local by_language = {}

function M.placeholder_open()
    return PLACEHOLDER_OPEN
end

local function build_index()
    by_language = {}
    for _, item in ipairs(terms) do
        if type(item) == "table" and type(item.en) == "string" and item.en ~= "" then
            for lang, value in pairs(item) do
                if lang ~= "en" and type(value) == "string" and value ~= "" then
                    local list = by_language[lang]
                    if not list then
                        list = {}
                        by_language[lang] = list
                    end
                    list[#list + 1] = { en = item.en, term = value }
                end
            end
        end
    end
    -- longest source term first, so "Hive Scum" is matched before "Hive"
    for _, list in pairs(by_language) do
        table.sort(list, function(a, b)
            return #a.en > #b.en
        end)
    end
end

function M.load(force)
    if terms and not force then
        return true
    end
    terms = {}
    by_language = {}

    local path = util.MOD_DIR .. "/translations/glossary.lua"
    if not util.file_exists(path) then
        return false, "glossary.lua not found"
    end

    local data, err = util.load_lua_file(path)
    if type(data) ~= "table" or type(data.terms) ~= "table" then
        return false, "glossary.lua has no 'terms' table (" .. tostring(err) .. ")"
    end

    terms = data.terms
    build_index()
    return true
end

function M.total()
    if not terms then M.load() end
    return #(terms or {})
end

-- How many terms are usable for a language.
function M.count(lang)
    if not terms then M.load() end
    local list = by_language[lang]
    return list and #list or 0
end

function M.languages()
    if not terms then M.load() end
    local out = {}
    for lang in pairs(by_language) do
        out[#out + 1] = lang
    end
    table.sort(out)
    return out
end

local function escape_pattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- "Veteran" -> "[Vv][Ee][Tt][Ee][Rr][Aa][Nn]" (ASCII letters match either case)
local function loose_pattern(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if c:match("%a") then
            out[#out + 1] = "[" .. c:upper() .. c:lower() .. "]"
        else
            out[#out + 1] = escape_pattern(c)
        end
    end
    return table.concat(out)
end

-- Whether the byte next to a match means the match is part of a longer word.
--
-- The rule depends on the term's own script, which is the only way to get both cases right:
--
--   * an ASCII term ("Ammo") is a word when its neighbours are ASCII word bytes; a CJK
--     neighbour does not block it, because "语言 Ammo" and "语言Ammo" are how mixed text is
--     actually written.
--   * a term in another script ("日本語") is a word only when its neighbours are not part of
--     that script either, so it is never matched in the middle of a longer run - "中文" must
--     not match inside "简体中文".
--
-- Lua's %w is ASCII-only in the C locale; multi-byte characters have to be recognised by
-- their bytes (every byte of a UTF-8 sequence is >= 128).
local function makes_it_a_longer_word(byte, term_is_multibyte)
    if not byte or byte == "" then
        return false
    end
    if byte:match("%w") then
        return true
    end
    return term_is_multibyte and byte:byte() >= 128
end

-- Rich-text markup has to be masked for the same reason glossary terms are, and
-- for one more: given "{#color(14,127,120)}Citadel Coelia Greenshade{#reset()}"
-- the free services hand the whole string straight back untranslated. Masking the
-- tags leaves plain words to translate and puts the original markup back after.
--   {#color(240,248,255)}  {#reset()}  {damage:%s}
local MARKUP = "{[#%w][^{}]*}"

-- Replaces known terms of `lang` with placeholders.
-- `mask_markup` defaults to true; pass false for a provider that keeps rich-text
-- markup intact on its own (DeepL does), so no pointless placeholders are added
-- that it could then drop.
-- Returns the masked text and the token list (tokens[i].term is the replacement).
function M.mask(text, lang, mask_markup)
    if type(text) ~= "string" or text == "" then
        return text, {}
    end
    if not terms then M.load() end

    local tokens = {}
    local result = text

    -- Rich-text markup is taken out of the text *before* the terms are masked, and that order is
    -- the whole point: "Color" is itself a UI term, so masking terms first turned
    -- "{#color(151,151,151)}" into "{#⟦0⟧(151,151,151)}" - and unmask then wrote the Chinese word
    -- into the *tag name* ({#颜色(151,151,151)}), a broken tag that only becomes visible when the
    -- text is drawn. Masking the tags first also hides their contents from the term pass, which is
    -- right: a tag is markup, not text the player reads.
    --
    -- With mask_markup the tags become tokens, and the caller's unmask puts them back. Without it
    -- (a provider trusted to keep markup on its own) the tags are held aside under a
    -- control-character sentinel that no term pattern can match, then restored verbatim before
    -- returning - the reply then carries the original tags, which is what "trusted with markup"
    -- has to mean.
    local held = nil
    if mask_markup == false then
        held = {}
        result = result:gsub(MARKUP, function(tag)
            held[#held + 1] = tag
            return "\1" .. #held .. "\1"
        end)
    else
        local seen_tags = {}
        result = result:gsub(MARKUP, function(tag)
            local index = seen_tags[tag]
            if not index then
                tokens[#tokens + 1] = { term = tag, source = tag, markup = true }
                index = #tokens
                seen_tags[tag] = index
            end
            return PLACEHOLDER_OPEN .. (index - 1) .. PLACEHOLDER_CLOSE
        end)
    end

    local list = type(lang) == "string" and by_language[lang] or nil
    if list and #list > 0 then
        for _, item in ipairs(list) do
            -- A handful of terms are also ordinary English words, and masking is a global
            -- replacement: "back" inside "back of the head" used to be replaced by the word a
            -- button shows for going back. Those words are masked only where the string *is* the
            -- label, which is where the benefit lives - a lone "Back" handed to a model is exactly
            -- what it gets wrong. Everything else (names: "Melee", "Armour Piercing", "German")
            -- still masks wherever it appears, because a name means the same thing in any
            -- position. See LABEL_ONLY_WORDS for the list and why it is short.
            local as_label_only = LABEL_ONLY_WORDS[item.en:lower()]
            if not (as_label_only and not is_a_label(text, item.en)) then
                -- The whole-word rule is checked on the two bytes *around* the match, not with
                -- the %f frontier: a frontier at the end of the pattern fails for any term that
                -- ends in punctuation ("Chinese (Simplified)", "Portuguese (Brazil)") and for
                -- every term in a non-Latin script, because it asks the term's own last byte to
                -- be a word byte. Measured: with the frontier, "Chinese (Simplified)" came back
                -- as "中文 (Simplified)" - the shorter "Chinese" term matched inside it - and
                -- "日本語" was never protected at all.
                local pattern = "()" .. loose_pattern(item.en) .. "()"
                local multibyte = item.en:find("[\128-\255]") ~= nil
                local token_index = nil
                result = result:gsub(pattern, function(from_pos, to_pos)
                    if makes_it_a_longer_word(result:sub(from_pos - 1, from_pos - 1), multibyte)
                        or makes_it_a_longer_word(result:sub(to_pos, to_pos), multibyte) then
                        return nil      -- part of a longer word: leave it alone
                    end
                    if not token_index then
                        tokens[#tokens + 1] = { term = item.term, source = item.en }
                        token_index = #tokens
                    end
                    return PLACEHOLDER_OPEN .. (token_index - 1) .. PLACEHOLDER_CLOSE
                end)
            end
        end
    end

    if held then
        result = result:gsub("\1(%d+)\1", function(index)
            return held[tonumber(index)] or ""
        end)
    end

    -- A wire glyph that was in the text itself (a real circled number in a game string) is masked like a
    -- term, so the wire layer cannot confuse it with one of ours. to_wire() then skips it, which is what
    -- keeps the two apart: the source glyph goes out as itself and comes back as itself.
    local seen_glyphs = {}
    for i = 1, #WIRE_GLYPHS do
        local glyph = WIRE_GLYPHS[i]
        if result:find(glyph, 1, true) then
            local index = seen_glyphs[glyph]
            if not index then
                tokens[#tokens + 1] = { term = glyph, source = glyph, glyph = true }
                index = #tokens
                seen_glyphs[glyph] = index
            end
            result = result:gsub(glyph, PLACEHOLDER_OPEN .. (index - 1) .. PLACEHOLDER_CLOSE)
        end
    end

    -- The same treatment for a bracketed single letter, which is one of *our* label spellings as well as
    -- something the game writes itself: "[X]" is a hotkey label. Without this the label pool claimed it,
    -- to_internal() converted it back to an internal placeholder that no token owned, and unmask dropped
    -- it - measured: "{#color(144,155,136)}[X]{#reset()}" was stored as "{#color(144,155,136)}{#reset()}".
    -- Masking it means the model never sees it, and wire_reserved() keeps the pool away from it.
    do
        local labels = {}
        for label in result:gmatch("%[[a-zA-Z]%]") do
            labels[label] = true
        end
        for label in pairs(labels) do
            local index = #tokens + 1
            tokens[index] = { term = label, source = label, glyph = true }
            -- escaped: a label is a Lua character class, not a literal
            result = result:gsub(label:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"),
                                 PLACEHOLDER_OPEN .. (index - 1) .. PLACEHOLDER_CLOSE)
        end
    end

    return result, tokens
end

-- A space that sits between two Han/Kana characters is wrong, and the placeholder is what put it
-- there: a service sees `⟦0⟧` as a Latin-shaped token and separates it from the text around it, so
-- `Show decimals` came back as `显示 小数位` and `Default Cooldown Color` as `默认 冷却时间 颜色`.
-- Measured on a real store: 15 of the 109 entries in one file carried such a space.
--
-- The rule is deliberately narrow, because it is a typographic fix and not a rewrite:
--   * only a space *directly* next to a term we just restored is removed, and only when the term
--     itself continues in the same script - `FPS 伤害` keeps its space, which Chinese typography
--     wants, while `显示 小数位` loses one;
--   * the neighbour has to belong to a script that does not separate words with spaces, checked
--     by *code point* rather than by the leading byte. The obvious shortcut (three-byte sequences
--     E3..ED) is wrong: Hangul syllables are U+AC00..U+D7AF, which UTF-8 encodes with the same
--     leading bytes, and Korean does separate its words with spaces - leaving that range out is
--     exactly what keeps Korean intact. Latin and Cyrillic targets have no such neighbours at all,
--     so nothing there is touched either.
--
-- The list is by script rather than "CJK", so a language added later is already right instead of
-- needing this function edited: Chinese and Japanese are the ones this mod offers today, and the
-- Southeast Asian scripts are the same shape of problem (Thai, Lao, Myanmar and Khmer write without
-- spaces between words). Ranges above U+FFFF (CJK extension B and beyond) are not listed: they are
-- rare in game text and would need the four-byte form.
-- Any three-byte character, used only as a cheap prefilter: the decision is the code-point list in
-- is_unspaced_part(). It used to start at E3 (U+3000), which silently excluded Thai and the other Southeast
-- Asian scripts at U+0E00..U+17FF - their leading byte is E0..E1. Widening it does not add false removals:
-- Devanagari and friends fall in the same byte range and are rejected by the code-point check, not here.
local UNSPACED_3BYTE = "[\224-\237][\128-\191][\128-\191]"

local function is_unspaced_part(part)
    if type(part) ~= "string" or #part ~= 3 then
        return false
    end

    local b1, b2, b3 = part:byte(1), part:byte(2), part:byte(3)
    if not (b1 and b2 and b3) or b1 < 0xE0 or b1 > 0xEF then
        return false
    end
    if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then
        return false
    end

    local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    return (cp >= 0x0E00 and cp <= 0x0E7F)      -- Thai
        or (cp >= 0x0E80 and cp <= 0x0EFF)      -- Lao
        or (cp >= 0x1000 and cp <= 0x109F)      -- Myanmar
        or (cp >= 0x1780 and cp <= 0x17FF)      -- Khmer
        or (cp >= 0x3000 and cp <= 0x30FF)      -- CJK punctuation and kana
        or (cp >= 0x3400 and cp <= 0x4DBF)      -- unified ideographs, extension A
        or (cp >= 0x4E00 and cp <= 0x9FFF)      -- unified ideographs
        or (cp >= 0xF900 and cp <= 0xFAFF)      -- compatibility ideographs
        -- Hangul (U+AC00..U+D7AF) is deliberately absent: Korean separates its words with spaces.
end

-- Removes a space the service added between a restored term and a neighbouring character of a script
-- that does not separate words with spaces. Returning nil from the gsub function leaves that match untouched.
-- True for the game's own rich-text markup ("{#color(..)}", "{#reset()}", "{#font(..)}"). Such a token is
-- invisible on screen, so a space beside it is really a space beside whatever the tag separates - and if that
-- neighbour is Chinese, the space is wrong. The term branches below cannot see this: their test is the first
-- and last three bytes of the token, and a tag starts with "{#".
local function is_markup(term)
    return term:sub(1, 2) == "{#" and term:sub(-1) == "}"
end

-- An ASCII comma or full stop between Chinese characters, which the services emit freely ("任务等级 40,在那里").
-- Chinese typography puts no space beside a comma or a full stop, whichever half of the world the punctuation
-- came from.
local ASCII_PUNCT = "[,%.!%;:%?]"

local function tighten_script_boundary(text, term)
    local escaped = escape_pattern(term)

    if is_markup(term) then
        -- The tag followed by a space and Chinese: drop the space (the tag itself stays).
        text = text:gsub(escaped .. " +(" .. UNSPACED_3BYTE .. ")", function(neighbour)
            if is_unspaced_part(neighbour) then
                return term .. neighbour
            end
            return nil
        end)
        -- Chinese, a space, then the tag.
        text = text:gsub("(" .. UNSPACED_3BYTE .. ") +" .. escaped, function(neighbour)
            if is_unspaced_part(neighbour) then
                return neighbour .. term
            end
            return nil
        end)
        return text
    end

    if is_unspaced_part(term:sub(-3)) then
        -- The whole match starts at the term, so the term has to be part of the replacement:
        -- returning just the neighbour deletes it.
        text = text:gsub(escaped .. " +(" .. UNSPACED_3BYTE .. ")", function(neighbour)
            if is_unspaced_part(neighbour) then
                return term .. neighbour
            end
            return nil
        end)
    end

    if is_unspaced_part(term:sub(1, 3)) then
        text = text:gsub("(" .. UNSPACED_3BYTE .. ") +" .. escaped, function(neighbour)
            if is_unspaced_part(neighbour) then
                return neighbour .. term
            end
            return nil
        end)
    end

    return text
end

-- Applies the same boundary rule to a finished translation, for a given target language: it
-- removes the space a service left between a glossary term and a neighbouring character of the
-- same script. unmask() does this for the terms it has just restored; this is for text restored
-- before the rule existed - a store written by an older build - which
-- tools/fix_term_spacing.lua rewrites in place.
function M.tighten(text, lang)
    if type(text) ~= "string" or text == "" then
        return text
    end

    for _, entry in ipairs(by_language[lang] or {}) do
        if type(entry.term) == "string" and entry.term ~= "" then
            text = tighten_script_boundary(text, entry.term)
        end
    end

    return text
end

-- The wire form of a placeholder: a single circled digit instead of a bracketed number.
--
-- The bracketed form (U+27E6/U+27E7, "mathematical white square brackets") is what the services mangle:
-- measured, yandex answered with "mark2mark" where the source had a placeholder, and bing dropped the
-- opening bracket when the token sat next to a literal digit ("Set to {0}0{1}"). A circled digit is one
-- glyph, looks like a number (which translators pass through), and has no pair to split.
--
-- It is a *wire* form only: internally the placeholders stay "\u27e6n\u27e7", so every guard, store check
-- and test keeps working on one shape. The two functions below convert at the boundary.
--
-- 51 tokens cover any string this mod has ever masked (the largest tooltip carries eight); a string that
-- needs more keeps the internal form, which is the behaviour everything had before.
function M.wire_reserved(tokens)
    local reserved = {}
    local function reserve(list)
        if type(list) ~= "table" then
            return
        end
        for i = 1, #list do
            local term = list[i] and list[i].term
            if type(term) == "string" and (WIRE_SET[term] or term:match("^%[[a-zA-Z]%]$")) then
                reserved[term] = true
            end
        end
    end
    if type(tokens) == "table" then
        if type(tokens[1]) == "table" and tokens[1].term ~= nil then
            reserve(tokens)
        else
            for i = 1, #tokens do
                reserve(tokens[i])
            end
        end
    end
    return reserved
end

-- A wire token goes into a gsub, so it has to be a literal pattern. The circled glyphs need nothing, but a
-- bracketed label is a Lua *character class* ("[a]" matches the letter a) - measured by the round-trip:
-- "Set to [a] 0[b] Reload Speed" came back as "Set to [⟦0⟧] 0[⟦1⟧] Relo⟦0⟧d Speed",
-- with the a of "Reload" replaced as well.
local function literal_pattern(token)
    return (token:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- The glyphs left for this request, in order.
local function wire_pool(reserved)
    local pool = {}
    for i = 1, #WIRE_GLYPHS do
        if not (reserved and reserved[WIRE_GLYPHS[i]]) then
            pool[#pool + 1] = WIRE_GLYPHS[i]
        end
    end
    return pool
end

-- Bracketed labels, for a service that rewrites single glyphs.
--
-- Measured 2026-10-12 against a self-hosted LibreTranslate 1.9.6: `①` comes back as `1`, `Ⓐ` comes back as
-- `B` with the first one dropped, `⟦0⟧` loses its brackets, `#0#` and `@0@` come back split - and `[a]`
-- comes back byte for byte, even when it sits right next to a digit. The circled digits were chosen in
-- 0.3.8 because the services then kept them and because a marker *adjacent to a digit* was the fragile
-- shape; a bracketed label ends with `]`, so it cannot be adjacent to a digit at all, and it has 52+
-- spellings ([a]..[z], [A]..[Z], then [aa].. ).
--
-- Only the providers that were measured to need it use this (see wire_variant in modules/online.lua).
local WIRE_LABELS = {}
do
    local letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for i = 1, #letters do
        WIRE_LABELS[#WIRE_LABELS + 1] = "[" .. letters:sub(i, i) .. "]"
    end
    -- past 52: two letters, which the same service kept as well
    for i = 1, #letters do
        for j = 1, #letters do
            WIRE_LABELS[#WIRE_LABELS + 1] = "[" .. letters:sub(i, i) .. letters:sub(j, j) .. "]"
        end
    end
end

local function label_pool(reserved)
    local pool = {}
    for i = 1, #WIRE_LABELS do
        if not (reserved and reserved[WIRE_LABELS[i]]) then
            pool[#pool + 1] = WIRE_LABELS[i]
        end
    end
    return pool
end

function M.wire_glyph_count()
    return #WIRE_GLYPHS
end

-- "\u27e60\u27e7 hello \u27e61\u27e7" -> "① hello ②"
function M.to_wire(masked, reserved, variant)
    if type(masked) ~= "string" then
        return masked
    end
    local pool = (variant == "labels") and label_pool(reserved) or wire_pool(reserved)
    for i = 1, #pool do
        local placeholder = PLACEHOLDER_OPEN .. (i - 1) .. PLACEHOLDER_CLOSE
        if masked:find(placeholder, 1, true) then
            masked = masked:gsub(literal_pattern(placeholder), pool[i])
        end
    end
    return masked
end

-- and back again, for an answer that came from a service
function M.to_internal(wire_text, reserved, variant)
    if type(wire_text) ~= "string" then
        return wire_text
    end
    local pool = (variant == "labels") and label_pool(reserved) or wire_pool(reserved)
    for i = 1, #pool do
        if wire_text:find(pool[i], 1, true) then
            wire_text = wire_text:gsub(literal_pattern(pool[i]),
                                       PLACEHOLDER_OPEN .. (i - 1) .. PLACEHOLDER_CLOSE)
        end
    end
    return wire_text
end

-- Puts the official terms back. Returns text and the number of tokens that went
-- missing (a translator may drop a placeholder; the caller can then discard it).
-- Spaces a service adds that the target language does not want, independent of any term or token:
--
--   * between two characters of a script that does not separate words with spaces (measured:
--     "显示 小数位" for "Show decimals", "迷路了。 其他" for "lost. Other");
--   * between such a character and an ASCII comma, full stop and friends, which the services emit
--     freely in Chinese text ("任务等级 40,在那里").
--
-- Exported because it has to run even when a string carries no mask at all - unmask() returns early
-- when it has no tokens, and a plain sentence that comes back with a space in the middle of it was
-- left alone until this existed. The accept path calls it; unmask calls it for the masked case.
function M.tidy(text)
    -- Scope, and it is deliberately the narrow one.
    --
    -- The only space this file may remove is one that sits beside a token of *ours* - a restored glossary
    -- term or a restored rich-text tag. Everything else in a translation belongs to the target language or
    -- to the English source, and both of those keep their spaces:
    --
    --   * "在 HUD 上显示", "为 1 或 0", "屏幕 HUD 元素" - a space between Chinese and Latin or digits is what
    --     Chinese typography wants, and the Latin is the English source text;
    --   * "Language: 简体中文" - the colon is English, so the space after it is English spacing;
    --   * classifying every space in the user's real stores by the scripts on either side gives 105
    --     CJK/punctuation, 83 Latin+CJK and 67 CJK+Latin, and *zero* CJK+CJK. There is no corpus behind a
    --     wider rule.
    --
    -- Two wider versions were written and removed on that evidence: removing a space between two CJK
    -- characters (the stores contain none, and the term branch below already covers the measured case), and
    -- removing one between CJK and ASCII punctuation (it broke "Language: 简体中文" - the colon is the
    -- source's, not the service's).
    --
    -- Fullwidth punctuation was measured too, because it is the one mark that cannot have come from the
    -- English source and so would be unambiguous: a space beside a fullwidth comma, colon or bracket, in
    -- either direction, occurs zero times across every store. The single hit was " 删除？无法撤销！ " and its
    -- English source is " Delete? NO UNDO! " - the spaces are the source's own edges, preserved. DeepL wrote
    -- the fullwidth question and exclamation marks with no space around them, unasked.
    --
    -- The term and markup branches in tighten_script_boundary() are where the real work happens. This
    -- function exists so that the accept path can run the markup half even when a string carries no mask at
    -- all, because unmask() returns early without tokens.
    return text
end

function M.unmask(text, tokens, expected)
    if type(text) ~= "string" then
        return text, 0
    end
    if type(tokens) ~= "table" or #tokens == 0 then
        return text, 0
    end

    -- A service may keep the placeholder but re-space or re-wrap it ("{ 0 }", "{0 }"), and then a
    -- literal search misses it while the raw characters still end up in the game. Whitespace inside the
    -- brackets is therefore tolerated, in both the missing check and the substitution; anything else is
    -- still a miss, and the caller refuses the answer (online.lua checks for a leftover).
    local function placeholder_pattern(index)
        return PLACEHOLDER_OPEN .. "%s*" .. tostring(index) .. "%s*" .. PLACEHOLDER_CLOSE
    end

    -- Occurrences, not existence, when the masked source is at hand: a term that appears twice shares one
    -- placeholder index, so a service that dropped *one* of the two used to pass the existence test and
    -- the loss was stored. Measured shape: "Restrict the distance between your {companion} and ... marked
    -- by the {companion} Auto-Mark".
    local function occurrences(haystack, pattern)
        local _, count = haystack:gsub(pattern, "")
        return count
    end

    local missing = 0
    local missing_indices = {}
    for i = 1, #tokens do
        local pattern = placeholder_pattern(i - 1)
        local wanted = 1
        if type(expected) == "string" and expected ~= "" then
            wanted = occurrences(expected, pattern)
        end
        if occurrences(text, pattern) < wanted then
            missing = missing + 1
            missing_indices[#missing_indices + 1] = i
        end
    end

    local result = text:gsub(PLACEHOLDER_OPEN .. "%s*(%d+)%s*" .. PLACEHOLDER_CLOSE, function(index)
        local token = tokens[tonumber(index) + 1]
        if token then
            return token.term
        end
        return ""
    end)

    for i = 1, #tokens do
        local token = tokens[i]
        -- `raw` marks a token that is punctuation, not a term: a masked line break must go back
        -- exactly as it was, without the CJK spacing rules that apply to real terms.
        if token and type(token.term) == "string" and token.term ~= "" and not token.raw then
            result = tighten_script_boundary(result, token.term)
        end
    end

    result = M.tidy(result)

    -- The third value names the tokens, so a caller can retry with just those sent as plain text
    -- (see relax_mask in online.lua).
    return result, missing, missing_indices
end

return M
