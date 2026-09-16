-- auto_translate.mod
-- Automatically translates installed mods' texts in memory (never touches the
-- original mod files) and caches the result locally.
return {
    -- DMF provides new_mod() and the localization hook this mod injects through. It is loaded by
    -- the game itself and must not be listed in mod_load_order.txt (that file's header says so:
    -- listing "dmf" or "base" makes the game error), so the dependency is declared here instead.
    -- Where this mod sits among the *listed* mods is the player's choice - the README asks for the
    -- top of the list, so the option texts of every mod below it are translated before DMF caches
    -- them.
    load_after = {
        "dmf",
    },
    run = function()
        fassert(rawget(_G, "new_mod"), "`auto_translate` needs Darktide Mod Framework.")
        new_mod("auto_translate", {
            mod_script       = "auto_translate/scripts/mods/auto_translate/auto_translate",
            mod_data         = "auto_translate/scripts/mods/auto_translate/auto_translate_data",
            mod_localization = "auto_translate/scripts/mods/auto_translate/auto_translate_localization",
        })
    end,
    packages = {},
    version = "0.2.0",
}
