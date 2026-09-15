-- auto_translate.mod
-- Automatically translates installed mods' texts in memory (never touches the
-- original mod files) and caches the result locally.
return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`auto_translate` needs Darktide Mod Framework.")
        new_mod("auto_translate", {
            mod_script       = "auto_translate/scripts/mods/auto_translate/auto_translate",
            mod_data         = "auto_translate/scripts/mods/auto_translate/auto_translate_data",
            mod_localization = "auto_translate/scripts/mods/auto_translate/auto_translate_localization",
        })
    end,
    packages = {},
    version = "0.1.0",
}
