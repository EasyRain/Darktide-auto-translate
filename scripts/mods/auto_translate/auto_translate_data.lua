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
                default_value = true,
            },
            {
                setting_id = "engine",
                type = "dropdown",
                default_value = "local_small",
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
                setting_id = "debug_logging",
                type = "checkbox",
                default_value = false,
            },
        },
    },
}
