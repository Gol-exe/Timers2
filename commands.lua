--[[
    Chat commands for Timers2 (//timers2 or //ti2).

    Every command is a row in COMMANDS: its name, aliases, how it is typed and
    what it changes. Parsing, saving, the reply and the help text all come from
    that row, so a usage message cannot drift from what the command accepts.
    Theme settings (//timers2 classic ..., //timers2 slim ...) work the same way
    through THEME_OPTIONS, and filter subcommands through FILTER_COMMANDS.

    Interface: init(settings, themes), handle(command, ...), help_lines()
      themes = {names = {...}, switch = function(name), reload = function()}
]]

local config        = require('config')
local data          = require('data')
local buff_duration = require('buff_duration')
local formatting    = require('formatting')
local naturalist    = require('naturalist')

local M = {}

local settings = {}
local themes   = {names = {}, switch = function() end, reload = function() end}

function M.init(addon_settings, theme_control)
    settings, themes = addon_settings, theme_control
end

local function say(text) windower.add_to_chat(8, '[Timers2] ' .. text) end
local function save() config.save(settings) end
local function on_off(value) return value and 'ON' or 'OFF' end

-- "name usage", without a trailing space when the usage is empty.
local function typed(...)
    local parts = {}
    for _, part in ipairs({...}) do
        if part ~= '' then parts[#parts + 1] = part end
    end
    return table.concat(parts, ' ')
end

local function usage(...) say('Usage: //timers2 ' .. typed(...)) end

-- Arguments arrive as a plain array; these read it front to back. The brackets
-- matter: on an empty list Lua 5.1's table.remove returns no value at all, and
-- tonumber() of no value raises an error where tonumber(nil) returns nil.
local function take(args) return (table.remove(args, 1)) end
local function take_lower(args) return (table.remove(args, 1) or ''):lower() end
local function rest(args) return table.concat(args, ' ') end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function add_or_remove(action)
    return action == 'add' or action == 'remove'
end

-------------------------------------------------------------------------------
-- Command kinds. Each has the arguments it takes (for usage and help) and what
-- running it does; run returns false when the arguments do not fit.
-------------------------------------------------------------------------------
local KINDS = {}

-- Flips a boolean setting. `words` = {on, off} reads "Abilities shown.";
-- without it the reply is "Show tenths: ON.", plus `note_on` when switched on.
KINDS.toggle = {
    usage = function() return '' end,
    run = function(spec)
        local value = not settings[spec.key]
        settings[spec.key] = value
        save()
        if spec.words then
            say(('%s %s.'):format(spec.label, value and spec.words[1] or spec.words[2]))
        else
            say(('%s: %s%s.'):format(spec.label, on_off(value),
                value and spec.note_on and (' (' .. spec.note_on .. ')') or ''))
        end
    end,
}

-- One of a fixed list of words. `store` turns the word into the saved value;
-- `explain` adds a remark per word to the reply.
KINDS.choice = {
    usage = function(spec) return '<' .. table.concat(spec.choices, '|') .. '>' end,
    run = function(spec, args)
        local value = take_lower(args)
        if not contains(spec.choices, value) then return false end
        if spec.store then settings[spec.key] = spec.store(value) else settings[spec.key] = value end
        save()
        say(('%s: %s%s.'):format(spec.label, value,
            spec.explain and (' (' .. spec.explain[value] .. ')') or ''))
    end,
}

-- A whole number, 0 or more.
KINDS.count = {
    usage = function() return '<N>' end,
    run = function(spec, args)
        local n = tonumber(take(args))
        if not n or n < 0 then return false end
        settings[spec.key] = math.floor(n)
        save()
        say(('%s: %d.'):format(spec.label, settings[spec.key]))
    end,
}

-- A positive number of seconds.
KINDS.seconds = {
    usage = function() return '<seconds>' end,
    run = function(spec, args)
        local n = tonumber(take(args))
        if not n or n <= 0 then return false end
        settings[spec.key] = n
        save()
        say(('%s: %ss.'):format(spec.label, n))
    end,
}

-- A screen position {x, y}.
KINDS.position = {
    usage = function() return '<x> <y>' end,
    run = function(spec, args)
        local x, y = tonumber(take(args)), tonumber(take(args))
        if not x or not y then return false end
        settings[spec.key].x = math.floor(x)
        settings[spec.key].y = math.floor(y)
        save()
        say(('%s: %d, %d.'):format(spec.label, settings[spec.key].x, settings[spec.key].y))
    end,
}

-- Anything else: `run(args)` does the work; `usage` is a string, or a function
-- for usage that depends on runtime state.
KINDS.custom = {
    usage = function(spec)
        if type(spec.usage) == 'function' then return spec.usage() end
        return spec.usage or ''
    end,
    run = function(spec, args) return spec.run(args) end,
}

-------------------------------------------------------------------------------
-- Theme settings
-------------------------------------------------------------------------------
local function read_numbers(args, count)
    local values = {}
    for i = 1, count do
        values[i] = tonumber(take(args))
        if not values[i] then return nil end
    end
    return values
end

-- How each kind of theme setting is typed and stored. apply returns false when
-- the arguments do not fit, otherwise true and an optional reply.
local OPTION_KINDS = {
    rgb = {usage = 'R G B', apply = function(tc, option, args)
        local v = read_numbers(args, 3)
        if not v then return false end
        tc[option.field] = {r = v[1], g = v[2], b = v[3]}
        return true
    end},
    argb = {usage = 'A R G B', apply = function(tc, option, args)
        local v = read_numbers(args, 4)
        if not v then return false end
        tc[option.field] = {a = v[1], r = v[2], g = v[3], b = v[4]}
        return true
    end},
    fraction = {usage = '<0-1>', apply = function(tc, option, args)
        local p = tonumber(take(args))
        if not p or p < 0 or p > 1 then return false end
        tc[option.field] = p
        return true
    end},
    integer = {usage = '<N>', apply = function(tc, option, args)
        local n = tonumber(take(args))
        if not n then return false end
        tc[option.field] = math.floor(n)
        return true
    end},
    toggle = {usage = '', apply = function(tc, option)
        tc[option.field] = not tc[option.field]
        return true, ('%s: %s.'):format(option.label, on_off(tc[option.field]))
    end},
    flash = {usage = '<seconds> [R G B]', apply = function(tc, _, args)
        local seconds = tonumber(take(args))
        if not seconds then return false end
        tc.flash_duration = seconds
        local v = read_numbers(args, 3)
        if v then tc.flash_color = {r = v[1], g = v[2], b = v[3]} end
        return true
    end},
    font = {usage = '<name> [size]', apply = function(tc, _, args)
        local name = take(args)
        if not name then return false end
        tc.font_name = name
        local size = tonumber(take(args))
        if size then tc.font_size = size end
        return true
    end},
}

-- `only` limits a setting to one theme; `reload` rebuilds that theme's text
-- objects, since fonts and text colors are set when they are created.
local THEME_OPTIONS = {
    {name = 'highcolor',  kind = 'rgb',      field = 'high_color',  only = 'classic'},
    {name = 'medcolor',   kind = 'rgb',      field = 'med_color',   only = 'classic'},
    {name = 'lowcolor',   kind = 'rgb',      field = 'low_color',   only = 'classic'},
    {name = 'medpercent', kind = 'fraction', field = 'med_percent', only = 'classic'},
    {name = 'lowpercent', kind = 'fraction', field = 'low_percent', only = 'classic'},
    {name = 'flash',      kind = 'flash'},
    {name = 'spacing',    kind = 'integer',  field = 'bar_spacing', only = 'classic'},
    {name = 'bgcolor',    kind = 'argb',     field = 'bg_color',    only = 'classic'},
    {name = 'textcolor',  kind = 'argb',     field = 'text_color',  reload = true},
    {name = 'font',       kind = 'font',     reload = true},
    {name = 'bold',       kind = 'toggle',   field = 'font_bold',   label = 'Bold text',   reload = true},
    {name = 'slim',       kind = 'toggle',   field = 'slim_mode',   label = 'Slim mode',   only = 'classic'},
    {name = 'extend',     kind = 'toggle',   field = 'extend_text', label = 'Extend text', only = 'classic'},
}

local function theme_options(theme_name)
    local list = {}
    for _, option in ipairs(THEME_OPTIONS) do
        if not option.only or option.only == theme_name then list[#list + 1] = option end
    end
    return list
end

local function theme_setting(theme_name, args)
    local tc = settings.themes and settings.themes[theme_name]
    if not tc then say('Theme settings not found: ' .. theme_name); return end

    local name = take_lower(args)
    local options = theme_options(theme_name)
    if name == '' then
        say(theme_name .. ' settings:')
        for _, option in ipairs(options) do
            windower.add_to_chat(8, '  ' .. typed(theme_name, option.name, OPTION_KINDS[option.kind].usage))
        end
        return
    end

    local option
    for _, candidate in ipairs(options) do
        if candidate.name == name then option = candidate end
    end
    if not option then
        local names = {}
        for _, candidate in ipairs(options) do names[#names + 1] = candidate.name end
        say(('Unknown %s setting "%s". Settings: %s.'):format(theme_name, name, table.concat(names, ', ')))
        return
    end

    local kind = OPTION_KINDS[option.kind]
    local ok, reply = kind.apply(tc, option, args)
    if not ok then usage(theme_name, option.name, kind.usage); return end
    save()
    if option.reload and settings.theme == theme_name then themes.reload() end
    say(reply or ('%s.%s updated.'):format(theme_name, option.name))
end

-------------------------------------------------------------------------------
-- Filters
-------------------------------------------------------------------------------
-- A built-in filter cannot be changed; says so and returns true for one.
local function builtin(fname, verb)
    if not data.builtin_filters[fname] then return false end
    say(('"%s" is a built-in filter and cannot be %s.'):format(fname, verb))
    return true
end

local FILTER_COMMANDS = {
    {name = 'create', usage = '<name>', run = function(args)
        local fname = rest(args):lower()
        if fname == '' then return false end
        if builtin(fname, 'replaced') then return end
        if settings.filters[fname] then
            say(('Filter "%s" already exists.'):format(fname))
            return
        end
        settings.filters[fname] = {categories = {}, sort = '', whitelist = {}}
        save()
        say(('Filter "%s" created.'):format(fname))
    end},

    {name = 'delete', usage = '<name>', run = function(args)
        local fname = rest(args):lower()
        if builtin(fname, 'deleted') then return end
        if not settings.filters[fname] then
            say(('No filter "%s".'):format(fname))
            return
        end
        settings.filters[fname] = nil
        if settings.active_filter == fname then settings.active_filter = '' end
        save()
        say(('Filter "%s" deleted.'):format(fname))
    end},

    {name = 'select', usage = '<name|none>', run = function(args)
        local fname = rest(args):lower()
        if fname == '' or fname == 'none' then
            settings.active_filter = ''
            save()
            say('Filter cleared.')
        elseif settings.filters[fname] or data.builtin_filters[fname] then
            settings.active_filter = fname
            save()
            say(('Filter "%s" active.'):format(fname))
        else
            say(('No filter "%s".'):format(fname))
        end
    end},

    {name = 'list', usage = '', run = function()
        local function marker(fname) return settings.active_filter == fname and ' [ACTIVE]' or '' end
        say('Built-in filters:')
        for fname, fdata in pairs(data.builtin_filters) do
            windower.add_to_chat(8, ('  "%s"%s — %s'):format(fname, marker(fname), fdata.description or ''))
        end
        say('Saved filters:')
        local any = false
        for fname, fdata in pairs(settings.filters) do
            any = true
            local cats = {}
            for c in pairs(fdata.categories or {}) do table.insert(cats, c) end
            windower.add_to_chat(8, ('  "%s"%s  sort=%s  cats=%s'):format(
                fname, marker(fname),
                (fdata.sort ~= '' and fdata.sort) or 'default',
                #cats > 0 and table.concat(cats, ',') or 'all'))
        end
        if not any then windower.add_to_chat(8, '  (none)') end
    end},

    {name = 'sort', usage = '<filter> <' .. table.concat(data.sort_modes, '|') .. '>', run = function(args)
        local fname = take_lower(args)
        local mode  = take_lower(args)
        if builtin(fname, 'modified') then return end
        if not settings.filters[fname] or not contains(data.sort_modes, mode) then return false end
        settings.filters[fname].sort = mode
        save()
        say(('Filter "%s" sort: %s.'):format(fname, mode))
    end},

    {name = 'category', aliases = {'cat'}, usage = '<filter> <add|remove> <ability|spell|buff|custom>', run = function(args)
        local fname  = take_lower(args)
        local action = take_lower(args)
        local cat    = take_lower(args)
        if builtin(fname, 'modified') then return end
        if not settings.filters[fname] or not add_or_remove(action)
                or not contains({'ability', 'spell', 'buff', 'custom'}, cat) then
            return false
        end
        settings.filters[fname].categories[cat] = action == 'add' or nil
        save()
        say(('Filter "%s": %s category "%s".'):format(fname, action, cat))
    end},

    {name = 'whitelist', aliases = {'wl'}, usage = '<filter> <add|remove> <name>', run = function(args)
        local fname  = take_lower(args)
        local action = take_lower(args)
        local entry  = rest(args)
        if builtin(fname, 'modified') then return end
        if not settings.filters[fname] or not add_or_remove(action) or entry == '' then return false end
        settings.filters[fname].whitelist[entry:lower()] = action == 'add' or nil
        save()
        say(('Filter "%s" whitelist: %s "%s".'):format(fname, action, entry))
    end},
}

local function find(list, name)
    for _, spec in ipairs(list) do
        if spec.name == name or contains(spec.aliases or {}, name) then return spec end
    end
end

local function filter_command(args)
    local sub  = take_lower(args)
    local spec = find(FILTER_COMMANDS, sub)
    if not spec then
        say('Filter subcommands:')
        for _, candidate in ipairs(FILTER_COMMANDS) do
            windower.add_to_chat(8, '  ' .. typed('filter', candidate.name, candidate.usage))
        end
        return
    end
    if spec.run(args) == false then usage('filter', spec.name, spec.usage) end
end

-------------------------------------------------------------------------------
-- The command table, in help order
-------------------------------------------------------------------------------
local sort_directions = {'asc', 'desc'}
local function ascending(word) return word == 'asc' end

local COMMANDS = {
    {name = 'theme', kind = 'custom', help = 'Switch display theme',
     usage = function() return '<' .. table.concat(themes.names, '|') .. '>' end,
     run = function(args)
        local name = take_lower(args)
        if not contains(themes.names, name) then return false end
        themes.switch(name)
        settings.theme = name
        save()
        say(('Theme: %s.'):format(name))
    end},
    -- gear, last and calibrate check the duration estimates: they work, but
    -- `hidden` keeps them out of the help so they do not confuse everyday use.
    {name = 'gear', kind = 'custom', hidden = true, help = 'Show the duration gear and augments detected',
     run = function()
        for _, line in ipairs(buff_duration.describe_gear()) do say(line) end
    end},
    {name = 'last', kind = 'custom', hidden = true, help = 'Show how the last buff duration was calculated',
     run = function()
        for _, line in ipairs(buff_duration.describe_last()) do say(line) end
        say(naturalist.describe())
    end},
    {name = 'calibrate', kind = 'toggle', hidden = true, key = 'calibrate', label = 'Calibration output',
     note_on = 'cast a buff on yourself to compare our estimate with the server',
     help = 'Toggle estimate-vs-server output for your own buffs'},

    {name = 'create', aliases = {'c'}, kind = 'custom', usage = '<name> <seconds>', help = 'Start a custom timer',
     run = function(args)
        local name     = take(args)
        local duration = tonumber(take(args))
        if not name or not duration or duration <= 0 then return false end
        data.custom_timers[name] = {
            expires = os.clock() + duration, duration = duration,
            created_order = data.next_order,
        }
        data.next_order = data.next_order + 1
        say(('Created timer "%s" (%s).'):format(name, formatting.time(duration, false)))
    end},
    {name = 'delete', aliases = {'d'}, kind = 'custom', usage = '<name>', help = 'Remove a custom timer',
     run = function(args)
        local name = rest(args)
        if not data.custom_timers[name] then
            say(('No custom timer "%s".'):format(name))
            return
        end
        data.custom_timers[name] = nil
        say(('Deleted timer "%s".'):format(name))
    end},

    {name = 'abilities', aliases = {'ab'}, kind = 'toggle', key = 'show_abilities', label = 'Abilities',
     words = {'shown', 'hidden'}, help = 'Show or hide ability recasts'},
    {name = 'spells', aliases = {'sp'}, kind = 'toggle', key = 'show_spells', label = 'Spells',
     words = {'shown', 'hidden'}, help = 'Show or hide spell recasts'},
    {name = 'buffs', aliases = {'bu'}, kind = 'toggle', key = 'show_buffs', label = 'Buffs',
     words = {'shown', 'hidden'}, help = 'Show or hide buff timers'},

    {name = 'sort', kind = 'choice', key = 'sort_mode', choices = data.sort_modes, label = 'Sort mode',
     help = 'Row order in every section'},
    {name = 'group', kind = 'choice', key = 'group_type', choices = {'start', 'character', 'none'},
     label = 'Group type', help = 'How buff rows are grouped'},
    {name = 'direction', aliases = {'dir'}, kind = 'choice', key = 'direction', choices = {'up', 'down'},
     explain = {up = 'show elapsed', down = 'show remaining'}, label = 'Direction',
     help = 'up = time elapsed, down = time remaining'},
    {name = 'recastdir', kind = 'choice', key = 'recast_low_to_high', choices = sort_directions, store = ascending,
     label = 'Recast sort direction', help = 'Recast sort direction'},
    {name = 'buffdir', kind = 'choice', key = 'buff_low_to_high', choices = sort_directions, store = ascending,
     label = 'Buff sort direction', help = 'Buff sort direction'},
    {name = 'customdir', kind = 'choice', key = 'custom_low_to_high', choices = sort_directions, store = ascending,
     label = 'Custom sort direction', help = 'Custom timer sort direction'},

    {name = 'recastlimit', kind = 'count', key = 'recast_limit', label = 'Recast row limit',
     help = 'Most recast rows shown (0 = no limit)'},
    {name = 'bufflimit', kind = 'count', key = 'buff_limit', label = 'Buff row limit',
     help = 'Most rows per buff section (0 = no limit)'},
    {name = 'customlimit', kind = 'count', key = 'custom_limit', label = 'Custom row limit',
     help = 'Most custom timer rows (0 = no limit)'},

    {name = 'pos', kind = 'position', key = 'pos', label = 'Position', help = 'Main panel position'},
    {name = 'custompos', kind = 'position', key = 'custom_pos', label = 'Custom timer position',
     help = 'Custom timer position'},

    {name = 'tenths', kind = 'toggle', key = 'show_tenths', label = 'Show tenths',
     help = 'Toggle tenths of a second under 10s'},
    {name = '1hourname', kind = 'toggle', key = 'show_1hour_name', label = 'Show 1-hour name only',
     help = 'Toggle hiding the time of 1-hour SP abilities'},
    {name = 'interval', aliases = {'i'}, kind = 'seconds', key = 'update_interval', label = 'Update interval',
     help = 'Refresh rate (default 0.5)'},

    {name = 'whitelist', aliases = {'wl'}, kind = 'custom', usage = '<abilities|spells> <add|remove> <name>',
     help = 'Only show the listed recasts',
     run = function(args)
        local list_type = take_lower(args)
        local action    = take_lower(args)
        local entry     = rest(args)
        local list_key  = ({abilities = 'ability_whitelist', spells = 'spell_whitelist'})[list_type]
        if not list_key or not add_or_remove(action) or entry == '' then return false end
        settings[list_key][entry:lower()] = action == 'add' or nil
        save()
        say(('%s whitelist: %s "%s".'):format(list_type, action, entry))
    end},
    {name = 'blacklist', aliases = {'bl'}, kind = 'custom', usage = '<add|remove> <buff name>',
     help = 'Never show the listed buffs',
     run = function(args)
        local action = take_lower(args)
        local entry  = rest(args)
        if not add_or_remove(action) or entry == '' then return false end
        settings.buff_blacklist[entry:lower()] = action == 'add' or nil
        save()
        say(('Buff blacklist: %s "%s".'):format(action, entry))
    end},
    {name = 'filter', aliases = {'f'}, kind = 'custom', usage = '<subcommand> ...',
     help = 'Named filters (//timers2 filter lists the subcommands)',
     run = filter_command},

    {name = 'classic', kind = 'custom', usage = '<setting> ...',
     help = 'Classic theme settings (//timers2 classic lists them)',
     run = function(args) theme_setting('classic', args) end},
    {name = 'slim', kind = 'custom', usage = '<setting> ...',
     help = 'Slim theme settings (//timers2 slim lists them)',
     run = function(args) theme_setting('slim', args) end},

    {name = 'help', aliases = {'h'}, kind = 'custom', help = 'This list',
     run = function()
        for _, line in ipairs(M.help_lines()) do windower.add_to_chat(8, line) end
    end},
}

local function command_usage(spec)
    return KINDS[spec.kind].usage(spec)
end

function M.help_lines()
    local lines = {('Timers2 v%s'):format(tostring(_addon and _addon.version))}
    for _, spec in ipairs(COMMANDS) do
        if not spec.hidden then
            lines[#lines + 1] = ('  %-40s %s'):format(typed(spec.name, command_usage(spec)), spec.help)
        end
    end
    return lines
end

function M.handle(command, ...)
    command = command and command:lower() or 'help'
    local spec = find(COMMANDS, command)
    if not spec then
        say(('Unknown command "%s". Type //timers2 help.'):format(command))
        return
    end
    if KINDS[spec.kind].run(spec, {...}) == false then
        usage(spec.name, command_usage(spec))
    end
end

return M
