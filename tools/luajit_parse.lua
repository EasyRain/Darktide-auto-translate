-- luajit_parse.lua -- parse the Lua files given on the command line, never run them.
--
-- Used by tools/lua_syntax_check.py when a LuaJIT binary is available. LuaJIT is the
-- runtime the game actually uses (5.1 plus a little of 5.2), so parsing with it is
-- the faithful check: a plain Lua 5.5 parser accepts a superset and would NOT catch a
-- 5.3+ feature that the game rejects.
--
-- loadfile() compiles the chunk without executing it, which is exactly what is
-- wanted here: running these files would call get_mod() and fail for reasons that
-- have nothing to do with syntax.
local bad = 0

for i = 1, #arg do
    local chunk, err = loadfile(arg[i])
    if chunk then
        chunk = nil
    else
        bad = bad + 1
        io.stderr:write("FAIL ", arg[i], "\n     ", tostring(err), "\n")
    end
end

print(string.format("%s (%s): %d file(s) parsed, %d failed",
    _VERSION, jit and jit.version or "no jit", #arg, bad))
os.exit(bad == 0 and 0 or 1)
