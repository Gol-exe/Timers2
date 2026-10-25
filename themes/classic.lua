--[[
    Classic theme for Timers2.
    Renders each row as a progress bar with an icon (or category dot),
    spell name overlaid left, and time remaining overlaid right.

    Interface: load(settings), update(result, settings), unload(), defaults

    Theme settings (settings.themes.classic; defaults in T.defaults below):
      high_color      {r,g,b}         bar fill color when remaining > med_percent
      med_percent     0-1             threshold below which mid color activates
      med_color       {r,g,b}         bar fill color in mid range
      low_percent     0-1             threshold below which low color activates
      low_color       {r,g,b}         bar fill color in low range
      flash_duration  seconds         flash a border around buff bars below this (0 = off)
      flash_color     {r,g,b}         flash border color
      bar_spacing     pixels          extra vertical gap between rows
      bg_color        {a,r,g,b}       bar background color
      text_color      {a,r,g,b}       row label and time text color
      font_name       string          font family
      font_size       points          row label font size
      font_bold       bool            bold row labels
      slim_mode       bool            hide all text, show bars+icons only
      extend_text     bool            position time outside bar (right side)
]]

local res        = require('resources')
local texts      = require('texts')
local images     = require('images')
local formatting = require('formatting')
local T          = {}

-- Also the addon's config defaults for this theme (Timers2.lua).
T.defaults = {
    high_color     = {r=0,   g=117, b=0  },
    med_percent    = 0.5,
    med_color      = {r=255, g=255, b=0  },
    low_percent    = 0.25,
    low_color      = {r=255, g=0,   b=0  },
    flash_duration = 0,
    flash_color    = {r=255, g=255, b=0  },
    bar_spacing    = 0,
    bg_color       = {a=50,  r=0,   g=0,  b=0  },
    text_color     = {a=220, r=255, g=255, b=255},
    font_name      = 'Consolas',
    font_size      = 8,
    font_bold      = false,
    slim_mode      = false,
    extend_text    = false,
}

-- settings.themes.classic, with T.defaults for anything it lacks.
local function options(settings)
    local ts = settings and settings.themes and settings.themes.classic or {}
    return setmetatable({}, {__index = function(_, key)
        local value = ts[key]
        if value == nil then value = T.defaults[key] end
        return value
    end})
end

-------------------------------------------------------------------------------
-- Fixed layout constants
-------------------------------------------------------------------------------
local ICON_GAP   = 3
local BAR_W      = 190
local BAR_H      = 10
local BAR_PAD    = 4
local TIME_W     = 44
local ROW_H      = BAR_H + 3
local TEXT_LIFT  = 5
local SEC_H      = 11
local GAP        = 3
local COLUMN_GAP = 12
local FONT_SEC   = 8
local MAX_ROWS   = 64   -- shared pool across all three columns (left + right + custom)
local MAX_SECS   = 24

local COL_SEC = {180, 180, 215}   -- section header text (not user-configurable)

local ICON_DIRS = {
    ability = windower.addon_path .. 'icons/abilities/',
    spell   = windower.addon_path .. 'icons/spells/',
}

-------------------------------------------------------------------------------
-- Icon name->id/cat lookup
-------------------------------------------------------------------------------
local icon_by_name = {}
for id, spell in pairs(res.spells) do
    local name = spell.en or spell.name
    if name then icon_by_name[name:lower()] = {id=id, cat='spell'} end
end
for id, ability in pairs(res.job_abilities) do
    local name = ability.en or ability.name
    if name and ability.recast_id and not icon_by_name[name:lower()] then
        icon_by_name[name:lower()] = {id=ability.recast_id, cat='ability'}
    end
end

local function resolve_icon(row)
    if row.cat == 'spell'   then return row.spell_id,  'spell'   end
    if row.cat == 'ability' then return row.recast_id, 'ability', row.job_id end
    if row.cat == 'buff' then
        local ico = row.name and icon_by_name[row.name:lower()]
        if ico then return ico.id, ico.cat end
        return row.buff_id, 'buff'
    end
    return nil, nil
end

local icon_path_cache = {}

-- Icon files: abilities by recast id (00036.png), spells by spell id, buffs by buff id.
-- Recast ids 0 and 254 are shared by every job's SP abilities, so those files carry
-- the job id as well: 00000.16.png is Blue Mage's one-hour ability, 00254.16.png its
-- second SP ability.
local function get_icon_path(cat, id, job_id)
    if not id then return false end
    local shared_sp = cat == 'ability' and job_id and (id == 0 or id == 254)
    local key = cat .. '_' .. tostring(id) .. (shared_sp and ('_' .. job_id) or '')
    if icon_path_cache[key] ~= nil then return icon_path_cache[key] end
    local dir      = ICON_DIRS[cat]
    local filename = (cat == 'buff') and (tostring(id) .. '.png')
                     or (shared_sp and string.format('%05d.%02d.png', id, job_id))
                     or (string.format('%05d', id) .. '.png')
    local path = dir and (dir .. filename)
    icon_path_cache[key] = (path and windower.file_exists(path)) and path or false
    return icon_path_cache[key]
end

-------------------------------------------------------------------------------
-- Retained drawing
--
-- Every object below remembers what it was last given, and a setter only calls
-- Windower when the value changes. Most rows look the same from one refresh to
-- the next, and the libraries resend on every call: images:path reloads the
-- texture, texts:text re-parses its template and texts:pos looks up the window
-- settings.
-------------------------------------------------------------------------------
local owned_prims = {}
local prim_state  = {}   -- [name] = {visible, a, r, g, b, x, y, w, h}

local function prim_own(name, a, r, g, b)
    table.insert(owned_prims, name)
    windower.prim.create(name)
    windower.prim.set_color(name, a, r, g, b)
    windower.prim.set_visibility(name, false)
    prim_state[name] = {visible = false, a = a, r = r, g = g, b = b}
end

local function prim_color(name, a, r, g, b)
    local s = prim_state[name]
    if s.a ~= a or s.r ~= r or s.g ~= g or s.b ~= b then
        windower.prim.set_color(name, a, r, g, b)
        s.a, s.r, s.g, s.b = a, r, g, b
    end
end

local function prim_rect(name, x, y, w, h)
    local s = prim_state[name]
    if s.x ~= x or s.y ~= y then
        windower.prim.set_position(name, x, y)
        s.x, s.y = x, y
    end
    if s.w ~= w or s.h ~= h then
        windower.prim.set_size(name, w, h)
        s.w, s.h = w, h
    end
    if not s.visible then
        windower.prim.set_visibility(name, true)
        s.visible = true
    end
end

local function prim_hide(name)
    local s = prim_state[name]
    if s.visible then
        windower.prim.set_visibility(name, false)
        s.visible = false
    end
end

-- A text or image object with the values it last showed.
local function slot(object) return {object = object, visible = false} end

local function place(s, x, y)
    if s.x ~= x or s.y ~= y then
        s.object:pos(x, y)
        s.x, s.y = x, y
    end
    if not s.visible then
        s.object:show()
        s.visible = true
    end
end

local function show_text(s, x, y, str)
    if s.str ~= str then
        s.object:text(str)
        s.str = str
    end
    place(s, x, y)
end

local function show_image(s, x, y, path)
    if s.path ~= path then
        s.object:path(path)
        s.path = path
    end
    place(s, x, y)
end

local function hide(s)
    if s.visible then
        s.object:hide()
        s.visible = false
    end
end

local TEXT_BG_OFF = {visible = false, alpha = 0}
local NO_DRAG     = {draggable = false}

local function new_text(font_sz, font_name, color, bold)
    local t = texts.new('', {
        bg    = TEXT_BG_OFF,
        text  = {size=font_sz, font=font_name, red=color.r, green=color.g, blue=color.b, alpha=color.a or 255},
        flags = NO_DRAG,
        padding = 1,
    })
    t:bold(bold == true)
    t:stroke_width(1)
    t:stroke_color(0, 0, 0)
    t:stroke_alpha(255)
    t:hide()
    return t
end

-------------------------------------------------------------------------------
-- Object pools
-------------------------------------------------------------------------------
-- rows[i] = {prims = {dot=, brd=, bga=, ...}, icon = slot, label = slot, time = slot}
local PRIM_LAYERS = {'dot', 'brd', 'bga', 'bgb', 'bgc', 'fla', 'flb', 'flc'}
local rows        = {}
local sections    = {}   -- [i] = slot
local used_rows   = 0    -- rows / sections drawn by the last update
local used_secs   = 0
local pool_ready  = false

local function hide_row(row)
    for _, name in pairs(row.prims) do prim_hide(name) end
    hide(row.icon)
    hide(row.label)
    hide(row.time)
end

-- Hides what the last update drew beyond this one's rows and sections.
local function hide_from(from_row, from_sec)
    for i = from_row, used_rows do hide_row(rows[i]) end
    for i = from_sec, used_secs do hide(sections[i]) end
    used_rows, used_secs = from_row - 1, from_sec - 1
end

local function destroy_objects()
    for _, row in ipairs(rows) do
        row.icon.object:destroy()
        row.label.object:destroy()
        row.time.object:destroy()
    end
    for _, s in ipairs(sections) do s.object:destroy() end
    rows, sections = {}, {}
    used_rows, used_secs = 0, 0
end

local function delete_prims()
    for _, name in ipairs(owned_prims) do windower.prim.delete(name) end
    owned_prims, prim_state = {}, {}
end

-------------------------------------------------------------------------------
-- Theme interface
-------------------------------------------------------------------------------
function T.load(settings)
    delete_prims()
    destroy_objects()

    local ts = options(settings)

    for i = 1, MAX_SECS do
        sections[i] = slot(new_text(FONT_SEC, ts.font_name, {r=COL_SEC[1], g=COL_SEC[2], b=COL_SEC[3]}))
    end

    for i = 1, MAX_ROWS do
        local prims = {}
        for _, layer in ipairs(PRIM_LAYERS) do prims[layer] = 'ti2_' .. layer .. '_' .. i end
        prim_own(prims.dot, 255, 255, 255, 255)
        prim_own(prims.brd, 255, 255, 220, 0)   -- flash border, must precede bg layers
        prim_own(prims.bga, 50, 0, 0, 0)
        prim_own(prims.bgb, 50, 0, 0, 0)
        prim_own(prims.bgc, 50, 0, 0, 0)
        prim_own(prims.fla, 255, 0, 117, 0)
        prim_own(prims.flb, 255, 0, 117, 0)
        prim_own(prims.flc, 255, 0, 117, 0)
        local img = images.new({draggable = false})
        img:fit(false)
        img:size(BAR_H, BAR_H)
        img:hide()
        rows[i] = {
            prims = prims,
            icon  = slot(img),
            label = slot(new_text(ts.font_size, ts.font_name, ts.text_color, ts.font_bold)),
            time  = slot(new_text(ts.font_size, ts.font_name, ts.text_color, ts.font_bold)),
        }
    end

    pool_ready = true
end

function T.unload()
    delete_prims()
    for _, row in ipairs(rows) do
        hide(row.icon); hide(row.label); hide(row.time)
    end
    for _, s in ipairs(sections) do hide(s) end
    used_rows, used_secs = 0, 0
    pool_ready = false
end

local dot_colors = {
    ability = {255, 165,  40},
    spell   = { 75, 158, 255},
    buff    = { 75, 218,  96},
    custom  = {238, 218,  55},
}

function T.update(result, settings)
    if not pool_ready then return end

    local left   = result.left   or {}
    local right  = result.right  or {}
    local custom = result.custom or {}

    local ts          = options(settings)
    local high_col    = ts.high_color
    local med_pct     = ts.med_percent
    local med_col     = ts.med_color
    local low_pct     = ts.low_percent
    local low_col     = ts.low_color
    local flash_dur   = ts.flash_duration
    local flash_col   = ts.flash_color
    local bg_col      = ts.bg_color
    local slim        = ts.slim_mode
    local ext_text    = ts.extend_text
    local row_height  = ROW_H + ts.bar_spacing
    local text_dy     = math.floor((BAR_H - ts.font_size) / 2) - TEXT_LIFT
    local show_tenths = settings.show_tenths ~= false
    local count_up    = (settings.direction or 'down') == 'up'

    -- For count-up the fill grows with the time passed. Flash still follows
    -- the time remaining (near expiry).
    local function fill_ratio(row)
        if row.total <= 0 then return 0 end
        local r = math.max(0, math.min(row.remaining / row.total, 1))
        return count_up and (1 - r) or r
    end

    local function fill_color(ratio)
        local c = ratio <= low_pct and low_col or ratio <= med_pct and med_col or high_col
        return 255, c.r, c.g, c.b
    end

    local px      = settings.pos.x
    local py      = settings.pos.y
    local right_x = px + BAR_H + ICON_GAP + BAR_W + COLUMN_GAP
    local cpos    = settings.custom_pos or {x = px, y = py}

    local row_idx = 1
    local sec_idx = 1

    local function draw_row(slot_row, row, icon_x, bar_x, bar_y)
        local p = slot_row.prims

        -- Icon or coloured dot
        local icon_id, icon_cat, icon_job = resolve_icon(row)
        local path = icon_id and get_icon_path(icon_cat, icon_id, icon_job)
        if path then
            show_image(slot_row.icon, icon_x, bar_y, path)
            prim_hide(p.dot)
        else
            hide(slot_row.icon)
            local dc = dot_colors[row.cat] or dot_colors.custom
            prim_color(p.dot, 255, dc[1], dc[2], dc[3])
            prim_rect(p.dot, icon_x, bar_y, BAR_H, BAR_H)
        end

        -- Flash border — 1px outline just outside the bar, alternates at ~2 Hz.
        -- Created before bg layers so the bg draws on top, exposing only the edge.
        if formatting.flash_lit(row, flash_dur) then
            prim_color(p.brd, 255, flash_col.r, flash_col.g, flash_col.b)
            prim_rect(p.brd, bar_x - 1, bar_y - 1, BAR_W + 2, BAR_H + 2)
        else
            prim_hide(p.brd)
        end

        -- Bar background — 3-layer rounded rect (2px corner radius)
        -- bga: full height, 2px inset each side
        -- bgb: 1px inset all sides
        -- bgc: full width, 2px inset top/bottom
        -- Union of the three traces a smooth 2px rounded corner.
        prim_color(p.bga, bg_col.a, bg_col.r, bg_col.g, bg_col.b)
        prim_rect(p.bga, bar_x + 2, bar_y,     BAR_W - 4, BAR_H)
        prim_color(p.bgb, bg_col.a, bg_col.r, bg_col.g, bg_col.b)
        prim_rect(p.bgb, bar_x + 1, bar_y + 1, BAR_W - 2, BAR_H - 2)
        prim_color(p.bgc, bg_col.a, bg_col.r, bg_col.g, bg_col.b)
        prim_rect(p.bgc, bar_x,     bar_y + 2, BAR_W,     BAR_H - 4)

        -- Bar fill — same 3-layer approach; right edge is also rounded.
        local ratio  = fill_ratio(row)
        local fill_w = math.floor(ratio * BAR_W + 0.5)
        local fa, fr, fg, fb = fill_color(ratio)
        local function fill_layer(name, inset_x, inset_y, width)
            if width > 0 then
                prim_color(name, fa, fr, fg, fb)
                prim_rect(name, bar_x + inset_x, bar_y + inset_y, width, BAR_H - 2 * inset_y)
            else
                prim_hide(name)
            end
        end
        fill_layer(p.flc, 0, 2, fill_w)       -- full fill width, 2px inset top/bottom
        fill_layer(p.flb, 1, 1, fill_w - 2)   -- 1px inset all sides
        fill_layer(p.fla, 2, 0, fill_w - 4)   -- full height, 2px inset each side

        -- Text labels (hidden in slim mode)
        if slim then
            hide(slot_row.label)
            hide(slot_row.time)
            return
        end
        local text_y = bar_y + text_dy
        show_text(slot_row.label, bar_x + BAR_PAD, text_y, formatting.label(row))
        if formatting.hides_time(row, settings) then
            hide(slot_row.time)
        else
            local time_x = ext_text and (bar_x + BAR_W + 2) or (bar_x + BAR_W - TIME_W)
            show_text(slot_row.time, time_x, text_y,
                      formatting.time(formatting.display_seconds(row, count_up), show_tenths))
        end
    end

    local function render_column(column, col_x, start_y)
        local bar_x = col_x + BAR_H + ICON_GAP
        local cur_y = start_y

        for _, sec in ipairs(column) do
            if sec.title and sec_idx <= MAX_SECS then
                show_text(sections[sec_idx], bar_x, cur_y, sec.title)
                cur_y   = cur_y + SEC_H + GAP
                sec_idx = sec_idx + 1
            end

            for _, row in ipairs(sec.rows) do
                if row_idx > MAX_ROWS then break end
                local bar_y = cur_y + math.floor((row_height - BAR_H) / 2)
                draw_row(rows[row_idx], row, col_x, bar_x, bar_y)
                cur_y   = cur_y + row_height
                row_idx = row_idx + 1
            end

            cur_y = cur_y + GAP
        end
    end

    render_column(left,   px,       py + SEC_H + GAP)
    render_column(right,  right_x,  py)
    render_column(custom, cpos.x,   cpos.y)

    hide_from(row_idx, sec_idx)
end

return T
