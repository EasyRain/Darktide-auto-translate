-- batch_cost.lua -- what batching a run costs in characters, and what it saves in requests.
--
-- The markers a batched request carries ("[1] ", "[2] ", ...) are sent to the service like any
-- other text, and a service that bills per character charges for them. The free endpoints are
-- charged per *request*, so batching is a clear win there; a metered API pays the markers, so
-- the trade should be a measured number rather than an assumption. That is what this prints.
--
--   luajit tools/batch_cost.lua [store.lua]
--
-- The default corpus is the probe store (real strings scanned from installed mods, 121 of
-- them). Any store in the same shape works: `return { entries = { key = { en = "..." } } }`.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local path = arg[1] or (here .. "/out/probe-store.lua")

local online = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/online.lua"))()
local store = assert(loadfile(path))()

-- The planner's own eligibility rule, read from the module so it cannot drift: an item travels
-- in a batch only when it is short and on one line.
local lim = online.batch_limits
local function batchable(item)
    return #item.en <= lim.item_chars and item.en:find("[\r\n]") == nil and not item.no_batch
end

local items, seen = {}, {}
for key, entry in pairs(store.entries or {}) do
    local en = entry.en
    if type(en) == "string" and en ~= "" and not seen[en] then
        seen[en] = true
        items[#items + 1] = { en = en, key = key, mod_id = "corpus", hash = "" }
    end
end
table.sort(items, function(a, b) return a.en < b.en end)

local lim = online.batch_limits
local eligible, batched_chars, solo_chars, all_chars = 0, 0, 0, 0
for _, item in ipairs(items) do
    all_chars = all_chars + #item.en
    if batchable(item) then
        solo_chars = solo_chars + #item.en
    end
end

-- Group exactly the way take_batch() does, through the real planner: a long string does not
-- merely sit out a batch, it *ends* the one being built, so the counts below are what a run
-- would really send.
local groups = online.plan_batch_for_tests(items)
local multi, in_batches = 0, 0
for _, group in ipairs(groups) do
    if #group > 1 then
        multi = multi + 1
        in_batches = in_batches + #group
    end
    for i, item in ipairs(group) do
        batched_chars = batched_chars + #item.en
        if #group > 1 then
            batched_chars = batched_chars + #string.format("[%d] ", i) + 1
        end
    end
end

print(string.format("corpus      : %s (%d strings, %d travel in batches)", path, #items, in_batches))
print(string.format("requests    : %d solo -> %d batched (%d multi-item batch(es))",
    #items, #groups, multi))
print(string.format("characters  : %d solo -> %d batched", all_chars, batched_chars))
if all_chars > 0 then
    print(string.format("cost        : %+d characters (%+.2f%% of the run), on short labels only",
        batched_chars - all_chars, 100 * (batched_chars - all_chars) / all_chars))
end
print("")
print("DeepL's API takes several `text` parameters in one request, which needs no markers at")
print("all; this module uses markers for every provider so that one implementation covers the")
print("free endpoints too (gtx and MyMemory accept a single query only).")
