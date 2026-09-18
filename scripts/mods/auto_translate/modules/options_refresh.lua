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

-- The name a mod declares, in whatever language its localization resolves right now.
--
-- The key is NOT the same in every mod: their data file ends with `name = mod:localize(<key>)`, and
-- most use "mod_name" - but unlock_ui_fps and scores use "mod_title" (measured on the installed set;
-- no mod defines both). Reading only "mod_name" made localize() answer "<mod_name>" for those two, so
-- their names were skipped in silence: the row for unlock_ui_fps kept the translated name while
-- ability_timer's went back, which is exactly how it was reported.
local NAME_KEYS = { "mod_title", "mod_name" }

local function mod_name_in(target)
    if type(target) ~= "table" or type(target.localize) ~= "function" then
        return nil
    end
    for i = 1, #NAME_KEYS do
        local value = target:localize(NAME_KEYS[i])
        if not is_key_missing(value) then
            return value
        end
    end
    return nil
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

-- The left-hand list as it is being drawn right now.
--
-- The category rows are widgets built at on_enter out of the name copies, and the label is baked into
-- `widget.content.text` at that moment (dmf_options_view_content_blueprints.lua, settings_button:init),
-- with the entry kept in `content.entry`. Marking the templates stale only takes effect on the NEXT
-- build, so a player who flips the switch while the screen is open keeps looking at the old language -
-- which is exactly what "the list does not follow, only a restart helps" was.
function M.reapply_live(mod, view)
    local dmf = get_mod("DMF")
    if type(view) ~= "table" or type(dmf) ~= "table" then
        return 0
    end
    local rows = view._category_data
    if type(rows) ~= "table" then
        return 0
    end

    local updated = 0
    for i = 1, #rows do
        local row = rows[i]
        local entry = type(row) == "table" and row.entry or nil
        local name = type(entry) == "table" and entry.mod_name or nil
        local target = name and dmf.mods and dmf.mods[name] or nil
        -- The toggle-mods category has no mod_name: it is DMF's own row and keeps its own wording.
        if type(target) == "table" and type(target.localize) == "function" then
            local title = mod_name_in(target)
            if title and entry.display_name ~= title then
                entry.display_name = title
                local widget = row.widget
                if type(widget) == "table" and type(widget.content) == "table" then
                    widget.content.text = title
                end
                updated = updated + 1
            end
        end
    end

    -- The rows of DMF's own mod-toggle list are widgets built from those same templates, and they baked
    -- the label into content.text when they were created: patching the template moves nothing.
    local by_category = view._settings_category_widgets
    if type(by_category) == "table" then
        for _, data in pairs(by_category) do
            if type(data) == "table" then
                for i = 1, #data do
                    local item = data[i]
                    local entry = type(item) == "table" and item.entry or nil
                    local widget = type(item) == "table" and item.widget or nil
                    if type(entry) == "table" and type(widget) == "table"
                        and type(widget.content) == "table"
                        and type(widget.content.text) == "string"
                        and type(entry.display_name) == "string"
                        and widget.content.text ~= entry.display_name then
                        widget.content.text = entry.display_name
                        updated = updated + 1
                    end
                end
            end
        end
    end

    return updated
end

-- Which names in the left-hand list are Chinese, and who put them there.
--
-- The list is translated by two different hands. Ours: a `mod_name` entry in the translation files,
-- which follows the switch. The mod's own: most mods ship a zh-cn name in their own localization file
-- (23 of the 27 installed here, measured), and `name = mod:localize("mod_name")` in the mod's data
-- file picks it up - that one is the mod author's text and cannot follow our switch at all. Without
-- this line, "the list is still Chinese" cannot be told apart from "our translation did not come back
-- out", and both have been reported with the same words.
local function has_cjk(text)
    return type(text) == "string" and text:find("[\228-\233]") ~= nil
end

function M.list_report(mod, view)
    local dmf = get_mod("DMF")
    if M.list_reported or type(view) ~= "table" or type(dmf) ~= "table" then
        return 0
    end
    local rows = view._category_data
    if type(rows) ~= "table" then
        return 0
    end

    local found, shown = {}, {}
    for i = 1, #rows do
        local entry = type(rows[i]) == "table" and rows[i].entry or nil
        local name = type(entry) == "table" and entry.mod_name or nil
        local target = name and dmf.mods and dmf.mods[name] or nil
        if type(target) == "table" and type(target.localize) == "function" and has_cjk(entry.display_name) then
            found[#found + 1] = string.format("%s='%s' (own key: '%s')",
                tostring(name), tostring(entry.display_name),
                tostring(mod_name_in(target) or "<missing>"))
        end
    end

    if mod and #found > 0 then
        M.list_reported = true
        for i = 1, math.min(#found, 4) do
            shown[#shown + 1] = found[i]
        end
        util.info(mod, "%d name(s) in the mod list are still Chinese; each with what the mod's own key resolves to (equal = the mod author's own zh-cn, different = ours did not come out): %s%s",
            #found, table.concat(shown, "; "),
            #found > 4 and string.format("; and %d more", #found - 4) or "")
    end
    return #found
end

-- Clears the view's cached templates when it is next left, so the following open rebuilds from the
-- (re-localised) data, and writes into the screen that is open right now. The second half is what the
-- player actually looks at: the category rows were built from the name copies, so marking the
-- templates stale only helps the next build.
function M.mark_stale(mod)
    M.stale = true

    local view = M.view
    if type(view) == "table" then
        -- Templates first, then the rows: the row text is copied out of the template, so the other
        -- order would push the old wording into the widgets.
        local rows, templates = 0, 0
        pcall(function() templates = M.reapply_templates(mod, view, true) end)
        pcall(function() rows = M.reapply_live(mod, view) end)
        if mod and (rows > 0 or templates > 0) then
            util.info(mod, "options screen is open: %d list row(s) and %d template(s) re-localised in place",
                rows, templates)
        end
        -- Say which Chinese names are left, and whose they are (see list_report).
        pcall(M.list_report, mod, view)
    end

    if exit_hook_installed then
        return
    end

    local BaseView = CLASS and CLASS.BaseView
    if not BaseView then
        util.log(mod, "CLASS.BaseView unavailable; option texts will need a restart")
        return
    end

    local ok, err = pcall(function()
        -- The live view instance is the one thing DMF keeps no handle on, so it is taken from the view
        -- callbacks. on_enter, not on_exit: the screen is open when the switch gets flipped, and the
        -- very first open has no exit behind it yet.
        mod:hook_safe(BaseView, "on_enter", function(self)
            if self and self.view_name == "dmf_options_view" then
                M.view = self
            end
        end)

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

    -- DMF's mod list does not read the options header for a mod's name: it reads the mod object
    -- (`get_readable_name()`), whose value was cached when the mod was constructed - `name =
    -- mod:localize("mod_name")` in the mod's own data file, so it holds whatever language was in the
    -- table at load time. Writing it back is the only way the list can move.
    --
    -- The setter has to be DMF's: `set_internal_data` is a module-local in dmf_mod_data.lua and is
    -- attached to the mod object ONLY for DMF itself (line 101), so `target.set_internal_data` is nil
    -- for every other mod and the call did nothing at all - silently, through the pcall. That is why
    -- the name on the left never went back while every detail row did.
    local function set_internal(target, key, value)
        if type(dmf.set_internal_data) == "function" then
            return (pcall(dmf.set_internal_data, target, key, value))
        end
        if type(target.set_internal_data) == "function" then
            return (pcall(target.set_internal_data, target, key, value))
        end
        return false
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
            --
            -- `localize(<name key>)` is the mod's own name (see mod_name_in: "mod_name" for most,
            -- "mod_title" for unlock_ui_fps). DMF itself uses `dmf_mod_name` and ships its own zh-cn
            -- for it, so its row is DMF's own text and is left alone.
            local title = mod_name_in(target)
            if title then
                assign(header, "title", title)
                if header.readable_mod_name ~= nil then
                    assign(header, "readable_mod_name", title)
                end
                -- Counted only when the write went through: this count is the evidence that the list
                -- can actually be moved, and it was overstated while the call was a silent no-op.
                if set_internal(target, "readable_name", title) then
                    named = named + 1
                end
            end
            local description = target:localize("mod_description")
            if not is_key_missing(description) and header.description ~= nil then
                assign(header, "description", description)
                set_internal(target, "description", description)
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

-- What the settings screen has already BUILT, as opposed to the data it was built from.
--
-- The category list down the left (the mod names) and the per-mod toggles are made from *copies* of
-- the header data the first time the screen is opened, while the detail widgets share the live tables.
-- That is why switching translation off reverted the detail text immediately and left the list in the
-- old language: re-localising the data reaches the live tables only. DMF rebuilds those copies when
-- `_options_templates` is dropped, which happens on the next open - and the player is looking at the
-- screen *now*. So patch the built entries as well, on every open.
function M.reapply_templates(mod, view, quiet)
    local dmf = get_mod("DMF")
    local templates = type(view) == "table" and view._options_templates or nil
    if type(dmf) ~= "table" or type(templates) ~= "table" then
        return 0
    end

    local updated = 0
    local categories, toggles, sample = 0, 0, nil
    local function assign(target, field, value)
        if value and target[field] ~= nil and target[field] ~= value then
            target[field] = value
            updated = updated + 1
        end
    end

    -- The name and description a mod shows, in the language its own localization currently resolves.
    local function wording(mod_name)
        local target = mod_name and dmf.mods and dmf.mods[mod_name] or nil
        if type(target) ~= "table" or type(target.localize) ~= "function" then
            return nil, nil
        end
        local description = target:localize("mod_description")
        return mod_name_in(target),
            (not is_key_missing(description)) and description or nil
    end

    for _, category in ipairs(templates.categories or {}) do
        categories = categories + 1
        local title, description = wording(category.mod_name)
        -- The first category is DMF's own toggle-mods page: no mod_name, nothing to translate. It is
        -- a useless sample, and reading `shown=` off it is what hid the rows that matter.
        if category.mod_name and not sample then
            sample = category
        end
        assign(category, "display_name", title)
        assign(category, "description", description)
    end

    -- The mod toggles carry their own copies. They are not marked with `type` (DMF picks the builder by
    -- type and the built template does not keep it), so the marker is `search_id` being a mod DMF
    -- knows: DMF sets it to the mod name, while an ordinary option row carries its own setting id.
    for _, setting in ipairs(templates.settings or {}) do
        local name = type(setting) == "table" and setting.search_id or nil
        if name and dmf.mods and dmf.mods[name] then
            toggles = toggles + 1
            local title, description = wording(name)
            assign(setting, "display_name", title)
            assign(setting, "tooltip_text", description)
            sample = sample or setting
        end
    end

    -- The first three builds always report, changed or not: "0 patched" on a fresh build says the list
    -- was already right, while no line at all says the build never happened - and telling those two
    -- apart is the whole question when a player reports that the list did not follow.
    -- util.info, not util.log - log lines are silent unless debug logging is on.
    local logs = M.templates_logs or 0
    if mod and not quiet and logs < 3 then
        M.templates_logs = logs + 1
        local name = sample and (sample.mod_name or sample.search_id) or "-"
        local target = name ~= "-" and dmf.mods and dmf.mods[name] or nil
        local resolved = type(target) == "table" and mod_name_in(target) or nil
        util.info(mod, "settings screen build: %d categor%s, %d mod toggle(s), %d patched; sample %s: shown=%s, localize(name key)=%s, readable=%s",
            categories, categories == 1 and "y" or "ies", toggles, updated, tostring(name),
            tostring(sample and sample.display_name), tostring(resolved),
            tostring(type(target) == "table" and target.get_readable_name and target:get_readable_name() or nil))
    end

    return updated
end

-- Patches the built list whenever the settings screen builds its templates.
--
-- The hook goes on `dmf.create_mod_options_settings` - the function that turns the header data into the
-- category list and the mod toggles - rather than on the view class. Hooking the class needs DMF's
-- delayed hooks (the class does not exist at load), and although DMF reported applying it, the callback
-- never ran: measured twice, with the diagnostic in place. This one uses exactly the same pattern as
-- the option-key recording that has worked since the beginning: a plain hook on a function of the dmf
-- table, with the original called first.
function M.install_view_hook(mod)
    if M.view_hooked then
        return true
    end
    local dmf = get_mod("DMF")
    if not (dmf and type(dmf.hook) == "function") then
        return false
    end
    local ok, hook_err = pcall(function()
        dmf:hook(dmf, "create_mod_options_settings", function(next_func, self, options_templates)
            local built_ok, built = pcall(next_func, self, options_templates)
            if not built_ok then
                util.info(mod, "the settings screen build failed: %s", tostring(built))
                return nil
            end
            -- DMF returns the templates table it filled in; fall back to the argument in case that
            -- ever changes, so the patch lands on whatever actually holds the list.
            local templates = (type(built) == "table") and built or options_templates
            local patched, perr = pcall(M.reapply_templates, mod, { _options_templates = templates })
            if not patched then
                -- util.info, not util.warn: a diagnostic must not become a notification.
                util.info(mod, "settings list refresh failed: %s", tostring(perr))
            end
            return built
        end)
    end)
    if not ok then
        util.info(mod, "could not hook the settings screen build: %s", tostring(hook_err))
        return false
    end
    M.view_hooked = true
    util.info(mod, "settings list refresh installed")
    return true
end

return M
