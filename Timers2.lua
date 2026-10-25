--[[
Copyright © 2024, Gol-exe
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Timers2 nor the names of its contributors may be
      used to endorse or promote products derived from this software without
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL Gol-exe BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

_addon.name     = 'Timers2'
_addon.author   = 'Gol-exe'
_addon.version  = '2.2.0'
_addon.commands = {'timers2', 'ti2'}

local config = require('config')
-- Windower's standard extensions (table, list, set and string helpers); the
-- texts and images libraries the themes use expect them to be loaded.
require('logger')
require('tables')
require('lists')
require('sets')
require('strings')

local data          = require('data')
local buff_duration = require('buff_duration')
local tracker       = require('tracker')
local commands      = require('commands')

-- Both themes are loaded once at startup; switching is just changing the pointer.
local themes = {
    classic = require('themes/classic'),
    slim    = require('themes/slim'),
}
local theme_names = {'classic', 'slim'}

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local defaults = {
    pos                = {x = 100, y = 100},
    custom_pos         = {x = 480, y = 250},
    show_abilities     = true,
    show_spells        = true,
    show_buffs         = true,
    update_interval    = 0.5,
    ability_whitelist  = {},
    spell_whitelist    = {},
    buff_blacklist     = {},
    sort_mode          = 'duration',   -- 'duration' | 'name' | 'player' | 'creation'
    direction          = 'down',       -- 'down' = time remaining | 'up' = time elapsed
    recast_low_to_high = true,         -- soonest recast available shown first
    buff_low_to_high   = false,        -- longest buff remaining shown first
    custom_low_to_high = false,        -- longest custom timer shown first
    recast_limit             = 0,            -- 0 = no limit
    buff_limit               = 0,
    custom_limit             = 0,
    condense_party_threshold = 2,           -- collapse party buffs shared by N+ members into one row (0 = off)
    show_tenths        = true,         -- sub-second display when < 10s remaining
    calibrate          = false,        -- print our duration estimate beside the server's after each cast
    show_1hour_name    = false,        -- hide timer for SP abilities (recast_id 0/254 — shared-ID "1-hour" abilities)
    group_type         = 'start',      -- 'start' | 'character' | 'none'
    filters            = {},
    active_filter      = '',
    theme              = 'classic',    -- 'classic' | 'slim'
    themes             = {             -- each theme's own settings and defaults live in its file
        classic = themes.classic.defaults,
        slim    = themes.slim.defaults,
    },
}

-- Global so the test harness can flip settings (calibrate) the addon reads.
settings = config.load(defaults)

local current_theme = themes[settings.theme] or themes.classic
local frame_time    = 0

tracker.init(settings)
commands.init(settings, {
    names  = theme_names,
    switch = function(name)
        current_theme.unload()
        current_theme = themes[name]
        current_theme.load(settings)
    end,
    reload = function() current_theme.load(settings) end,
})

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
windower.register_event('load', 'login', function()
    current_theme.load(settings)
    tracker.login()
    buff_duration.warm_up()   -- loads item data and carried gear now, not on the first cast
end)

windower.register_event('unload', function()
    current_theme.unload()
end)

windower.register_event('logout', tracker.logout)
windower.register_event('job change', tracker.job_change)
windower.register_event('zone change', tracker.zone_change)
windower.register_event('incoming chunk', tracker.incoming)

windower.register_event('prerender', function()
    local curr = os.clock()
    if curr > frame_time + settings.update_interval then
        frame_time = curr
        tracker.tick()
        current_theme.update(data.collect(settings), settings)
    end
end)

windower.register_event('addon command', commands.handle)
