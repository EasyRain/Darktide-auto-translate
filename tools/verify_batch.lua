-- verify_batch.lua -- check the offline batching path against the real model.
--
-- tools/smoke_online.lua proves the planner and the splitter behave; it cannot prove
-- that the model keeps the markers at the batch size dispatch() actually uses, nor that
-- a returned part is attributed back to the right key, nor whether batching is actually
-- better than translating one string at a time. This does, using the deployed model and
-- real short strings from the mod's own store.
--
-- The model is a separate process and the batch text carries non-ASCII placeholder
-- characters, so the round trip is driven from PowerShell (see the README note at the
-- bottom of this file):
--
--   luajit tools/verify_batch.lua prepare <store-file> <target-lang> [max-items]
--     writes tools/out/batches.lua (the plan: every item, its placeholder tokens and the
--     batch it landed in), tools/out/solo.txt (one source string per line) and
--     tools/out/batch_1.txt ... (the exact string dispatch() would submit)
--
--   at_cli.exe queue <model-dir> <lang> <every line of solo.txt as its own argument>
--       > tools/out/solo.out.txt
--   at_cli.exe model <model-dir> <lang> "<contents of batch_N.txt>" --src en
--       > tools/out/batch_N.out.txt            (for every N)
--
--   luajit tools/verify_batch.lua verify
--     splits every answer the way handle_local_batch() does, restores each part with
--     that item's own token list, applies the same text_is_safe() gate, and prints one
--     line per key.
--
--   luajit tools/verify_batch.lua compare
--     the same, but against the solo answers: did batching change the outcome, and in
--     which direction? Batch size, marker form and the "unchanged" rule are all
--     judgement calls that this number decides.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local mod_dir = here .. "/.."
local out_dir = here .. "/out"

local util = assert(loadfile(mod_dir .. "/scripts/mods/auto_translate/modules/util.lua"))()
util.MOD_DIR = mod_dir

local glossary = assert(loadfile(mod_dir .. "/scripts/mods/auto_translate/modules/glossary.lua"))()
glossary.init(util)

Mods = { lua = { ffi = { cdef = function() end, load = function() error("no core in this test") end } } }
local online = assert(loadfile(mod_dir .. "/scripts/mods/auto_translate/modules/online.lua"))()
-- online.lua takes its collaborators through init(); the batch rule below needs a
-- glossary that can unmask, and text_is_safe() is the module's own.
online.init(util, nil, glossary, nil, nil)

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    -- Windows PowerShell's Out-File writes a UTF-8 BOM; the CLI's own output does not.
    if data:sub(1, 3) == "\239\187\191" then
        data = data:sub(4)
    end
    return data
end

local function write_file(path, data)
    -- util.ensure_dir() goes through Mods.lua.ffi, which the stub above refuses (that is
    -- the game's runtime, not this one), so the directory is made with cmd's mkdir.
    util.ensure_dir(out_dir)
    os.execute('mkdir "' .. out_dir:gsub("/", "\\") .. '" >nul 2>nul')
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function quote(s)
    return string.format("%q", s)
end

-- Lua source for a table of strings/numbers/booleans.
local function ser(value, indent)
    indent = indent or ""
    if type(value) == "string" then
        return quote(value)
    end
    if type(value) ~= "table" then
        return tostring(value)
    end
    local lines = {}
    local inner = indent .. "  "
    for i, entry in ipairs(value) do
        lines[#lines + 1] = inner .. ser(entry, inner) .. ","
    end
    for k, entry in pairs(value) do
        if type(k) ~= "number" then
            lines[#lines + 1] = string.format("%s%s = %s,", inner, k, ser(entry, inner))
        end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
end

local function load_plan()
    local chunk = loadfile(out_dir .. "/batches.lua")
    if not chunk then
        io.stderr:write("no plan: run prepare first\n")
        os.exit(1)
    end
    return chunk()
end

-- The CLI prints diagnostics before the answer:
--   queue: "[03] src...                               -> translated"
--   model: "result     : translated"
local function result_of(answer)
    if not answer then return nil end
    local result = answer:match("result%s*:([^\r\n]*)")
    if result then
        return (result:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return nil
end

local function queue_results(answer)
    local out = {}
    for line in tostring(answer):gmatch("[^\r\n]+") do
        local index, text = line:match("^%[(%d+)%]%s*.-%s+%-%>%s*(.*)$")
        if index then
            out[tonumber(index)] = text
        end
    end
    return out
end

-- What accept_translation() would do with this text: placeholder count intact, format
-- specifiers intact, nothing dropped for being too short.
local function judge(item, text)
    local restored, missing = glossary.unmask(text or "", item.tokens)
    if missing > 0 then
        return "lost-terms", restored
    end
    local safe, why = online.text_is_safe(item.en, restored)
    if not safe then
        return "refused", restored, why
    end
    if restored == item.masked then
        return "unchanged", restored
    end
    return "translated", restored
end

-- ---------------------------------------------------------------------------
-- prepare
-- ---------------------------------------------------------------------------
local function prepare(store_path, lang, max_items, items_cap)
    if items_cap then
        online.set_batch_limits_for_tests(items_cap)
    end
    print(string.format("batch caps: %d item(s), %d char(s), %d char(s) per item",
        online.batch_limits.items, online.batch_limits.chars, online.batch_limits.item_chars))

    local data, err = util.load_lua_file(store_path)
    if type(data) ~= "table" or type(data.entries) ~= "table" then
        io.stderr:write("could not read the store: ", tostring(err), "\n")
        os.exit(1)
    end

    -- The store has no stable order, so the keys are sorted: the same store has to give
    -- the same batches on every run, or the measurement cannot be repeated.
    local keys = {}
    for key in pairs(data.entries) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local items = {}
    for _, key in ipairs(keys) do
        local entry = data.entries[key]
        -- The queue itself filters these out before they ever reach an engine (key
        -- labels like "[F10]", numbers, strings without ASCII letters), so sending them
        -- here would compare both models on strings neither of them is ever asked to
        -- translate.
        if type(entry) == "table" and type(entry.en) == "string" and entry.en ~= ""
            and online.is_translatable(entry.en, lang) then
            items[#items + 1] = { key = key, en = entry.en, old = entry.text or "" }
        end
    end

    -- Only batchable items, so the plan is what dispatch() would really produce. The
    -- planner is driven through the real queue, and singletons are dropped here: a
    -- "batch" of one is the solo path, which the queue run covers.
    local groups = online.plan_batch_for_tests(items)
    local plan, solo, n = {}, {}, 0

    for _, group in ipairs(groups) do
        if #group > 1 and (not max_items or n + #group <= max_items) then
            local batch = { index = #plan + 1, items = {} }
            local parts = {}
            for i, one in ipairs(group) do
                local masked, tokens = glossary.mask(one.en, lang, true)
                batch.items[i] = {
                    key = one.key,
                    en = one.en,
                    masked = masked,
                    old = one.old,
                    part = string.format("[%d] %s", i, masked),
                    tokens = tokens,
                }
                parts[i] = batch.items[i].part
                n = n + 1
            end
            plan[#plan + 1] = batch
            write_file(string.format("%s/batch_%d.txt", out_dir, batch.index), table.concat(parts, " "))
        end
    end

    -- One line per item, in plan order: the queue run translates exactly these. They are
    -- the *masked* strings, the same text the batch carries minus its marker, so the
    -- baseline gets the same glossary protection and the two answers are comparable.
    local lines = {}
    for _, batch in ipairs(plan) do
        for _, item in ipairs(batch.items) do
            lines[#lines + 1] = item.masked
        end
    end

    write_file(out_dir .. "/batches.lua", "return " .. ser({ lang = lang, batches = plan }) .. "\n")
    write_file(out_dir .. "/solo.txt", table.concat(lines, "\r\n") .. "\r\n")

    print(string.format("%d item(s) in %d batch(es), lang %s", n, #plan, lang))
    for _, batch in ipairs(plan) do
        local keys = {}
        for _, item in ipairs(batch.items) do
            keys[#keys + 1] = item.key
        end
        print(string.format("  batch %d (%d): %s", batch.index, #batch.items, table.concat(keys, ", ")))
    end
end

-- ---------------------------------------------------------------------------
-- verify -- attribution and guards, per batch
-- ---------------------------------------------------------------------------
local function verify()
    local plan = load_plan()
    local checked, failures, retries = 0, 0, 0

    for _, batch in ipairs(plan.batches) do
        local answer = read_file(string.format("%s/batch_%d.out.txt", out_dir, batch.index))
        local result = result_of(answer)
        print(string.format("\n=== batch %d (%d item(s), lang %s) ===", batch.index, #batch.items, plan.lang))

        if not result then
            io.stderr:write(string.format("no answer in batch_%d.out.txt\n", batch.index))
            failures = failures + 1
            goto continue
        end

        print(string.format("submitted : %s", result))
        local parts = online.split_batch_for_tests(result, #batch.items)
        if not parts then
            -- The real failure: nothing can be attributed, so every item of the batch is
            -- handed back for a solo attempt.
            print("FAIL split: the model did not keep the markers -> all of these are retried one by one")
            failures = failures + 1
            goto continue
        end

        for i, item in ipairs(batch.items) do
            checked = checked + 1
            local verdict, restored, why = judge(item, parts[i])
            -- "unchanged" and the guard refusals are not split failures: the code retries
            -- exactly those items solo (no_batch), which is the designed answer to a
            -- half-good batch.
            local label = verdict == "translated" and "ok" or verdict
            if verdict ~= "translated" then
                retries = retries + 1
            end

            print(string.format("%-10s %-26s %s", label, item.key, restored))
            print(string.format("           en   : %s", item.en))
            print(string.format("           part : %s", parts[i]))
            if item.old ~= "" then
                print(string.format("           solo : %s   <- stored before batching existed", item.old))
            end
            if why then
                print(string.format("           why  : %s", tostring(why)))
            end
        end

        ::continue::
    end

    print(string.format("\n%d item(s) checked, %d split failure(s), %d item(s) would be retried solo",
        checked, failures, retries))
    os.exit(failures == 0 and 0 or 1)
end

-- ---------------------------------------------------------------------------
-- compare -- solo answers against batched ones, same items, same model, same session
-- ---------------------------------------------------------------------------
local function compare()
    local plan = load_plan()
    local solo = queue_results(read_file(out_dir .. "/solo.out.txt"))
    if not next(solo) then
        io.stderr:write("no solo answers: run the queue command first\n")
        os.exit(1)
    end

    local tally = {}
    local function count(name)
        tally[name] = (tally[name] or 0) + 1
    end

    local index, rows = 0, {}
    for _, batch in ipairs(plan.batches) do
        local answer = read_file(string.format("%s/batch_%d.out.txt", out_dir, batch.index))
        local result = result_of(answer)
        local parts = result and online.split_batch_for_tests(result, #batch.items) or nil

        for i, item in ipairs(batch.items) do
            index = index + 1
            local solo_raw = solo[index]
            local solo_verdict, solo_text, solo_why = "missing", "", nil
            if solo_raw then
                solo_verdict, solo_text, solo_why = judge(item, solo_raw)
            end

            local batch_verdict, batch_text, batch_why
            if not parts then
                batch_verdict, batch_text = "unsplit", "(markers lost)"
            else
                batch_verdict, batch_text, batch_why = judge(item, parts[i])
            end

            -- What would actually be stored? A batch part that the guards refuse (or that
            -- came back unchanged) is retried on its own, so its stored value is the solo
            -- answer - the batch can only add, never take away.
            local effect
            if batch_verdict == "translated" and solo_verdict == "translated" then
                effect = (solo_text == batch_text) and "same answer" or "changed answer"
            elseif batch_verdict == "translated" then
                effect = "BATCH WINS"
            elseif batch_verdict == "unsplit" then
                effect = "batch unusable"
            elseif solo_verdict == "missing" then
                effect = "no baseline"
            else
                effect = "kept solo result"
            end
            count(effect)
            count("solo:" .. solo_verdict)
            count("batch:" .. batch_verdict)

            rows[#rows + 1] = string.format("%-16s %-26s %s\n    solo : %s\n    batch: %s",
                effect, item.key, item.en, solo_text ~= "" and solo_text or "(none)", batch_text)
            if batch_why then
                rows[#rows + 1] = "    batch refused: " .. tostring(batch_why)
            end
            if solo_why then
                rows[#rows + 1] = "    solo refused : " .. tostring(solo_why)
            end
        end
    end

    print(table.concat(rows, "\n"))
    print("\n--- summary ---")
    local names = {}
    for name in pairs(tally) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        print(string.format("%-18s %d", name, tally[name]))
    end
    print(string.format("%-18s %d", "items", index))
end

-- ---------------------------------------------------------------------------
-- compare-models -- two models, same strings, same plan: which answer would be stored,
-- and does the bigger model actually change it for the better?
--
-- Judging translation quality automatically is not possible here (there is no
-- reference for most strings), so this prints what differs and counts the cases that
-- need no judgement at all: an answer that fails the guards, an answer the model gave
-- back unchanged (no translation), a batch whose markers were lost, and - for a
-- traditional Chinese target - simplified characters leaking into the output.
-- ---------------------------------------------------------------------------
local SIMPLIFIED = {}
do
    local set = loadfile(here .. "/zh_simplified_chars.lua")
    if set then
        for _, c in ipairs(set()) do
            SIMPLIFIED[c] = true
        end
    end
end

local function simplified_in(text)
    local found = {}
    -- A byte-wise scan cannot work here: Lua 5.1 strings are bytes, so text:sub(i, i)
    -- returns one byte of a multi-byte character and never matches a character at all
    -- (the first version of this check did exactly that and reported a clean 0%).
    for c in pairs(SIMPLIFIED) do
        if text:find(c, 1, true) then
            found[#found + 1] = c
        end
    end
    table.sort(found)
    return table.concat(found, " ")
end

-- Reads one model's answers from tools/out/<tag>/.
local function read_answers(tag, plan)
    local dir = out_dir .. "/" .. tag
    local answers = { batches = {}, solo = queue_results(read_file(dir .. "/solo.out.txt")) }
    for _, batch in ipairs(plan.batches) do
        local raw = read_file(string.format("%s/batch_%d.out.txt", dir, batch.index))
        local result = result_of(raw)
        answers.batches[batch.index] = result and online.split_batch_for_tests(result, #batch.items) or nil
        answers.batches["raw" .. batch.index] = result
    end
    return answers
end

-- What the queue would end up storing for one item, including the fallback: a part the
-- guards refuse is answered by the solo run instead. Returns source, stored text and
-- how the answer was classified.
local function effective(item, part, solo_raw)
    if part then
        local why = online.batch_part_refusal_for_tests(item, item.masked, part, item.tokens)
        if not why then
            local restored = glossary.unmask(part, item.tokens)
            return "batch", restored, "translated"
        end
    end
    if solo_raw then
        local verdict, text = judge(item, solo_raw)
        if verdict == "translated" or verdict == "unchanged" then
            return "solo", text, verdict
        end
        return "solo", text, "dropped (" .. tostring(verdict) .. ")"
    end
    return "none", "", "no answer"
end

local function compare_models(tag_a, tag_b)
    local plan = load_plan()
    local a = read_answers(tag_a, plan)
    local b = read_answers(tag_b, plan)

    if not next(a.solo) or not next(b.solo) then
        io.stderr:write("missing solo answers: run the queue for both models first\n")
        os.exit(1)
    end

    local tally, rows, differences, index = {}, {}, {}, 0
    local function count(name)
        tally[name] = (tally[name] or 0) + 1
    end

    local heads = {}
    for _, tag in ipairs({ tag_a, tag_b }) do
        heads[tag] = { unsplit = 0, simplified = 0, unchanged = 0, dropped = 0, batches = 0 }
    end

    for _, batch in ipairs(plan.batches) do
        for _, tag in ipairs({ tag_a, tag_b }) do
            heads[tag].batches = heads[tag].batches + 1
            if not (tag == tag_a and a.batches[batch.index] or tag == tag_b and b.batches[batch.index]) then
                heads[tag].unsplit = heads[tag].unsplit + 1
            end
        end

        for i, item in ipairs(batch.items) do
            index = index + 1
            local part_a = a.batches[batch.index] and a.batches[batch.index][i] or nil
            local part_b = b.batches[batch.index] and b.batches[batch.index][i] or nil
            local src_a, text_a, kind_a = effective(item, part_a, a.solo[index])
            local src_b, text_b, kind_b = effective(item, part_b, b.solo[index])

            -- Count what needs no judgement, per model, and flag simplified characters
            -- in a traditional Chinese answer.
            local function annotate(tag, text, kind)
                if kind == "unchanged" then
                    heads[tag].unchanged = heads[tag].unchanged + 1
                elseif kind ~= "translated" then
                    heads[tag].dropped = heads[tag].dropped + 1
                end
                local leaked = simplified_in(text)
                if leaked ~= "" then
                    heads[tag].simplified = heads[tag].simplified + 1
                    return text .. "   << simplified: " .. leaked
                end
                return text
            end
            text_a = annotate(tag_a, text_a, kind_a)
            text_b = annotate(tag_b, text_b, kind_b)

            local effect
            local usable_a = (kind_a == "translated")
            local usable_b = (kind_b == "translated")
            if usable_a and usable_b then
                effect = (text_a == text_b) and "same" or "differ"
            elseif usable_b then
                effect = "B only"
            elseif usable_a then
                effect = "A only"
            else
                effect = "neither"
            end
            count(effect)

            local row = string.format("%-8s %s\n    en : %s\n    A  : %s  [%s %s]\n    B  : %s  [%s %s]",
                effect, item.key, item.en, text_a, src_a, kind_a, text_b, src_b, kind_b)
            rows[#rows + 1] = row
            if effect ~= "same" then
                differences[#differences + 1] = row
            end
        end
    end

    local f = io.open(out_dir .. "/model-compare.txt", "wb")
    if f then
        f:write("A = " .. tag_a .. "\nB = " .. tag_b .. "\n\n")
        f:write(table.concat(rows, "\n"))
        f:write("\n")
        f:close()
    end

    print(string.format("A = %s   B = %s   (%d string(s), %d batch(es))", tag_a, tag_b, index, #plan.batches))
    for _, tag in ipairs({ tag_a, tag_b }) do
        local h = heads[tag]
        print(string.format("  %-8s batches with lost markers: %d/%d   no translation stored: %d   simplified leaks: %d",
            tag, h.unsplit, h.batches, h.unchanged + h.dropped, h.simplified))
    end
    print("\n--- items where the two models would store different text ---")
    print(table.concat(differences, "\n"))
    print("\n--- summary ---")
    local names = {}
    for name in pairs(tally) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        print(string.format("%-10s %d", name, tally[name]))
    end
    print(string.format("full table: %s", out_dir .. "/model-compare.txt"))
end

local command = arg[1]
if command == "prepare" then
    if not arg[2] then
        io.stderr:write("usage: luajit tools/verify_batch.lua prepare <store-file> <target-lang> [max-items] [items-per-batch]\n")
        os.exit(1)
    end
    prepare(arg[2], arg[3] or "zh-tw", tonumber(arg[4]), tonumber(arg[5]))
elseif command == "verify" then
    verify()
elseif command == "compare" then
    compare()
elseif command == "compare-models" then
    if not (arg[2] and arg[3]) then
        io.stderr:write("usage: luajit tools/verify_batch.lua compare-models <tagA> <tagB>\n")
        os.exit(1)
    end
    compare_models(arg[2], arg[3])
else
    io.stderr:write("usage: luajit tools/verify_batch.lua prepare|verify|compare ...\n")
    os.exit(1)
end
