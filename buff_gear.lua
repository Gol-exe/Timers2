--[[
    Fallbacks for buff_duration.lua's gear scan.

    buff_duration.lua reads each worn item's in-game description (Windower's
    res.item_descriptions) and its augments, so almost nothing needs listing
    here. This file holds only items whose description states no number, e.g.
    "Increases song effect duration" or "Enhances "Perpetuance" effect", plus
    effects that live in hidden item data. Use `//timers2 gear` to see which
    worn pieces the scan flagged as unreadable.

    Item ids are Windower's items.lua ids. Keys of each entry:
      enh        Enhancing magic duration, fraction (0.10 = +10%)
      regen      Regen effect duration, seconds
      perp       Perpetuance multiplier bonus (2 + perp)
      song       Song duration, fraction
      relic      relic hands: Red Mage Enhancing Magic Duration merit gives
                 9s per level instead of 6s
      diffusion  Blue Mage Diffusion Charuqs: +5% per Diffusion merit rank

    Values come from bg-wiki and lenonk/Timers (addons/timers/duration/*),
    which derives from Thorny's duration tables:
    https://github.com/lenonk/Timers

    Copyright (c) 2022 Thorny

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]

local M = {}

M.gaps = {
    -- Enhancing magic duration (description says "Increases enhancing magic effect duration")
    [27947] = {enh = 0.15},   -- Atrophy Gloves
    [11248] = {enh = 0.10},   -- Estq. Houseaux +1
    [11148] = {enh = 0.20},   -- Estq. Houseaux +2
    [16204] = {enh = 0.10},   -- Estoqueur's Cape

    -- Regen effect duration (description says "Increases "Regen" effect duration")
    [28092] = {regen = 18},   -- Theo. Pantaloons
    [11206] = {regen = 9},    -- Orison Mitts +1
    [11106] = {regen = 18},   -- Orison Mitts +2
    [27787] = {regen = 20},   -- Runeist Bandeau

    -- Perpetuance ("Enhances "Perpetuance" effect")
    [11223] = {perp = 0.25},  -- Svnt. Bracers +1
    [11123] = {perp = 0.5},   -- Svnt. Bracers +2

    -- Song duration ("Increases song effect duration", no number)
    [19000] = {song = 0.10},  -- Carnwenhan (75)
    [20629] = {song = 0.05},  -- Legato Dagger
    [18575] = {song = 0.25},  -- Daurdabla (90)
    [18576] = {song = 0.30},  -- Daurdabla (95)
    [18571] = {song = 0.30},  -- Daurdabla (99)
    [18839] = {song = 0.30},  -- Daurdabla (99, Afterglow)
    [11618] = {song = 0.10},  -- Aoidos' Matinee
    [11193] = {song = 0.05},  -- Aoidos' Hngrln. +1
    [11093] = {song = 0.10},  -- Aoidos' Hngrln. +2
    [28074] = {song = 0.10},  -- Mdk. Shalwar +1
    [28232] = {song = 0.10},  -- Brioso Slippers

    -- Hidden item data (not in the description)
    [23536] = {relic = true},                                   -- Viti. Gloves +3
    [10745] = {diffusion = true},                               -- Mirage Charuqs +2
    [27358] = {diffusion = true}, [27359] = {diffusion = true}, -- Luhlaza Charuqs, +1
    [23346] = {diffusion = true}, [23681] = {diffusion = true}, -- Luhlaza Charuqs +2, +3
}

-- Path items (Reforged / JSE necks): the item only stores a path letter and a
-- rank, never the percentage, so the value comes from here. `enh` is Enhancing
-- magic duration per rank (0.01 = +1% per rank). bg-wiki "Duelist's Torque +2":
-- Path A at R25 (max) is Enh. Mag. eff. dur. +25%; the three tiers top out at
-- R15 / R20 / R25. Of the 22 job JSE necks, this is the only one with an
-- Enhancing Magic duration effect (checked on bg-wiki's JSE Necks category,
-- Path A at R25): Argute Stole +2 adds Helix duration and Bagua Charm +2 adds
-- Luopan duration, neither of which Timers2 tracks.
M.paths = {
    [25441] = {A = {enh = 0.01}},   -- Duelist's Torque
    [25442] = {A = {enh = 0.01}},   -- Dls. Torque +1
    [25443] = {A = {enh = 0.01}},   -- Dls. Torque +2
}

-- Carnwenhan's description gives a numeral instead of a percentage.
M.songNumerals = {I = 0.10, II = 0.25, III = 0.30, IV = 0.40, V = 0.50}

-- Armor sets that boost Enhancing Magic cast on others while Composure is up:
-- +10/20/35/50% for 2/3/4/5 pieces of the same set and tier (bg-wiki).
M.composureSetBonus = {0, 0.10, 0.20, 0.35, 0.50}  -- indexed by piece count 1..5

return M
