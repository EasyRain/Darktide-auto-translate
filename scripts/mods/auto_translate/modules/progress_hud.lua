-- progress_hud.lua — the translation progress text in the bottom-right corner.
--
-- Deliberately plain: a couple of lines of text, no panel, no bar. The mod works
-- while the player is playing, so the point is only to say what it is doing
-- without opening the options or reading the log.
--
-- Drawing technique (engine API):
--   * the HUD is drawn from a hook on scripts/managers/ui/ui_constant_elements,
--     whose draw() receives the renderer as self._ui_renderer
--   * UIRenderer.begin_pass(renderer, scenegraph, input_service, dt, settings) /
--     end_pass wrap the draw; settings carry scale, start_layer and alpha
--   * UIRenderer.draw_text(renderer, text, size, font, pos, box, color, options)
--
-- Two things that are easy to get wrong and cost time:
--   * draw_text's trailing options argument MUST be a table - passing nil throws
--     "attempt to index local 'additional_settings'"
--   * the font must be passed as a font NAME resolved by the UI font manager, not a
--     font resource path: the manager maps it to a locale-aware fallback chain, and
--     that is what makes Chinese glyphs render instead of boxes
local M = {}

local mod, util, online, download

local UIRenderer, UIFonts, UIFontSettings, UIConstantElements
local ready = false
local tried = false

local hook_installed = false
local announced_draw = false
local draw_error_logged = false

local render_settings = {}
local empty_scenegraph = {}
local text_pos = { 0, 0, 952 }
local text_box = { 0, 0 }

local TEXT = { 255, 233, 236, 226 }
local TEXT_DIM = { 210, 172, 178, 172 }
local TEXT_WARN = { 255, 226, 138, 90 }

function M.init(m, u, o, d)
    mod = m
    util = u
    online = o
    download = d
end

local function resolve()
    if ready or tried then
        return ready
    end
    tried = true

    local ok, err = pcall(function()
        UIRenderer = require("scripts/managers/ui/ui_renderer")
        UIFonts = require("scripts/managers/ui/ui_fonts")
        UIFontSettings = require("scripts/managers/ui/ui_font_settings")
        UIConstantElements = require("scripts/managers/ui/ui_constant_elements")
    end)

    if ok and UIRenderer and UIFonts and UIFontSettings and UIConstantElements then
        ready = true
    else
        util.warn(mod, "progress HUD unavailable: %s", tostring(err))
    end
    return ready
end

local function font_type()
    local ok, body = pcall(function()
        return UIFontSettings.hud_body
    end)
    if ok and type(body) == "table" and type(body.font_type) == "string" then
        return body.font_type
    end
    return "proxima_nova_medium"
end

-- The options table is mandatory. A drop shadow is the one styling kept: plain text
-- over the game world is otherwise hard to read.
local function font_options()
    local ok, options = pcall(UIFonts.get_font_options_by_style, {
        -- right aligned: the block sits in the top-right corner, so the text hugs
        -- the screen edge instead of leaving a ragged one
        text_horizontal_alignment = "right",
        text_vertical_alignment = "center",
        drop_shadow = true,
    }, {})
    if ok and type(options) == "table" then
        return options
    end
    return {}
end

-- What to show, and for how long. Returns nil when there is nothing to draw.
local function compose(t)
    if not mod:get("progress_hud") then
        return nil
    end

    -- A model download comes first: it is the thing the player just started, it has its
    -- own percentage, and the translation queue may well be idle while it runs.
    if download then
        local dl = download.status()
        if dl.active or dl.done or dl.error then
            if dl.active then
                M.visible_until = (t or 0) + 10
            elseif (t or 0) >= (M.visible_until or 0) then
                return nil
            end

            local lines = {
                { text = string.format("%s  %s", mod:localize("mod_name"), mod:localize("hud_download")), color = TEXT },
            }
            if dl.active then
                local percent = (dl.total and dl.total > 0)
                    and string.format("%.0f%%", 100 * (dl.received or 0) / dl.total)
                    or string.format("%.1f MB", (dl.received or 0) / (1024 * 1024))
                lines[#lines + 1] = {
                    text = string.format("%s  %s", tostring(dl.name or ""), percent),
                    color = TEXT_DIM,
                }
            elseif dl.error then
                lines[#lines + 1] = { text = mod:localize("hud_download_failed", tostring(dl.error)), color = TEXT_WARN }
            else
                lines[#lines + 1] = { text = mod:localize("hud_download_done"), color = TEXT_DIM }
            end
            return lines
        end
    end

    local status = online.status()
    local queued = status.queued or 0
    if queued <= 0 then
        return nil
    end

    -- Stay on screen while work is happening, and for a few seconds after it stops
    -- so the result is actually readable.
    if status.running then
        M.visible_until = (t or 0) + 10
    elseif (t or 0) >= (M.visible_until or 0) then
        return nil
    end

    local lines = {}
    lines[#lines + 1] = {
        text = string.format("%s  %s", mod:localize("mod_name"),
            mod:localize("hud_progress", status.done or 0, queued)),
        color = TEXT,
    }

    if status.loading then
        -- The offline model is read from disk in the background; say so, because
        -- otherwise the counter sits at 0 and looks stuck.
        lines[#lines + 1] = { text = mod:localize("hud_model_loading"), color = TEXT_DIM }
    elseif status.running then
        local detail = mod:localize("hud_left", status.left or 0)
        if (status.failed or 0) > 0 or (status.refused or 0) > 0 then
            detail = detail .. "  " .. mod:localize("hud_failures", status.failed or 0, status.refused or 0)
        end
        lines[#lines + 1] = { text = detail, color = TEXT_DIM }
    elseif status.cooldown and status.cooldown > 0 then
        lines[#lines + 1] = { text = mod:localize("hud_cooldown", status.cooldown), color = TEXT_WARN }
    elseif status.last_error then
        lines[#lines + 1] = { text = mod:localize("hud_error", tostring(status.last_error)), color = TEXT_WARN }
    else
        lines[#lines + 1] = { text = mod:localize("hud_finished", status.done or 0), color = TEXT_DIM }
    end

    return lines
end

local function draw(self, ui_renderer, input_service, dt, t)
    local lines = compose(t)
    if not lines then
        return
    end

    local Vector3 = rawget(_G, "Vector3")
    if not Vector3 then
        return
    end

    local engine_render_settings = self and self._render_settings
    local resolution = rawget(_G, "RESOLUTION_LOOKUP")
    local scale = (engine_render_settings and engine_render_settings.scale)
        or (resolution and resolution.scale) or ui_renderer.scale or 1
    local res_w = (resolution and (resolution.width or resolution.res_w or resolution[1])) or 1920
    local screen_width = res_w / scale

    local font_size = math.floor(17 * scale + 0.5)
    local line_height = font_size + 4
    local width = math.floor(330 * scale + 0.5)

    -- Top-right corner. It used to sit bottom-right, where it covered the ammo and
    -- weapon readouts; the top-right of the HUD is empty, so nothing is hidden.
    -- TOP_MARGIN leaves room for anything the game puts along the top edge.
    local TOP_MARGIN = 70
    local RIGHT_MARGIN = 36
    local x = screen_width - width - RIGHT_MARGIN
    local y = TOP_MARGIN

    render_settings.scale = scale
    render_settings.inverse_scale = (engine_render_settings and engine_render_settings.inverse_scale) or (1 / scale)
    render_settings.start_layer = 950
    render_settings.alpha_multiplier = 1
    render_settings.material_flags = 0

    local options = font_options()
    local font = font_type()

    local ok, err = pcall(function()
        UIRenderer.begin_pass(ui_renderer, empty_scenegraph, input_service, dt, render_settings)

        local cursor = y
        for _, line in ipairs(lines) do
            text_pos[1] = x
            text_pos[2] = cursor
            text_box[1] = width
            text_box[2] = line_height
            UIRenderer.draw_text(ui_renderer, line.text, font_size, font, text_pos, text_box,
                line.color, options)
            cursor = cursor + line_height
        end

        UIRenderer.end_pass(ui_renderer)
    end)

    if not ok then
        -- Never leave a pass open: that would break the rest of the UI rendering.
        pcall(UIRenderer.end_pass, ui_renderer)
        if not draw_error_logged then
            draw_error_logged = true
            util.warn(mod, "progress HUD draw failed: %s", tostring(err))
        end
        return
    end

    if not announced_draw then
        announced_draw = true
        util.info(mod, "progress HUD is drawing (%d line(s))", #lines)
    end
end

function M.install(m)
    if hook_installed then
        return true
    end
    if not resolve() then
        return false
    end

    local ok, err = pcall(function()
        m:hook_safe(UIConstantElements, "draw", function(self, dt, t, input_service)
            local renderer = self and self._ui_renderer
            if not renderer then
                return
            end
            draw(self, renderer, input_service, dt, t)
        end)
    end)

    if not ok then
        util.warn(m, "progress HUD hook failed: %s", tostring(err))
        return false
    end

    hook_installed = true
    util.log(m, "progress HUD installed")
    return true
end

return M
