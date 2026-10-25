--[[
    Text shared by the themes and the calibrate output: clock strings, row
    labels and the values a row displays. No display primitives here.
]]

local M = {}

-- "m:ss", rounded to the nearest second.
function M.mmss(seconds)
    seconds = math.floor(seconds + 0.5)
    return ('%d:%02d'):format(math.floor(seconds / 60), seconds % 60)
end

-- A row's time: tenths of a second under 10s when show_tenths is on, else "m:ss"
-- with the seconds dropped (a timer reads 0:09 until it is really under 9s).
function M.time(seconds, show_tenths)
    if show_tenths and seconds > 0 and seconds < 10 then
        return ('%.1f'):format(seconds)
    end
    if seconds <= 0 then return '0:00' end
    return ('%d:%02d'):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

-- "Shell V [6]" for a condensed row, "Haste [Name]" for a party row in the
-- flat (group none) list, otherwise the name alone.
function M.label(row)
    if row.count then return row.name .. ' [' .. row.count .. ']' end
    if row.party_name then return row.name .. ' [' .. row.party_name .. ']' end
    return row.name
end

-- Seconds the row shows: what is left, or with direction "up" what has passed.
function M.display_seconds(row, count_up)
    if count_up then return math.max(0, row.total - row.remaining) end
    return row.remaining
end

-- The shared SP-ability recasts (ids 0 and 254) show no time with
-- show_1hour_name on.
function M.hides_time(row, settings)
    return settings.show_1hour_name == true and (row.recast_id == 0 or row.recast_id == 254)
end

-- True while a buff row about to expire is in the lit half of its ~2 Hz flash.
function M.flash_lit(row, flash_duration)
    return flash_duration > 0 and row.cat == 'buff' and row.remaining <= flash_duration
        and math.floor(os.clock() * 2) % 2 == 0
end

-- True when a buff row is inside its flash window at all (lit or not).
function M.flashing(row, flash_duration)
    return flash_duration > 0 and row.cat == 'buff' and row.remaining <= flash_duration
end

return M
