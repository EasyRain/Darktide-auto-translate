-- auto_translate_data.lua
local mod = get_mod("auto_translate")

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "apply_translation",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "auto_translate_enabled",
                type = "checkbox",
                -- off by default: the first launch is for configuring engines and models
                default_value = false,
            },
            {
                setting_id = "target_language",
                type = "dropdown",
                default_value = "auto",
                options = {
                    { text = "lang_auto",   value = "auto" },
                    { text = "lang_zh_cn",  value = "zh-cn" },
                    { text = "lang_zh_tw",  value = "zh-tw" },
                    { text = "lang_ja",     value = "ja" },
                    { text = "lang_ko",     value = "ko" },
                    { text = "lang_ru",     value = "ru" },
                    { text = "lang_de",     value = "de" },
                    { text = "lang_fr",     value = "fr" },
                    { text = "lang_es",     value = "es" },
                    { text = "lang_it",     value = "it" },
                    { text = "lang_pl",     value = "pl" },
                    { text = "lang_pt_br",  value = "pt-br" },
                    { text = "lang_uk",     value = "uk" },
                },
            },
            {
                setting_id = "engine",
                type = "dropdown",
                -- "auto" resolves to: large model -> small model -> keyed API ->
                -- free online. A fresh install has no model, so this works out of
                -- the box while still preferring the offline model once it exists.
                -- (Selecting a local engine explicitly still pauses with a notice
                -- when its model has not been downloaded.)
                default_value = "auto",
                options = {
                    { text = "engine_auto",       value = "auto" },
                    { text = "engine_online_free", value = "online_free" },
                    { text = "engine_online_api",  value = "online_api" },
                    { text = "engine_local_small", value = "local_small" },
                    { text = "engine_local_large", value = "local_large" },
                },
            },
            {
                setting_id = "online_api_key",
                type = "text",
                default_value = "",
                max_length = 256,
            },
            {
                setting_id = "proxy",
                type = "text",
                default_value = "",
                max_length = 128,
            },
            {
                setting_id = "download_model_small",
                type = "checkbox",
                default_value = false,
            },
            {
                setting_id = "download_model_large",
                type = "checkbox",
                default_value = false,
            },
            {
                setting_id = "progress_hud",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "reload_translations",
                type = "button",
                button_text = "reload_translations",
                function_name = "reload_translations",
            },
            {
                setting_id = "clear_cache",
                type = "button",
                button_text = "clear_cache",
                function_name = "clear_cache",
            },
            {
                setting_id = "test_glossary",
                type = "button",
                button_text = "test_glossary",
                function_name = "test_glossary",
            },
            {
                setting_id = "test_engines",
                type = "button",
                button_text = "test_engines",
                function_name = "test_engines",
            },
            {
                setting_id = "show_status",
                type = "button",
                button_text = "show_status",
                function_name = "show_status",
            },
            {
                setting_id = "debug_logging",
                type = "checkbox",
                default_value = false,
            },
        },
    },
}
