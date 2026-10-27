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
      refresh    Refresh effect received duration, seconds (own copy only)
      relic      relic hands: Red Mage Enhancing Magic Duration merit gives
                 9s per level instead of 6s
      roll       Phantom Roll duration, seconds
      winning    extra seconds per Winning Streak merit level
      ja         job ability durations: [ability] = {sec = seconds} or {pct = fraction}

    Blue Mage Diffusion Charuqs are not listed: their Diffusion bonus is an
    augment ('Enhances "Diffusion" effect'), so only augmented pieces count, and
    the augment scan finds it on every tier.

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

    -- Refresh received duration ('Increases duration of "Refresh" effect received')
    [11575] = {refresh = 30}, -- Grapevine Cape

    -- Red Mage relic hands: every Vitiation Gloves tier carries the merit bonus
    -- (confirmed in game) but no description says so. Dls. Gloves +2 has it only
    -- when augmented, which the augment scan reads ("Enhancing Magic duration").
    [26984] = {relic = true}, -- Vitiation Gloves
    [26985] = {relic = true}, -- Viti. Gloves +1
    [23201] = {relic = true}, -- Viti. Gloves +2
    [23536] = {relic = true}, -- Viti. Gloves +3
    [24012] = {relic = true}, -- Viti. Gloves +4

    -- Phantom Roll duration ('Inc. "Phantom Roll" effect duration', bg-wiki "Phantom Roll")
    [11220] = {roll = 20},    -- Nvrch. Gants +1
    [11120] = {roll = 40},    -- Nvrch. Gants +2

    -- Job abilities ('Increases "Jig" duration' and the like). `ja` holds what the
    -- scan reads from numbered text: [ability] = {sec = seconds} or {pct = fraction}.
    -- Jigs, bg-wiki "Spectral Jig":
    [15746] = {ja = {Jig = {pct = 0.25}}},  [15747] = {ja = {Jig = {pct = 0.25}}},  -- Dancer's Toe Shoes
    [11393] = {ja = {Jig = {pct = 0.35}}},  [11394] = {ja = {Jig = {pct = 0.35}}},  -- Dnc. Toe Shoes +1
    [28241] = {ja = {Jig = {pct = 0.40}}},  [28242] = {ja = {Jig = {pct = 0.40}}},  -- Maxixi Toe Shoes
    [16360] = {ja = {Jig = {pct = 0.25}}},  -- Etoile Tights
    [16361] = {ja = {Jig = {pct = 0.35}}},  -- Etoile Tights +1
    [10728] = {ja = {Jig = {pct = 0.35}}},  -- Etoile Tights +2
    -- Sambas, bg-wiki "Category:Samba":
    [16138] = {ja = {Samba = {sec = 30}}},  [16139] = {ja = {Samba = {sec = 30}}},  -- Dancer's Tiara
    [11475] = {ja = {Samba = {sec = 30}}},  [11476] = {ja = {Samba = {sec = 30}}},  -- Dancer's Tiara +1
    [27681] = {ja = {Samba = {sec = 40}}},  [27682] = {ja = {Samba = {sec = 40}}},  -- Maxixi Tiara
    -- Flee, bg-wiki "Flee":
    [14094] = {ja = {Flee = {sec = 15}}},   -- Rogue's Poulaines
    [15357] = {ja = {Flee = {sec = 15}}},   -- Rog. Poulaines +1
    [28228] = {ja = {Flee = {sec = 15}}},   -- Pillager's Poulaines

    -- Corsair relic head: +6s per Winning Streak merit level (bg-wiki "Lanun
    -- Tricorne +3"). Every Lanun Tricorne tier carries it, like the Red Mage relic
    -- hands past Dls. Gloves +2; Comm. Tricorne +2 has it only when augmented
    -- ('Enhances "Winning Streak" effect'), which the augment scan reads. The
    -- Lanun Tricorne's '"Phantom Roll" effects +50' is not a duration.
    [26656] = {winning = 6},  -- Lanun Tricorne
    [26657] = {winning = 6},  -- Lanun Tricorne +1
    [23079] = {winning = 6},  -- Lanun Tricorne +2
    [23414] = {winning = 6},  -- Lanun Tricorne +3
    [23934] = {winning = 6},  -- Lanun Tricorne +4
}

-- Path items (Reforged / JSE necks): the item only stores a path letter and a
-- rank, never the percentage, so the value comes from here. `enh` is Enhancing
-- magic duration per rank (0.01 = +1% per rank). bg-wiki "Duelist's Torque +2":
-- Path A at R25 (max) is Enh. Mag. eff. dur. +25%; the three tiers top out at
-- R15 / R20 / R25. Of the 22 job JSE necks, this is the only one with an
-- Enhancing Magic duration effect (checked on bg-wiki's JSE Necks category,
-- Path A at R25): Argute Stole +2 adds Helix duration and Bagua Charm +2 adds
-- Luopan duration, neither of which Timers2 tracks.
--
-- `roll` is Phantom Roll duration in seconds at the path's top rank
-- (`max_rank`), counted only from the main hand ("All augments are active only
-- when the weapon is in your Main Hand", bg-wiki). Path C at max rank: Lanun
-- Knife +45 (R20), Rostam +60 (R25); Comm. Knife +30 (bg-wiki "Phantom Roll"),
-- its top rank taken as R15 like the first of three tiers elsewhere. Below the
-- top rank the value is scaled by rank: bg-wiki gives no per-rank table, so
-- that part is an estimate and `//timers2 gear` says so.
M.paths = {
    [25441] = {A = {enh = 0.01}},   -- Duelist's Torque
    [25442] = {A = {enh = 0.01}},   -- Dls. Torque +1
    [25443] = {A = {enh = 0.01}},   -- Dls. Torque +2
    [21579] = {C = {roll = 30, max_rank = 15, main = true}},   -- Comm. Knife
    [21580] = {C = {roll = 45, max_rank = 20, main = true}},   -- Lanun Knife
    [21581] = {C = {roll = 60, max_rank = 25, main = true}},   -- Rostam
}

-- Carnwenhan's description gives a numeral instead of a percentage: I (75) 10%,
-- II (80) 20% (bg-wiki "Carnwenhan (Level 80)"), III (85) 30%, IV (90/95) 40%,
-- V (99/119) 50%.
M.songNumerals = {I = 0.10, II = 0.20, III = 0.30, IV = 0.40, V = 0.50}

-- Armor sets that boost Enhancing Magic cast on others while Composure is up:
-- +10/20/35/50% for 2/3/4/5 pieces (bg-wiki). Estoqueur +2 and every Lethargy
-- tier count together (confirmed in game).
M.composureSetBonus = {0, 0.10, 0.20, 0.35, 0.50}  -- indexed by piece count 1..5

return M
