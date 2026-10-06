-- smoke_local_model.lua -- the offline engine, through the module's own FFI surface.
--
-- Why this exists: 0.3.4 shipped a call to at_set_model_threads that no ffi.cdef block declared.
-- LuaJIT raises "missing declaration for symbol" the moment the symbol is indexed, so the startup
-- pipeline aborted on the local-model path -- and nothing in the suite ever walked that path, which is
-- how it reached players. tools/check_exports.py now catches the static side of that; this smoke
-- catches the live side: it loads the real DLL through modules/online.lua's own CDEF and drives the
-- model pipeline the way the module does.
--
-- The model is 1.3 GB and only exists on a machine that downloaded it, so the smoke reports a skip
-- when it is missing (exit 0) and otherwise loads, translates and checks the result. Point it
-- elsewhere with AT_MODEL_DIR.
--
--   luajit tools/smoke_local_model.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local modules = here .. "/../scripts/mods/auto_translate/modules"

local ffi = require("ffi")
-- Declared here rather than reached for through ffi.C: indexing an undeclared symbol is the very
-- failure this smoke exists to catch, and the polling loop needs a real sleep, not a busy wait.
ffi.cdef[[ void Sleep(unsigned long); ]]
Mods = { lua = { ffi = ffi } }

local chunk, err = loadfile(modules .. "/online.lua")
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, online = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(online), "\n")
    os.exit(1)
end

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-46s got %-8s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end

-- Only what the module touches when it loads the core and runs the local path.
local mod = {
    id = "auto_translate",
    info = function() end,
    warning = function() end,
    error = function() end,
    get = function() return nil end,
}
online.init({
    popup = function() end,
    info = function() end,
    warn = function() end,
    log = function() end,
}, nil, nil, nil, nil, nil)

-- The module looks for the DLL at "mods/auto_translate/bin/at_core.dll" and its siblings, which is
-- how the game finds it - relative to the game folder, because that is the game's working directory.
-- Stand in the same place before the first load (load_core remembers a failure, so this has to happen
-- before it, not after).
local game = os.getenv("AT_GAME")
    or "D:\\Steam\\steamapps\\common\\Warhammer 40,000 DARKTIDE"
ffi.cdef[[ int SetCurrentDirectoryA(const char*); ]]
if ffi.C.SetCurrentDirectoryA(game) == 0 then
    print("note: could not stand in " .. game .. "; the core will not be found (skipped)")
    os.exit(0)
end

-- ---- 1. the DLL, through the module's CDEF (this is the 0.3.4 regression)
local core, why = online.load_core(mod)
check("native core loads", core ~= nil, true)
if not core then
    print("  " .. tostring(why))
    os.exit(1)
end
print("  core version: " .. tostring(ffi.string(core.at_version())))

local called, result = pcall(function() return core.at_set_model_threads(2) end)
check("at_set_model_threads is declared (0.3.4 crash)", called, true)
if not called then
    print("  " .. tostring(result))
else
    check("the thread cap is accepted", result ~= nil and result ~= 0, true)
end

-- ---- 2. the model files, if this machine has them
local function exists(path)
    local handle = io.open(path, "rb")
    if handle then handle:close() return true end
    return false
end

local model_dir = os.getenv("AT_MODEL_DIR")
    or "D:\\Steam\\steamapps\\common\\Warhammer 40,000 DARKTIDE\\mods\\auto_translate\\models"
if not exists(model_dir .. "\\model.bin") then
    print("note: no model at " .. model_dir .. "; the local path was not exercised (skipped)")
    print("")
    if failures > 0 then
        print(string.format("%d failure(s)", failures))
        os.exit(1)
    end
    print("the FFI surface used by the local engine is intact")
    os.exit(0)
end

check("the model directory holds all four files", core.at_set_model_dir(model_dir), 4)

local started = core.at_load_model_async()
check("the background load started", started >= 0, true)

local MODEL_READY = 2
local deadline = os.time() + 240
while core.at_model_status() ~= MODEL_READY and os.time() < deadline do
    ffi.C.Sleep(200)
end
check("the model reports ready", core.at_model_status(), MODEL_READY)
-- The core reports the effective thread count only once a model is loaded (the CLI prints "threads: 2
-- of 32" after its load line), so this is where the cap can be observed - and where 0.3.4 would have
-- thrown before the load even started.
check("the loaded model uses the capped thread count", core.at_model_threads(), 2)
if core.at_model_status() ~= MODEL_READY then
    print("  core said: " .. tostring(ffi.string(core.at_model_error())))
end

-- ---- 3. one string through the engine
local accepted = core.at_submit("The Emperor protects.", "zh-cn")
check("the core accepted the string", accepted ~= 0, true)

local buffer = ffi.new("char[4096]")
local bytes = 0
local poll_deadline = os.time() + 60
while bytes == 0 and os.time() < poll_deadline do
    bytes = core.at_poll(buffer, 4096)
end
check("a translation came back", bytes > 0, true)
if bytes > 0 then
    local text = ffi.string(buffer, bytes)
    check("it is not the English source", text ~= "The Emperor protects.", true)
    print("  translation: " .. text)
end

print("")
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("the offline engine runs end to end")
