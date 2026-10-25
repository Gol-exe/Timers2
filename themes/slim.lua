--[[
    Slim theme for Timers2.
    Renders all active timers as plain text: "spellname: M:SS"
    No icons, bars, or graphics — maximum readability at minimum screen space.

    Interface: load(settings), update(result, settings), unload(), defaults

    Theme settings (settings.themes.slim; defaults in T.defaults below):
      flash_duration  seconds   buff rows below this blink a '! ' prefix (0 = off)
      flash_color     {r,g,b}   stored by the flash command, unused: the text has one color
      text_color      {a,r,g,b} display text color
      font_name       string    font family
      font_size       points    font size
      font_bold       bool      bold text
]]

local texts      = require('texts')
local formatting = require('formatting')
local T          = {}

-- Also the addon's config defaults for this theme (Timers2.lua).
T.defaults = {
    flash_duration = 0,
    flash_color    = {r=255, g=255, b=0  },
    text_color     = {a=220, r=220, g=220, b=235},
    font_name      = 'Consolas',
    font_size      = 9,
    font_bold      = false,
}

-- settings.themes.slim, with T.defaults for anything it lacks.
local function options(settings)
    local ts = settings and settings.themes and settings.themes.slim or {}
    return setmetatable({}, {__index = function(_, key)
        local value = ts[key]
        if value == nil then value = T.defaults[key] end
        return value
    end})
end

local COLUMN_GAP = 120   -- pixels between left and right text columns

-- One text object per column, with what it last showed: texts:text re-parses its
-- template and texts:pos looks up the window settings on every call, so both
-- are only called when the value changes.
local displays = {}   -- left / right / custom = {object, str, x, y, visible}

local function new_display(ts)
    local tc = ts.text_color
    local t = texts.new('', {
        bg      = {visible = false, alpha = 0},
        text    = {size=ts.font_size, font=ts.font_name, red=tc.r, green=tc.g, blue=tc.b, alpha=tc.a},
        flags   = {draggable = false},
        padding = 2,
    })
    t:bold(ts.font_bold == true)
    t:stroke_width(1)
    t:stroke_color(0, 0, 0)
    t:stroke_alpha(200)
    t:hide()
    return {object = t, visible = false}
end

local function show(display, x, y, lines)
    if #lines == 0 then
        if display.visible then display.object:hide(); display.visible = false end
        return
    end
    local str = table.concat(lines, '\n')
    if display.str ~= str then display.object:text(str); display.str = str end
    if display.x ~= x or display.y ~= y then display.object:pos(x, y); display.x, display.y = x, y end
    if not display.visible then display.object:show(); display.visible = true end
end

function T.load(settings)
    for _, display in pairs(displays) do display.object:destroy() end
    local ts = options(settings)
    local left, right, custom = new_display(ts), new_display(ts), new_display(ts)
    displays = {left = left, right = right, custom = custom}
end

function T.unload()
    for _, display in pairs(displays) do
        display.object:hide()
        display.visible = false
    end
end

local function sections_to_lines(sections, flash_dur, show_tenths, count_up, settings)
    local lines = {}
    for _, sec in ipairs(sections) do
        if sec.title then table.insert(lines, sec.title) end
        local indent = sec.title and '  ' or ''
        for _, row in ipairs(sec.rows) do
            local flash = ''
            if formatting.flashing(row, flash_dur) then
                flash = formatting.flash_lit(row, flash_dur) and '! ' or '  '
            end
            local line = indent .. flash .. formatting.label(row)
            if not formatting.hides_time(row, settings) then
                line = line .. ': ' .. formatting.time(formatting.display_seconds(row, count_up), show_tenths)
            end
            table.insert(lines, line)
        end
    end
    return lines
end

function T.update(result, settings)
    if not displays.left then return end

    local ts          = options(settings)
    local flash_dur   = ts.flash_duration
    local show_tenths = settings.show_tenths ~= false
    local count_up    = (settings.direction or 'down') == 'up'

    local px   = settings.pos.x
    local py   = settings.pos.y
    local cpos = settings.custom_pos or {x = px, y = py}

    local function lines(sections)
        return sections_to_lines(sections or {}, flash_dur, show_tenths, count_up, settings)
    end
    show(displays.left,   px,              py,     lines(result.left))
    show(displays.right,  px + COLUMN_GAP, py,     lines(result.right))
    show(displays.custom, cpos.x,          cpos.y, lines(result.custom))
end

return T
