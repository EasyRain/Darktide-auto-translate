-- Two steps of the sampled pipeline, driven by a shell loop.
--
-- A full run is impractical (2000+ keys, and the free tier does not hand out a whole round), so a handful
-- of risky shapes are driven through the real modules instead - mask, the line-break pass, the wire form,
-- a real request, the decode, the unmask and the real guards:
--
--   luajit tools/sample_step.lua wire    <index> <lang> <out-file>
--       writes the exact text a provider would receive (the wire form)
--   luajit tools/sample_step.lua verdict <index> <lang> <answer-file>
--       runs decode -> unmask -> text_is_safe on the answer and prints "ok" or "FAIL <reason>"
--
-- The request itself is made by tools/smoke_bing.lua (which owns the bing session) or by at_cli for the
-- endpoints that need none, so this file never speaks HTTP.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."

local ffi = require("ffi")
Mods = { lua = { ffi = setmetatable({}, { __index = function(_, key)
    -- A missing library still fails (the glossary's fake-ffi case), but a real one resolves, which is what
    -- load_core needs when this harness is run from the game's binaries directory.
    if key == "load" then
        return function(path)
            local ok, lib = pcall(ffi.load, path)
            if ok then return lib end
            error("no native core")
        end
    end
    return ffi[key]
end }) } }
package.path = repo .. "/scripts/mods/auto_translate/modules/?.lua;" .. package.path

local function slurp(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

local glossary = require("glossary")
local MOD_DIR = [[D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate]]
glossary.init({
    MOD_DIR = MOD_DIR,
    file_exists = function(path) return slurp(path) ~= nil end,
    load_lua_file = function(path)
        local chunk = loadfile(path)
        if not chunk then return nil, "load failed" end
        return chunk()
    end,
    info = function() end, warn = function() end, error = function() end,
    get = function() return false end, log = function() end,
})
assert(glossary.load())
local online = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/online.lua"))()

local function cstr_or(ptr)
    local ok, value = pcall(function() return ffi.string(ptr) end)
    return ok and value or "?"
end

local OPEN, CLOSE = "\226\159\166", "\226\159\167"     -- byte-wise: Lua 5.1 has no \u escapes

-- the online path's line-break pass (see mask_breaks in online.lua): each break becomes its own token
local function mask_breaks(text, tokens)
    if not text:find("\n", 1, true) then
        return text, tokens
    end
    local out = {}
    for i = 1, #tokens do out[i] = tokens[i] end
    text = text:gsub("\n", function()
        out[#out + 1] = { term = "\n", raw = true }
        return OPEN .. (#out - 1) .. CLOSE
    end)
    return text, out
end

local function mask_sample(index, lang)
    local samples = dofile(here .. "/sample-input.lua")
    local item = samples[index]
    if not item then
        return nil, nil, nil
    end
    local masked, tokens = glossary.mask(item.en, lang, true)
    masked, tokens = mask_breaks(masked, tokens)
    return item, masked, tokens
end

local mode, index, lang, path = arg[1], tonumber(arg[2]), arg[3], arg[4]
assert(mode == "wire" or mode == "verdict" or mode == "retry" or mode == "local"
    or mode == "api",
    "usage: wire|verdict|retry|local|api <index> <lang> <file> [key] [provider]")
local item, masked, tokens = mask_sample(index, lang)
if not item then
    print("FAIL no such sample: " .. tostring(index))
    os.exit(1)
end

-- A string the run never sends is not a sample: the decoration rule (a marquee title, a swatch) skips it
-- before any request, so measuring it here would invent failures for strings that cost nothing.
if online.is_asset_entry_for_tests(item.en) then
    if mode == "wire" then
        local handle = assert(io.open(path, "wb"))
        handle:write("")
        handle:close()
    end
    print("skip " .. item.shape .. " (the decoration rule leaves it in English)")
    os.exit(0)
end

if mode == "wire" then
    -- exactly what the request carries: the same two conversions the online paths apply
    local text = glossary.to_wire(masked, tokens)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
    print("wire " .. item.shape .. " " .. #tokens .. " token(s)")
    os.exit(0)
end

if mode == "api" then
    -- An API provider (DeepL by default). The key travels on the command line for this test and is never
    -- written into the repository: a run gets it from the mod's own setting.
    local key = arg[5]
    local provider = arg[6] or "deepl"
    assert(key and key ~= "", "api needs a key")
    local stub = { info = function() end, warn = function() end, error = function() end,
        get = function() return nil end, log = function() end, popup = function() end }
    online.init(stub, nil, glossary, nil, nil, nil)
    local core, why = online.load_core(stub)
    if not core then
        print("FAIL api: " .. tostring(why))
        os.exit(1)
    end

    local text = glossary.to_wire(masked, tokens)
    local host_buf = ffi.new("char[?]", 512)
    local path_buf = ffi.new("char[?]", 8192)
    local body_buf = ffi.new("char[?]", 65536)
    local headers = ffi.new("char[?]", 2048)
    if core.at_online_host(provider, key, host_buf, 512) == 0
        or core.at_online_path(provider, key, "en", lang, text, path_buf, 8192) == 0 then
        print("FAIL api: " .. tostring(cstr_or(core.at_online_error())))
        os.exit(0)
    end
    if core.at_online_body(provider, "en", lang, text, body_buf, 65536) == 0 then
        print("FAIL api: body: " .. tostring(cstr_or(core.at_online_error())))
        os.exit(0)
    end
    if core.at_online_headers(provider, key, headers, 2048) == 0 then
        print("FAIL api: headers: " .. tostring(cstr_or(core.at_online_error())))
        os.exit(0)
    end
    local job = core.at_http_post(host_buf, path_buf, core.at_online_content_type(provider),
        headers, body_buf)
    if job <= 0 then
        print("FAIL api: post: " .. tostring(cstr_or(core.at_error())))
        os.exit(0)
    end

    local id_buf = ffi.new("int[1]")
    local result_buf = ffi.new("int[1]")
    local code_buf = ffi.new("int[1]")
    local out_buf = ffi.new("char[?]", 65536)
    local len_buf = ffi.new("int[1]")
    local win_buf = ffi.new("unsigned int[1]")   -- the cdef wants unsigned int*, not char*
    local deadline = os.clock() + 60
    local rc = 0
    while os.clock() < deadline do
        rc = core.at_http_poll(id_buf, result_buf, code_buf, out_buf, 65536, len_buf, win_buf)
        if rc ~= 0 then break end
    end
    if rc == 0 then
        print("FAIL api: no answer within 60s")
        os.exit(0)
    end
    if result_buf[0] ~= 0 then
        print("FAIL api: HTTP " .. tostring(code_buf[0]))
        os.exit(0)
    end
    local parsed = ffi.new("char[?]", 65536)
    local n = core.at_online_parse(provider, out_buf, parsed, 65536)
    if n <= 0 then
        print("FAIL api: unreadable reply: " .. tostring(cstr_or(core.at_online_error())))
        os.exit(0)
    end
    local handle = assert(io.open(path, "wb"))
    handle:write(ffi.string(parsed, n))
    handle:close()
    print("api " .. provider .. " " .. item.shape .. " " .. n .. " byte(s)")
    os.exit(0)
end

if mode == "local" then
    -- The offline model, through the core the game uses: the DLL is loaded from the game's folder so that
    -- the model directory next to it resolves, and the text goes out in the same wire form the online
    -- paths use (the whole point of testing this engine with the new placeholder).
    -- load_core() is what declares the core's FFI surface and finds the DLL, so it has to run before any
    -- at_* call (the first version of this called at_model_status directly and died in __index).
    -- online.lua takes its dependencies through init(); without this call its `util` upvalue is nil and
    -- load_core dies on the first thing it wants to log.
    local stub = { info = function() end, warn = function() end, error = function() end,
        get = function() return nil end, log = function() end, popup = function() end }
    online.init(stub, nil, glossary, nil, nil, nil)
    local core, why = online.load_core(stub)
    if not core then
        print("FAIL local: " .. tostring(why))
        os.exit(1)
    end
    local READY = 2
    if core.at_model_status() ~= READY then
        core.at_load_model_async()
        local deadline = os.clock() + 180
        while core.at_model_status() ~= READY and os.clock() < deadline do end
    end
    if core.at_model_status() ~= READY then
        print("FAIL local: the model is not ready (status " .. tostring(core.at_model_status()) .. ")")
        os.exit(1)
    end
    local text = glossary.to_wire(masked, tokens)
    if core.at_submit(text, lang) <= 0 then
        print("FAIL local: the core refused the text: " .. tostring(core.at_model_error()))
        os.exit(0)
    end
    local buf = ffi.new("char[?]", 65536)
    local deadline = os.clock() + 180
    local n = 0
    while os.clock() < deadline do
        n = core.at_poll(buf, 65536)
        if n ~= 0 then break end
    end
    if n <= 0 then
        print("FAIL local: no answer (last n=" .. tostring(n) .. ")")
        os.exit(0)
    end
    local handle = assert(io.open(path, "wb"))
    handle:write(ffi.string(buf, n))
    handle:close()
    print("local " .. item.shape .. " " .. n .. " byte(s)")
    os.exit(0)
end

if mode == "retry" then
    -- Plan A as the run applies it: the tokens the service dropped are sent as plain text instead.
    local raw = slurp(path) or ""
    local internal = glossary.to_internal(raw, tokens)
    local rest, missing = glossary.unmask(internal, tokens, masked)
    local relax = {}
    local added = 0
    for i = 1, #tokens do
        local placeholder = OPEN .. (i - 1) .. CLOSE
        if not internal:find(placeholder, 1, true) then
            relax[i] = true
            added = added + 1
        end
    end
    local relaxed, kept = online.relax_mask_for_tests(masked, tokens, relax)
    local handle = assert(io.open(arg[5] or path, "wb"))
    handle:write(glossary.to_wire(relaxed, kept))
    handle:close()
    -- The answer that comes back is judged against the *relaxed* expectation, not the original one: the
    -- relaxed terms are deliberately no longer placeholders, so counting them as missing would be wrong.
    -- (The first version of this harness did exactly that and reported plan A as useless.)
    local side = assert(io.open((arg[5] or path) .. ".relax", "wb"))
    side:write("return {")
    for i = 1, #tokens do
        if relax[i] then side:write(i .. ", ") end
    end
    side:write("}\n")
    side:close()
    print(string.format("retry %d token(s) relaxed, %d kept", added, #kept))
    os.exit(0)
end

local raw = slurp(path)
if not raw then
    print("FAIL could not read the answer: " .. tostring(path))
    os.exit(1)
end

-- the reply side of the real pipeline
local internal = glossary.to_internal(raw, tokens)
-- A retry's expectation: the same relaxation the request applied
local side = loadfile(path .. ".relax")
if side then
    local relax_list = side()
    local relax = {}
    for _, i in ipairs(relax_list) do relax[i] = true end
    masked, tokens = online.relax_mask_for_tests(masked, tokens, relax)
end
local restored, missing = glossary.unmask(internal, tokens, masked)
if missing and missing > 0 then
    print(string.format("FAIL %s: %d placeholder(s) missing", item.shape, missing))
    os.exit(0)
end
if restored == masked then
    print(string.format("FAIL %s: the answer is unchanged", item.shape))
    os.exit(0)
end
local safe, why = online.text_is_safe(item.en, restored, lang)
if not safe then
    print(string.format("FAIL %s: %s", item.shape, tostring(why)))
else
    print(string.format("ok   %s", item.shape))
end
