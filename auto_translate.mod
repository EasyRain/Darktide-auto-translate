-- auto_translate.mod
-- Automatically translates installed mods' texts in memory (never touches the
-- original mod files) and caches the result locally.
return {
    -- DMF provides new_mod() and the localization hook this mod injects through, so it has to be
    -- loaded first. Declared here rather than left to mod_load_order.txt: a player who put this
    -- entry above dmf would otherwise get an assert instead of a working mod. Where this mod sits
    -- *among the other mods* stays the player's choice - the README asks for "as early as
    -- possible", so the option texts of the mods below it are translated before DMF caches them.
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
