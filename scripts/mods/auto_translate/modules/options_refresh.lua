-- options_refresh.lua — make newly translated option texts appear without restarting.
--
-- Why this is needed: DMF localises widget titles and tooltips while initialising a
-- mod's `data` (core/options.lua -> localize_generic_widget_data), replacing the
-- localization KEY with the finished string. The Mod Options screen then builds its
-- widgets from those strings ONCE and caches them
-- (dmf_options_view.on_enter: "if not self._options_templates").
--
-- So a translation this mod produces while the game is running cannot show up in the
-- options on its own: the key is already gone and the widgets are already built.
-- Nothing about that is wrong with the translation - the file is written correctly
-- and the text is live for anything the game looks up at runtime.
--
-- Two things close the gap without a restart:
--   1. keep the ORIGINAL keys. Hooking dmf.initialize_mod_options hands us the raw
--      widget definitions before DMF overwrites title/tooltip with strings.
--   2. re-localise dmf.options_widgets_data in place, and clear the view's cached
--      templates on the next exit so reopening the screen rebuilds from that data.
--      (Not while the view is open: its own callbacks read _options_templates, so
--      clearing it mid-session breaks the next setting change.)
--
-- The player then only has to close and reopen the options screen.
local M = {}

local util

function M.init(u)
    util = u
end

-- mod_name -> { widgets = { [setting_id] = { title = <key>, tooltip = <key> } } }
M.raw = {}

M.stale = false
local exit_hook_installed = false

local function is_key_missing(text)
    -- mod:localize() answers "<key>" when there is no entry for it
    return type(text) ~= "string" or text == "" or text:match("^<.*>$") ~= nil
end

-- Records the raw title/tooltip keys of one mod's widgets. Called from the hook,
-- before DMF localises them.
function M.record(target_mod, options)
    if type(target_mod) ~= "table" or type(options) ~= "table" then
        return 0
    end
    local name = type(target_mod.get_name) == "function" and target_mod:get_name() or nil
    if type(name) ~= "string" or name == "" then
        return 0
    end

    local entry = { widgets = {} }
    local function walk(list)
        if type(list) ~= "table" then
            return
        end
        for _, widget in ipairs(list) do
            if type(widget) == "table" then
                if type(widget.setting_id) == "string" then
                    -- Everything DMF localises while building the widget: the title, the tooltip, a
                    -- button's caption and each dropdown entry. All of them are keys right now, which
                    -- is the only moment they can be caught.
                    local record = {
                        title = widget.title,
                        tooltip = widget.tooltip,
                        button_text = widget.button_text,
                    }
                    if type(widget.options) == "table" then
                        local options = {}
                        for i, option in ipairs(widget.options) do
                            if type(option) == "table" and type(option.text) == "string" then
                                options[i] = option.text
                            end
                        end
                        record.options = options
                    end
                    entry.widgets[widget.setting_id] = record
                end
                if type(widget.sub_widgets) == "table" then
                    walk(widget.sub_widgets)
                end
            end
        end
    end

    walk(options.widgets)
    M.raw[name] = entry
    return 1
end

-- Installs the recording hook. Safe to call more than once.
function M.install_hook(mod)
    if M.hooked then
        return true
    end

    local dmf = get_mod("DMF")
    if not (dmf and type(dmf.hook) == "function") then
        return false
    end

    local handler = function(next_func, target_mod, options)
        pcall(M.record, target_mod, options)
        return next_func(target_mod, options)
    end

    local ok, err = pcall(function()
        dmf:hook(dmf, "initialize_mod_options", handler)
    end)
    if not ok then
        util.warn(mod, "could not hook initialize_mod_options: %s", tostring(err))
        return false
    end

    M.hooked = true
    util.log(mod, "option key recording installed")
    return true
end

-- Clears the view's cached templates when it is next left, so the following open
-- rebuilds from the (re-localised) data. Only ever clears once per reload.
function M.mark_stale(mod)
    M.stale = true
    if exit_hook_installed then
        return
    end

    local BaseView = CLASS and CLASS.BaseView
    if not BaseView then
        util.log(mod, "CLASS.BaseView unavailable; option texts will need a restart")
        return
    end

    local ok, err = pcall(function()
        mod:hook_safe(BaseView, "on_exit", function(self)
            if self and self.view_name == "dmf_options_view" and M.stale then
                M.stale = false
                self._options_templates = nil
                util.info(mod, "options screen will be rebuilt on the next open")
            end
        end)
    end)

    if ok then
        exit_hook_installed = true
    else
        util.warn(mod, "could not hook the options view: %s", tostring(err))
    end
end

-- Re-localises every mod's widget titles and tooltips from the keys recorded in
-- M.raw. Only counts strings that actually change, so the caller can decide
-- whether a rebuild is worth it: with nothing translated there is nothing to show
-- and rebuilding the options screen would be pure waste.
-- Returns how many strings were replaced.
function M.reapply(mod)
    local dmf = get_mod("DMF")
    if type(dmf) ~= "table" or type(dmf.options_widgets_data) ~= "table" then
        return 0
    end

    local updated = 0
    local named = 0

    local function assign(target, field, value)
        if target[field] ~= value then
            target[field] = value
            updated = updated + 1
        end
    end

    for _, mod_data in ipairs(dmf.options_widgets_data) do
        local header = mod_data[1]
        local name = type(header) == "table" and header.mod_name or nil
        local target = name and dmf.mods and dmf.mods[name] or nil
        local raw = name and M.raw[name] or nil

        if type(target) == "table" and type(target.localize) == "function" then
            -- The mod's own entry in the options list. This part needs no recorded keys: it is the
            -- name the list shows, and a mod that has no settings never goes through
            -- initialize_mod_options at all - which is why gating it on `raw` (below) left every
            -- option-less mod showing its translated name.
            local title = target:localize("mod_name")
            if not is_key_missing(title) then
                assign(header, "title", title)
                if header.readable_mod_name ~= nil then
                    assign(header, "readable_mod_name", title)
                end
                -- DMF's mod list does not read this header for the name: it reads the mod object
                -- (`get_readable_name()`), whose value was cached when the mod was constructed - so the
                -- name has to be written back through the setter DMF exposes, or the list keeps
                -- showing the translation while everything else has gone back to the source language.
                if type(target.set_internal_data) == "function" then
                    pcall(target.set_internal_data, target, "readable_name", title)
                end
                named = named + 1
            end
            local description = target:localize("mod_description")
            if not is_key_missing(description) and header.description ~= nil then
                assign(header, "description", description)
                if type(target.set_internal_data) == "function" then
                    pcall(target.set_internal_data, target, "description", description)
                end
            end

            -- Its widgets: these do need the keys recorded before DMF turned them into strings.
            if raw then
            for i = 2, #mod_data do
                local widget = mod_data[i]
                local keys = type(widget) == "table" and widget.setting_id and raw.widgets[widget.setting_id] or nil
                if keys then
                    local widget_title = target:localize(keys.title or widget.setting_id)
                    if not is_key_missing(widget_title) then
                        assign(widget, "title", widget_title)
                    end

                    local tooltip
                    if keys.tooltip then
                        tooltip = target:localize(keys.tooltip)
                    elseif type(dmf.quick_localize) == "function" then
                        tooltip = dmf.quick_localize(target, widget.setting_id .. "_description")
                    end
                    if not is_key_missing(tooltip) then
                        assign(widget, "tooltip", tooltip)
                    end

                    if keys.button_text and type(widget.button_text) == "string" then
                        local caption = target:localize(keys.button_text)
                        if not is_key_missing(caption) then
                            assign(widget, "button_text", caption)
                        end
                    end

                    if keys.options and type(widget.options) == "table" then
                        for i, option_key in pairs(keys.options) do
                            local option = widget.options[i]
                            if type(option) == "table" and type(option.text) == "string" then
                                local caption = target:localize(option_key)
                                if not is_key_missing(caption) then
                                    assign(option, "text", caption)
                                end
                            end
                        end
                    end
                end
            end
            end
        end
    end

    return updated, named
end

return M
