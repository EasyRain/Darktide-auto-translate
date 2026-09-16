-- check_options_layout.lua -- what the options screen will actually show.
--
-- Runs DMF's own layout rules against the shipped auto_translate_data.lua, offline:
--
--   1. unfold        (dmf/scripts/mods/dmf/modules/core/options.lua, unfold_table)
--   2. visibility    (.../ui/options/mod_options.lua, update_widget_set_visibility)
--   3. tab candidates(.../ui/options/mod_options.lua, has_focusable_descendant)
--
-- and prints the result: which sections exist, which rows each one holds, which rows DMF
-- hides behind the API-service dropdown, and whether the top-level groups qualify for
-- DMF's built-in options tab strip. It reads the same file the game reads, so a setting
-- left outside every group - or a show_widgets index that points at nothing - shows up
-- here instead of in the options menu.
--
--     luajit tools/check_options_layout.lua [api_provider]
--
-- The optional argument is the value of the API-service dropdown to simulate (default
-- "deepl"; pass "custom" to see the custom-endpoint fields).
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local provider_value = arg[1] or "deepl"

local real_get_mod = get_mod
get_mod = function() return { localize = function(_, key) return key end } end
local data = assert(loadfile(here .. "/../scripts/mods/auto_translate/auto_translate_data.lua"))()
get_mod = real_get_mod

local raw_widgets = data.options.widgets

-- 1. unfold -------------------------------------------------------------------------
-- Mirrors unfold_table: one flat, ordered array, each entry carrying depth and
-- parent_index. `header` is DMF's own first entry (the mod row).
local unfolded = { { type = "header", index = 1, depth = 0, parent_index = 0 } }

local function unfold(list, parent_index, depth)
    for _, widget in ipairs(list) do
        unfolded[#unfolded + 1] = widget
        widget.index = #unfolded
        widget.depth = depth
        widget.parent_index = parent_index

        if (widget.type == "group" or widget.type == "checkbox"
                or widget.type == "dropdown" or widget.type == "header")
            and type(widget.sub_widgets) == "table" then
            unfold(widget.sub_widgets, widget.index, depth + 1)
        end
    end
end

unfold(raw_widgets, 1, 0)

-- 2. dropdown children --------------------------------------------------------------
-- DMF turns each option's show_widgets (positions inside sub_widgets, 1-based) into real
-- widget indices, and marks the dropdown as controlling them.
local controls_sub_widgets = {}

for _, widget in ipairs(unfolded) do
    if widget.type == "dropdown" and type(widget.sub_widgets) == "table" then
        local mapped = {}

        for i, option in ipairs(widget.options or {}) do
            if type(option.show_widgets) == "table" then
                widget.controls_sub_widgets = true
                local set = {}

                for j, position in ipairs(option.show_widgets) do
                    local child = widget.sub_widgets[position]

                    if not child then
                        print(string.format(
                            "ERROR  %s: option #%d show_widgets[%d] = %d points at no sub_widget",
                            widget.setting_id, i, j, position))
                        os.exit(1)
                    end

                    set[child.index] = true
                end

                mapped[option.value] = set
            end
        end

        if widget.controls_sub_widgets then
            controls_sub_widgets[widget.index] = mapped
        end
    end
end

-- The value each setting would have, from DMF's own defaults plus the simulated choice.
local values = { api_provider = provider_value }

for _, widget in ipairs(unfolded) do
    if values[widget.setting_id] == nil and widget.default_value ~= nil then
        values[widget.setting_id] = widget.default_value
    end
end

local function get_value(setting_id)
    return values[setting_id]
end

-- 3. visibility ---------------------------------------------------------------------
local visible = { [1] = true }

for i = 2, #unfolded do
    local widget = unfolded[i]
    local parent = unfolded[widget.parent_index]
    local is_visible = visible[widget.parent_index] ~= false

    if is_visible and parent.type == "checkbox" then
        is_visible = get_value(parent.setting_id) == true
    elseif is_visible and parent.type == "dropdown" and parent.controls_sub_widgets then
        local mapped = controls_sub_widgets[parent.index] or {}
        local shown = mapped[get_value(parent.setting_id)] or {}

        is_visible = shown[widget.index] == true
    end

    visible[widget.index] = is_visible
end

-- 4. tab candidates -----------------------------------------------------------------
local function has_focusable_descendant(widgets, index)
    local depth = widgets[index].depth

    for i = index + 1, #widgets do
        local widget = widgets[i]

        if widget.depth <= depth then
            break
        end

        if widget.type ~= "group" then
            return true
        end
    end

    return false
end

local candidates = {}

for i = 2, #unfolded do
    local widget = unfolded[i]

    if widget.depth == 0 and type(widget.sub_widgets) == "table"
        and has_focusable_descendant(unfolded, i) then
        candidates[#candidates + 1] = i
    end
end

-- Report -----------------------------------------------------------------------------
print(string.format("api_provider = %s", provider_value))
print(string.format("%d widget(s) unfolded, %d top-level section(s)\n",
    #unfolded - 1, #candidates))

local section_of = {}
for _, start in ipairs(candidates) do
    section_of[start] = true
end

local current = nil

for i = 2, #unfolded do
    local widget = unfolded[i]

    if section_of[i] then
        current = widget
        print(string.format("[%s]  %s", widget.setting_id, widget.type))
    elseif current then
        local state = visible[i] and "visible" or "HIDDEN"
        print(string.format("    %-24s %-9s %-9s depth %d%s", widget.setting_id, widget.type,
            state, widget.depth, visible[i] and "" or "   <- hidden by its parent"))
    end
end

-- Anything the tab strip could not reach is the failure this tool exists for: a setting
-- defined at the top level (depth 0) belongs to no section, so no tab would ever show it.
local orphans = 0

for i = 2, #unfolded do
    local widget = unfolded[i]

    if widget.type ~= "group" and widget.depth == 0 then
        print(string.format("ORPHAN %s: a setting outside every group", widget.setting_id))
        orphans = orphans + 1
    end
end

local hidden = 0

for i = 2, #unfolded do
    if not visible[i] then
        hidden = hidden + 1
    end
end

print("")
print(string.format("%d section(s) qualifying for DMF's tab strip, %d hidden row(s), %d orphan(s)",
    #candidates, hidden, orphans))

os.exit(orphans == 0 and 0 or 1)
