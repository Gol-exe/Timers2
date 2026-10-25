--[[
    Buff duration helper for Timers2.
    Estimates how long a spell cast on another player will last, in seconds.
    Returns nil for spells it has no data for so the caller can fall back.

    Base durations are ported from lenonk/Timers (addons/timers/duration/*),
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

    Scope: every Enhancing Magic spell with a duration, including the self-only
    ones (Spikes): our own copy's estimate and the Naturalist's Roll measurement
    use them too. Plus buff songs and Blue Magic buffs. Ninjutsu (Utsusemi),
    Dark and Divine Magic (Endark, Dread Spikes, Klimaform), aura (Indi/Geo) and
    enemy-targeted (debuffs, Absorb, Elegy/Lullaby) spells are left out.

    Modelled: equipped duration gear (songs, enhancing, Regen flat seconds),
    duration augments (enhancing %, all-songs levels, relic-hands merit
    augment), Red Mage enhancing merits/job points, Bard song job points (Tenuto, Clarion
    Call, Marcato, 1200 JP gift), White Mage and Scholar Regen job
    points, Light Arts and Tabula Rasa Regen bonus,
    Perpetuance (incl. Savant's/Arbatel bracers), Composure armor-set bonus on
    others, Troubadour, Blue Mage Diffusion (merits + Charuqs) and Unbridled
    Learning Effect II job points. Enhancing and song base durations match Windower's
    res.spells except Invisible/Sneak/Deodorize (random since 2010, see below);
    Blue Magic ones were checked per spell against bg-wiki too
    (self-only buffs are included because Diffusion can hit the party).

    Deliberately ignored: Dynamis/Reive instruments. Naturalist's Roll is not
    computed here: its potency depends on the roll number and the Corsair's gear,
    which we cannot see. naturalist.lua measures it from our own buffs instead
    (using context.results) and the tracker applies it to party members.

    Not applicable: Rune Fencer's Enhancing Magic Received Duration gifts only
    affect spells the Rune Fencer receives, and we cannot see other players' job
    points. (Self-cast buffs use the server-synced expiry instead.)

    Not yet modelled: low-level-target reduction.
    Gear effects are read from the game's own item descriptions and augments
    (see "Gear scan" below), not from per-item tables. buff_gear.lua only lists
    the few items whose text states no number. Odyssey/Reforged path items
    store only a path and rank; the few that matter are in buff_gear.paths.
]]

local res     = require('resources')
local gear    = require('buff_gear')
local extdata = require('extdata')

local M = {}

-- Buff ids (Windower res.buffs)
local COMPOSURE      = 419
local PERPETUANCE    = 469
local TROUBADOUR     = 348
local DIFFUSION      = 356
local LIGHT_ARTS     = 358
local ADDENDUM_WHITE = 401
local TABULA_RASA    = 377
local MARCATO        = 231
local TENUTO         = 455
local CLARION_CALL   = 499

-- Composure triples our own Enhancing Magic only up to this many seconds.
local COMPOSURE_CAP = 1800

-- Job ids (Windower res.jobs)
local WHM, BRD, RDM, BLU, SCH, RUN = 3, 10, 5, 16, 20, 22

-- Rune Fencer job point gifts (bg-wiki "Rune Fencer"): Enhancing Magic received
-- duration +10% at 100 job points spent and another +10% at 1200. Like every
-- gift they count only on a main job at 99.
M.RUNE_FENCER = RUN
function M.rune_fencer_gifts(jp_spent)
    if jp_spent >= 1200 then return 0.20 end
    if jp_spent >= 100 then return 0.10 end
    return 0
end
-- A mastered Rune Fencer (2100 job points) has both.
M.MASTERED_RUNE_FENCER_GIFTS = M.rune_fencer_gifts(2100)

-- Embolden (Rune Fencer, buff 534): the next Enhancing spell its holder
-- receives is stronger but lasts half as long, and uses the buff up (bg-wiki
-- "Embolden"). Evasionist's Cape augments change it; that gear is the Rune
-- Fencer's, which we cannot see.
M.EMBOLDEN = 534
local EMBOLDEN_DURATION = 0.5

-- Our own gifts from our job points: 0 when we are not a 99 Rune Fencer, nil
-- when we are one but the client does not show the job points.
function M.own_rune_fencer_gifts(player)
    if player.main_job_id ~= RUN or player.main_job_level ~= 99 then return 0 end
    local points = player.job_points and player.job_points.run
    return points and points.jp_spent and M.rune_fencer_gifts(points.jp_spent) or nil
end

-- [spell_id] = {base = seconds (nil = computed), kind = string, cap = seconds}
local spells = {}

local function span(first, last)
    local ids = {}
    for id = first, last do ids[#ids + 1] = id end
    return ids
end

local function join(...)
    local ids = {}
    for _, list in ipairs({...}) do
        for _, id in ipairs(list) do ids[#ids + 1] = id end
    end
    return ids
end

local function add(kind, base, ids)
    for _, id in ipairs(ids) do spells[id] = {base = base, kind = kind} end
end

-------------------------------------------------------------------------------
-- Enhancing magic ('enhancing': Perpetuance doubles it)
-------------------------------------------------------------------------------
add('enhancing', 1800, join(span(43, 52), span(125, 134)))                 -- Protect/Shell (+ra)
add('enhancing', 300,  join({53, 54, 476}, span(479, 492)))               -- Blink, Stoneskin, Crusade, Boost/Gain
add('enhancing', 525,  {136, 137, 138})                                    -- Invisible, Sneak, Deodorize: random, see below
add('enhancing', 600,  {55})                                               -- Aquaveil
add('enhancing', 240,  {107})                                              -- Phalanx II
add('enhancing', 180,  join({57, 511, 96, 106, 308, 309, 493, 495, 845, 846, 895},
                            {99}, span(100, 105), span(113, 119),         -- Storms, Enspells
                            span(312, 317), span(857, 864)))              -- Enspell II, Storm II
add('enhancing', 150,  {109, 473, 894})                                    -- Refresh I-III
add('enhancing', 90,   {478})                                              -- Embrava
add('enhancing', 75,   {108})                                              -- Regen
add('enhancing', 60,   {97, 110, 111, 477, 504})                           -- Reprisal, Regen II-V
add('enhancing', 30,   {840})                                              -- Foil
-- Blaze / Ice / Shock Spikes: self-only. Measured in game: Blaze Spikes with
-- +10% gear, five Telchine (+50% augments) and a +28% Naturalist's Roll lasted
-- 6:13 = 180 x (1.10 + 0.28) x 1.50.
add('enhancing', 180,  {249, 250, 251})
spells[55].cap = 1800

-- Invisible, Sneak and Deodorize: since the December 2010 update the base is a
-- random 450 to 600 seconds (bg-wiki), so the estimate uses the middle and the
-- real time comes from the buff lists. Upstream and older resources say 300,
-- which put self-casts under heavy duration gear at half the server's time.
for _, id in ipairs({136, 137, 138}) do
    spells[id].random = true
    spells[id].note   = 'random base duration, 7.5 to 10 minutes'
end

-- Regen also adds Regen-duration gear seconds and the Light Arts / job point
-- bonuses before the multipliers.
for _, id in ipairs({108, 110, 111, 477, 504}) do
    spells[id].regen_gear = true
    spells[id].regen      = true
end

-- Bar-element / Bar-status: flat 8 minutes; enhancing skill only affects potency.
add('enhancing', 480, join(span(60, 78), span(84, 92)))

-- Reraise I-IV: flat, unaffected by modifiers.
add('fixed', 3600, {135, 141, 142, 848})

-------------------------------------------------------------------------------
-- Songs ('song': Troubadour doubles it). Buff songs only.
-------------------------------------------------------------------------------
add('song', 120, join(span(378, 420), span(424, 453), {464, 465, 467, 469, 470}))

-- Song families. Gear descriptions name the family ("Minuet"+1 = +10% to
-- Minuet); songs not listed (Aubade through Fugue, Aria, Dirge) only get the
-- all-songs bonuses.
local FAMILIES = {
    'Minuet', 'Minne', 'Paeon', 'Madrigal', 'Mambo', 'Etude', 'Ballad',
    'March', 'Prelude', 'Mazurka', 'Carol', 'Hymnus', 'Scherzo',
}
local function song_family(name, ids)
    for _, id in ipairs(ids) do spells[id].family = name end
end
song_family('Paeon',    span(378, 385))
song_family('Ballad',   span(386, 388))
song_family('Minne',    span(389, 393))
song_family('Minuet',   span(394, 398))
song_family('Madrigal', {399, 400})
song_family('Prelude',  {401, 402})
song_family('Mambo',    {403, 404})
song_family('March',    {417, 419, 420})
song_family('Etude',    span(424, 437))
song_family('Carol',    span(438, 453))
song_family('Hymnus',   {464})
song_family('Mazurka',  {465, 467})
song_family('Scherzo',  {470})

-------------------------------------------------------------------------------
-- Blue Magic buffs
-------------------------------------------------------------------------------
-- Every one of these can reach a party member via Diffusion. Each value was
-- checked against bg-wiki's spell page and Windower's res.spells duration.
-- Where they disagree the choice is noted; upstream (lenonk/Timers) had
-- Regeneration, Nat. Meditation and Harden Shell at 180s, which neither
-- source supports.
add('blu', 900, {632, 517, 647, 668, 745})                 -- Diamondhide, Metallic Body, Zephyr Mantle, Magic Barrier (wiki's 5 min is wrong; Windower and in-game: 15), Carcharian Verve (see below)
add('blu', 750, {615})                                    -- Plasma Charge: random 10 to 15 minutes, 750 is the middle (see below)
add('blu', 300, {530, 661, 662, 679, 710})                -- Refueling, Animating Wail, Battery Charge, Occultation, Erratic Flutter
add('blu', 180, {613, 636, 674, 685, 696, 750,            -- Reactor Cool, Warm-Up, Fantod, Barrier Tusk, O. Counterstance, Mighty Guard
                   614,                                     -- Saline Coat: the server timer reads 3:00 (measured); bg-wiki says the effect itself ends a minute early, and the buff lists / wear-off messages remove the row if so
                   741})                                    -- Pyric Bulwark (measured 5:12 with Diffusion/Charuqs/JP = 180 x 1.74; bg-wiki and the resources say 5 min)
add('blu', 90,  {547, 642, 658, 664, 700, 737, 655})      -- Cocoon, Amplification, Plenilune Embrace, Regeneration, Nat. Meditation, Harden Shell, Triumphant Roar (wiki's 60 is wrong)
add('blu', 60,  {538})                                    -- Memento Mori
add('blu', 30,  {574})                                    -- Feather Barrier
spells[664].regen_gear = true                               -- Telchine Chasuble etc. extend Regeneration

-- Plasma Charge lasts a random 10 to 15 minutes (confirmed in game; Windower lists 750
-- = the middle, and one cast measured 14:51), so the estimate can only be the expected
-- value; the real time comes from the server's buff list. Shown in the calibrate output.
spells[615].note   = 'random duration, 10 to 15 minutes'
spells[615].random = true

-- Carcharian Verve grants three buffs (Attack Boost, Magic Attack Boost, Aquaveil);
-- only the 15 minute Aquaveil shows, so the timer follows it (buff 39). Its Aquaveil
-- was measured on its own: with 5/5 Diffusion, Luhlaza Charuqs +1 and Unbridled
-- 20/20 it lasts 24:43-24:45 = 900 x (1 + 0.20 + 0.25 + 0.20), the job points
-- adding to the percentage where every other Unbridled spell multiplies by it.
spells[745].status      = 39
spells[745].jp_additive = true

-- Diffusion applies to everything here except Diamondhide and Plenilune Embrace
-- (bg-wiki's Diffusion spell list). Unbridled spells also get the Unbridled
-- Learning Effect II job point bonus.
for id, entry in pairs(spells) do
    if entry.kind == 'blu' and id ~= 632 and id ~= 658 then entry.diffusion = true end
end
for _, id in ipairs({737, 741, 745, 750}) do spells[id].unbridled = true end

-------------------------------------------------------------------------------
-- Caster state
-------------------------------------------------------------------------------

-- The player's active buff ids as a set.
local function buff_set(player)
    local set = {}
    for _, id in pairs(player.buffs or {}) do set[id] = true end
    return set
end

local SLOTS = {
    'main', 'sub', 'range', 'ammo', 'head', 'neck', 'left_ear', 'right_ear',
    'body', 'hands', 'left_ring', 'right_ring', 'back', 'waist', 'legs', 'feet',
}

-- Equipment slot ids used by the server's equip packets (0x050). This is not
-- the same order as SLOTS; it is GearSwap's default_slot_map.
local SLOT_BY_ID = {
    [0] = 'main', 'sub', 'range', 'ammo', 'head', 'body', 'hands', 'legs', 'feet',
    'neck', 'waist', 'left_ear', 'right_ear', 'left_ring', 'right_ring', 'back',
}

-- What each slot holds according to the server: [slot] = {bag=, index=}, or
-- false for a slot the server emptied. A slot with no entry is unknown and is
-- read from client memory.
--
-- The server judges a spell by the gear worn when the cast completes (the
-- midcast set under GearSwap), and GearSwap swaps again as soon as it sees the
-- completion packet. Client memory can lag those swaps, so while swaps are
-- happening we follow the incoming 0x050 stream instead, as GearSwap does;
-- stream order guarantees the state we hold when the completion packet (0x028)
-- arrives is the state the server used. Once no equip packet has arrived for
-- SETTLE seconds, memory has caught up and replaces the tracked state, so a
-- piece the stream never mentioned (or a bad early snapshot) cannot linger.
local worn              = {}
local last_equip_packet = 0
local SETTLE            = 5

local function memory_slot(eq, slot)
    local index = eq and eq[slot]
    if index and index > 0 then return {bag = eq[slot .. '_bag'], index = index} end
    return nil
end

-- Only the equipment table: get_items() without a bag would build every bag.
local function memory_equipment()
    return windower.ffxi.get_items('equipment')
end

-- Replaces the tracked state with what client memory shows.
function M.sync_equipment()
    worn = {}
    local eq = memory_equipment()
    for _, slot in ipairs(SLOTS) do worn[slot] = memory_slot(eq, slot) end
end

-- Feed every incoming 0x050 chunk here: index at byte 5 (0 = unequip), slot at
-- byte 6, bag at byte 7.
function M.handle_equipment_packet(raw)
    local slot = SLOT_BY_ID[raw:byte(6)]
    if not slot then return end
    local index = raw:byte(5)
    worn[slot] = index > 0 and {bag = raw:byte(7), index = index} or false
    last_equip_packet = os.clock()
end

-- [slot] = item table (id, extdata, ...) for everything currently worn.
local function equipped_items()
    local settled = os.clock() - last_equip_packet > SETTLE
    if settled then M.sync_equipment() end

    local eq   -- memory, read only if some slot is unknown while swaps are in flight
    local items = {}
    for _, slot in ipairs(SLOTS) do
        local where = worn[slot]
        if where == nil and not settled then
            eq = eq or memory_equipment()
            where = memory_slot(eq, slot)
        end
        if where then
            local item = windower.ffxi.get_items(where.bag, where.index)
            if item and item.id and item.id > 0 then items[slot] = item end
        end
    end
    return items
end

-------------------------------------------------------------------------------
-- Gear scan
--
-- One pass over the worn items produces every gear-derived number the
-- calculations need. Item effects come from the game's own text, so new gear
-- is picked up without edits here:
--   * the item description (res.item_descriptions), parsed once per item id
--   * the item's decoded augments (Windower's extdata library)
--   * buff_gear.lua, for the few items whose text states no number
-------------------------------------------------------------------------------

-- Item descriptions. Windower's resources library would load the whole
-- res/item_descriptions.lua (5 MB, 23,000 items) the first time anything touched
-- res.item_descriptions, to read at most 16 worn pieces. Instead the lines of the
-- pieces we have not seen yet are read straight out of the file, in one pass, and
-- only their parsed stats are kept. If the file cannot be read, the resources
-- library is the fallback.
local DESCRIPTION_FILE = 'res/item_descriptions.lua'

local description_text = {}     -- [item_id] = English description, or false when there is none
local description_problem = false   -- the last read found neither the file nor the resources table

-- Where the line for `id` starts in the description file's content, or nil.
-- The file has one entry per line, `    [23989] = {id=23989,en="...",ja="..."},`,
-- in ascending id order, so the line is found by bisecting byte offsets rather
-- than scanning all 5 MB for every id. Should the order ever not hold, a plain
-- search still finds it.
local function bisect_entry(content, id)
    local lo, hi = 1, #content
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local line_start = content:find('\n    [', mid, true)
        local line_id = line_start and tonumber(content:match('^\n    %[(%d+)%]', line_start))
        if line_id == id then
            return line_start
        elseif line_id and line_id < id then
            lo = line_start + 1
        else
            hi = mid - 1
        end
    end
    return nil
end
M._bisect_entry = bisect_entry   -- for the tests: checked without the fallback

local function find_entry(content, id)
    return bisect_entry(content, id) or content:find('\n    [' .. id .. '] = ', 1, true)
end

-- Reads the English text of each id in `ids` from the description file. Returns
-- nil when the file cannot be opened.
local function read_descriptions(ids)
    local handle = io.open(windower.windower_path .. DESCRIPTION_FILE, 'rb')
    if not handle then return nil end
    local content = handle:read('*a')
    handle:close()

    local found = {}
    for _, id in ipairs(ids) do
        local line_start = find_entry(content, id)
        local prefix = '\n    [' .. id .. '] = {id=' .. id .. ',en="'
        local text_start = line_start and content:sub(line_start, line_start + #prefix - 1) == prefix
                           and line_start + #prefix - 1
        if text_start then
            local line = content:sub(text_start + 1, (content:find('\n', text_start, true) or #content + 1) - 1)
            local cut, from = nil, 1
            while true do                                   -- the English text ends at the last `",ja="`
                local at = line:find('",ja="', from, true)
                if not at then break end
                cut, from = at, at + 1
            end
            local raw = cut and line:sub(1, cut - 1) or line:gsub('"},?%s*$', '')
            found[id] = raw:gsub('\\n', ' '):gsub('\\"', '"'):gsub('\\\\', '\\')
        end
    end
    return found
end

local function load_descriptions(ids)
    if #ids == 0 then return end
    local found = read_descriptions(ids)
    description_problem = false
    for _, id in ipairs(ids) do
        if found then
            description_text[id] = found[id] or false
        else
            local ok, entry = pcall(function() return res.item_descriptions[id] end)
            description_text[id] = ok and entry and entry.en or false
            if not ok then description_problem = true end
        end
    end
end

-- True when item description data can be read. Without it the scan sees no gear
-- text at all, so `//timers2 gear` reports this.
function M.descriptions_loaded()
    local handle = io.open(windower.windower_path .. DESCRIPTION_FILE, 'rb')
    if handle then
        handle:close()
        return true
    end
    local ok, table_ = pcall(function() return res.item_descriptions end)
    return ok and table_ ~= nil
end

local stats_cache = {}   -- [item_id] = stats

local function parse_description(item_id)
    local stats = {fam = {}}
    if description_text[item_id] == nil then load_descriptions({item_id}) end
    local text = description_text[item_id]
    if not text then return stats end
    text = text:gsub('%s+', ' '):gsub(' effect duration', ' duration')

    -- Effects listed under a zone header only work in that zone (Dynamis and
    -- Reive instruments); they are ignored, so drop everything from the header on.
    local cut
    for _, header in ipairs({'Reives:', 'Dynamis:', 'Dynamis (D):'}) do
        local at = text:find(header, 1, true)
        if at and (not cut or at < cut) then cut = at end
    end
    if cut then text = text:sub(1, cut - 1) end

    local value = text:match('[Ee]nhancing [Mm]agic [Dd]uration ?([+-]%d+)%%')
    if value then stats.enh = tonumber(value) / 100 end

    value = text:match('"Regen" duration %+(%d+)')
    if value then stats.regen = tonumber(value) end

    value = text:match('"Perpetuance"%+(%d+)%%')
    if value then stats.perp = tonumber(value) / 100 end

    value = text:match('[Ss]ong duration %+(%d+)%%')
    if value then stats.song = tonumber(value) / 100 end
    local numeral = text:match('ncreases? song duration ([IVX]+)%f[%A]')
    if numeral and gear.songNumerals[numeral] then
        stats.song = (stats.song or 0) + gear.songNumerals[numeral]
    end

    -- Miracle Cheer: songs last a fixed number of minutes whatever else is worn.
    value = text:match('[Ss]ong duration for party members %+(%d+) min')
    if value then stats.song_fixed = tonumber(value) * 60 end

    value = text:match('[Aa]ll [Ss]ongs %+(%d+)')
    if value then stats.levels = tonumber(value) end
    for _, family in ipairs(FAMILIES) do
        value = text:match('"' .. family .. '"%+(%d+)')
        if value then stats.fam[family] = tonumber(value) end
    end

    stats.composure = text:find('Set: Augments "Composure"', 1, true) ~= nil

    -- A duration effect that is named but carries no number: the scan cannot
    -- read it. Reported by describe_gear so it can be added to buff_gear.lua.
    stats.unreadable = (text:find('nhancing magic duration', 1, true) and not stats.enh)
        or (text:find('"Regen" duration', 1, true) and not stats.regen)
        or (text:find('ncreases song duration', 1, true) and not stats.song and not stats.levels)
        or (text:find('Enhances "Perpetuance"', 1, true) and not stats.perp)
        or false
    return stats
end

local function item_stats(item_id)
    local stats = stats_cache[item_id]
    if not stats then
        stats = parse_description(item_id)
        local gap = gear.gaps[item_id]
        if gap then
            for key, value in pairs(gap) do stats[key] = value end
            stats.unreadable = false
        end
        stats_cache[item_id] = stats
    end
    return stats
end

-- Bags gear can be worn from.
local WEARABLE_BAGS = {'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4',
                       'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8'}

-- Ids of every weapon and armor piece in those bags, each once.
local function wearable_ids()
    local ids, seen = {}, {}
    local items = windower.ffxi.get_items()
    if not items then return ids end            -- not logged in: login calls again
    local _ = res.items                         -- loads the whole resource now, even with nothing carried
    for _, bag_name in ipairs(WEARABLE_BAGS) do
        for _, item in pairs(items and items[bag_name] or {}) do
            local id = type(item) == 'table' and item.id
            local info = id and id > 0 and res.items[id]
            if info and (info.category == 'Armor' or info.category == 'Weapon') and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- Called on addon load and login, so the first cast does not stall the game.
-- That cast otherwise pays for two loads at once: Windower's items resource
-- (extdata.decode looks every item up in it, and loading its 23,000 entries is
-- most of a freeze of up to a second), and the description file for the gear.
-- Both are done here, for every wearable piece carried, so a cast only reads
-- the file again for gear obtained since. Returns whether descriptions can be
-- read at all (see descriptions_loaded).
function M.warm_up()
    local ok = pcall(function()
        local ids = wearable_ids()          -- the first res.items lookup loads the resource
        local unseen = {}
        for _, id in ipairs(ids) do
            if description_text[id] == nil and not stats_cache[id] then unseen[#unseen + 1] = id end
        end
        load_descriptions(unseen)           -- one pass over the file for all of them
        for _, id in ipairs(ids) do item_stats(id) end
    end)
    return ok and M.descriptions_loaded()
end

-- Augments cannot be cached: they belong to the individual item. Strings come
-- from extdata.decode, e.g.
--   "Enh. Mag. eff. dur. +N"       Telchine-style, N percent (seen in game on Telchine gear)
--   "All Songs+N" / "All songs +N"  N levels, 10% each
--   "Enhancing Magic duration"      relic hands merit augment
--   'Enhances "Diffusion" effect'   Blue Mage Charuqs
local function item_augments(item)
    local found = {enh = 0, levels = 0, relic = false, diffusion = false, raw = {}}
    if not item.extdata then return found end
    local ok, decoded = pcall(extdata.decode, item)
    if not ok then
        found.error = tostring(decoded)
        return found
    end
    -- Path items store only a path letter and rank; the value comes from buff_gear.paths.
    if decoded.path then
        local bonus = gear.paths[item.id] and gear.paths[item.id][decoded.path]
        if bonus and bonus.enh then
            local pct = bonus.enh * (decoded.rank or 0)
            found.enh = found.enh + pct
            found.raw[#found.raw + 1] = {
                text = ('path %s rank %s = enhancing duration +%.0f%%'):format(decoded.path, tostring(decoded.rank), pct * 100),
                counted = true}
        else
            found.raw[#found.raw + 1] = {
                text = ('path %s rank %s (no duration value known)'):format(decoded.path, tostring(decoded.rank)),
                counted = false}
        end
    end
    for _, text in ipairs(decoded.augments or {}) do
        -- "Path: A" is already shown by the path line above
        if not (decoded.path and text:match('^Path: ')) then
            local percent = text:match('^Enh%. Mag%. eff%. dur%. %+(%d+)')
                         or text:match('^Enhancing [Mm]agic effect duration %+(%d+)')
            local levels  = text:match('^[Aa]ll [Ss]ongs%s*%+(%d+)')
            local counted = true
            if percent then
                found.enh = found.enh + tonumber(percent) / 100
            elseif levels then
                found.levels = found.levels + tonumber(levels)
            elseif text:match('^Enhancing Magic duration') then
                found.relic = true
            elseif text:match('^Enhances "Diffusion" effect') then
                found.diffusion = true
            else
                counted = false
            end
            found.raw[#found.raw + 1] = {text = text, counted = counted}
        end
    end
    return found
end

-- Composure set pieces count per set family: the name's first letters give the
-- set ("Leth." / "Lethargy" -> leth, "Estq." -> estq), so every tier of a set
-- combines (confirmed in game; bg-wiki lists Lethargy base through +3 as one
-- set). Different sets do not combine.
local function composure_set_key(item_id)
    local item = res.items and res.items[item_id]
    local name = item and item.en or ''
    return name:sub(1, 4):lower()
end

-- Totals for everything worn. Fractions are 0.10 = +10%.
--   enh        gear-listed Enhancing Magic duration
--   aug        augment Enhancing Magic duration (a separate multiplier)
--   regen      Regen duration seconds
--   perp       Perpetuance multiplier bonus (2 + perp)
--   song       all-songs duration
--   fam        [family] = extra song duration for that family
--   composure  best Composure set bonus for the pieces worn
--   relic, diffusion   flags
--   detail     [slot] = {item = item table, stats = ..., augments = ...}
local function scan_gear()
    local totals = {enh = 0, aug = 0, regen = 0, perp = 0, song = 0, fam = {},
                    composure = 0, relic = false, diffusion = false, detail = {}, set_counts = ''}
    local sets  = {}
    local worn_items = equipped_items()
    local unseen = {}
    for _, item in pairs(worn_items) do
        if description_text[item.id] == nil and not stats_cache[item.id] then unseen[#unseen + 1] = item.id end
    end
    load_descriptions(unseen)       -- one pass over the file for every piece not seen before
    for slot, item in pairs(worn_items) do
        local stats    = item_stats(item.id)
        local augments = item_augments(item)
        totals.detail[slot] = {item = item, stats = stats, augments = augments}

        totals.enh   = totals.enh   + (stats.enh   or 0)
        totals.regen = totals.regen + (stats.regen or 0)
        totals.perp  = totals.perp  + (stats.perp  or 0)
        totals.song  = totals.song  + (stats.song  or 0) + 0.1 * ((stats.levels or 0) + augments.levels)
        for family, levels in pairs(stats.fam) do
            totals.fam[family] = (totals.fam[family] or 0) + 0.1 * levels
        end
        if stats.song_fixed then totals.song_fixed = math.max(totals.song_fixed or 0, stats.song_fixed) end
        totals.aug       = totals.aug + augments.enh
        totals.relic     = totals.relic     or stats.relic     or augments.relic
        totals.diffusion = totals.diffusion or stats.diffusion or augments.diffusion
        if stats.composure then
            local key = composure_set_key(item.id)
            sets[key] = (sets[key] or 0) + 1
        end
    end
    local counts = {}
    for key, pieces in pairs(sets) do
        totals.composure = math.max(totals.composure, gear.composureSetBonus[pieces] or 0)
        counts[#counts + 1] = ('%s x%d'):format(key, pieces)
    end
    totals.set_counts = #counts > 0 and table.concat(counts, ', ') or 'no set pieces worn'
    return totals
end

-- One line per worn item, then the totals. Every augment string extdata
-- returns is listed, counted or not, so a wording the scan does not know shows
-- up here instead of silently adding nothing.
local function gear_lines(totals)
    local lines = {}
    if description_problem then
        lines[#lines + 1] = 'item descriptions NOT AVAILABLE - gear text cannot be read, only buff_gear.lua fallbacks count'
    end
    for _, slot in ipairs(SLOTS) do
        local d = totals.detail[slot]
        if d then
            local s, a, parts = d.stats, d.augments, {}
            local function add_part(text) parts[#parts + 1] = text end
            if s.enh    then add_part(('enhancing %+.0f%%'):format(s.enh * 100)) end
            if s.regen  then add_part(('regen +%.0fs'):format(s.regen)) end
            if s.perp   then add_part(('perpetuance +%.0f%%'):format(s.perp * 100)) end
            if s.song   then add_part(('songs +%.0f%%'):format(s.song * 100)) end
            if s.levels then add_part(('all songs +%d'):format(s.levels)) end
            if s.song_fixed then add_part(('songs fixed at %.0f min'):format(s.song_fixed / 60)) end
            for family, levels in pairs(s.fam) do add_part(('%s +%d'):format(family, levels)) end
            if s.composure then add_part('composure set') end
            if s.relic or a.relic then add_part('relic hands') end
            if s.diffusion or a.diffusion then add_part('diffusion') end
            for _, aug in ipairs(a.raw) do
                add_part(('aug "%s"%s'):format(aug.text, aug.counted and '' or ' (not counted)'))
            end
            if a.error then add_part('augment decode failed: ' .. a.error) end
            if s.unreadable then add_part('DURATION TEXT WITHOUT A NUMBER - not counted') end
            local item = res.items and res.items[d.item.id]
            lines[#lines + 1] = ('%s: %s - %s'):format(slot, item and item.en or d.item.id,
                #parts > 0 and table.concat(parts, ', ') or 'nothing detected')
        end
    end
    lines[#lines + 1] = ('totals: enhancing %+.0f%% (+%.0f%% aug), regen +%.0fs, songs +%.0f%%, perpetuance x%.2f, composure +%.0f%% (%s)'):format(
        totals.enh * 100, totals.aug * 100, totals.regen, totals.song * 100, 2 + totals.perp, totals.composure * 100, totals.set_counts)
    return lines
end

-- For `//timers2 gear`: what is worn right now.
function M.describe_gear()
    local totals = scan_gear()
    description_problem = not M.descriptions_loaded()      -- an explicit check, not just the last read
    return gear_lines(totals)
end

-- Shown in the trace when the merit value is missing: which merit keys the
-- client does expose, so a wrong key name is obvious.
local function merit_hint(player)
    if not player.merits then return ' [player.merits is missing]' end
    if player.merits.enhancing_magic_duration ~= nil then return '' end
    local keys = {}
    for key in pairs(player.merits) do
        if tostring(key):find('enhanc') then keys[#keys + 1] = tostring(key) end
    end
    table.sort(keys)
    return ' [key enhancing_magic_duration is nil; similar keys: ' .. (#keys > 0 and table.concat(keys, ',') or 'none') .. ']'
end

-- Flat seconds from merits and job points (bg-wiki "Enhancing Magic" step 1).
-- Merits and job point gifts only count while the job is main; gifts need 99.
-- Returns the seconds and a short breakdown for the trace.
local function flat_seconds(entry, totals, player, buffs)
    local main, level = player.main_job_id, player.main_job_level
    local points = player.job_points or {}
    local seconds, parts = 0, {}
    local function add(text, value)
        seconds = seconds + value
        parts[#parts + 1] = ('%s %+.0f'):format(text, value)
    end

    if main == RDM then
        local merits = player.merits and player.merits.enhancing_magic_duration
        local per_level = totals.relic and 9 or 6
        if level >= 75 then add(('merits %s x%d'):format(tostring(merits), per_level) .. merit_hint(player), (merits or 0) * per_level) end
        local jp = points.rdm and points.rdm.enhancing_magic_duration
        if level == 99 then add(('RDM JP %s'):format(tostring(jp)), jp or 0) end
    end

    if entry.regen then
        -- These bonuses apply to Regen cast on other players too. Confirmed in game:
        -- Light Arts (Scholar), Scholar with Accession and Arbatel Bracers, Tabula
        -- Rasa, and White Mage with Light Arts active.
        if main == WHM and level == 99 and points.whm then
            add('WHM regen JP', 3 * (points.whm.regen_duration or 0))
        end
        local light_arts = buffs[LIGHT_ARTS] or buffs[ADDENDUM_WHITE]
        if buffs[TABULA_RASA] then
            add('Tabula Rasa', 72)          -- overrides the Light Arts level bonus
        elseif light_arts and main == SCH then
            add('Light Arts', math.floor((level - 10) / 10) * 6)
        end
        if light_arts and main == SCH and level == 99 and points.sch then
            add('SCH LA JP', 3 * (points.sch.light_arts_effect or 0))
        end
    end
    return seconds, table.concat(parts, ', ')
end

-------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------

-- The most recent calculation, step by step, for `//timers2 last`.
local last_traces = {}      -- ['others'] / ['own']

function M.describe_last()
    local lines = {}
    for _, which in ipairs({'others', 'own'}) do
        local trace = last_traces[which]
        if trace then
            lines[#lines + 1] = ('%s (spell %d), %s:'):format(trace.name, trace.spell_id,
                which == 'own' and 'your own copy' or 'on other players')
            for _, step in ipairs(trace.steps) do lines[#lines + 1] = '  ' .. step end
            if trace.totals then
                lines[#lines + 1] = '  gear used:'
                for _, line in ipairs(gear_lines(trace.totals)) do lines[#lines + 1] = '    ' .. line end
            end
        end
    end
    if #lines == 0 then lines[1] = 'no duration has been calculated yet' end
    return lines
end

-- True when a spell lasts as long on the caster as on anyone else it hits. Songs
-- and Blue Magic have no "received" modifiers; Enhancing Magic does (Composure
-- triples the caster's own copy), so the caster's server time says nothing about
-- the others' there.
function M.same_on_self(spell_id)
    local entry = spells[spell_id]
    return entry ~= nil and (entry.kind == 'song' or entry.kind == 'blu')
end

-- A short remark about how predictable a spell's duration is, or nil.
function M.duration_note(spell_id)
    local entry = spells[spell_id]
    return entry and entry.note
end

-- The buff id a spell's timer should be matched against when it differs from
-- the one in the resources (nil otherwise).
function M.get_status(spell_id)
    local entry = spells[spell_id]
    return entry and entry.status
end

-- What a calculation reads about the caster: the player table, their buff set
-- and the gear scan, each fetched on first use. One cast asks for the duration
-- on others and then on our own copy; passing the same context to both reads
-- the client and the worn gear once instead of twice. Afterwards the context
-- also holds context.player, context.buffs ([buff id] = true) and
-- context.results.others / .own = {duration, name, capped, enh_term}.
function M.new_context()
    return {}
end

local function context_player(context)
    if context.player == nil then
        context.player = windower.ffxi.get_player() or false
        context.buffs  = context.player and buff_set(context.player) or {}
    end
    return context.player or nil, context.buffs
end

local function context_totals(context)
    context.totals = context.totals or scan_gear()
    return context.totals
end

-- Seconds a spell cast by the local player is expected to last on another
-- player, or nil if the spell is not covered (or nobody is logged in). With
-- `own_copy` it is the caster's own buff instead: Enhancing Magic then gets
-- Composure's x3 (capped at 30 minutes) in place of the set bonus that only
-- applies to other players. `context` (from new_context) is optional; it lets
-- several calls for one cast share their reads.
--
-- Modifiers on the receiving end of Enhancing Magic, which the caster's state
-- cannot show, come in `received` = {naturalist = fraction, gifts = fraction,
-- embolden = true}: Naturalist's Roll adds to the gear percentage, Rune Fencer
-- job point gifts multiply after the augments (bg-wiki "Enhancing Magic"), and
-- Embolden halves what is left. Our own copy reads our own gifts from our job
-- points and our own Embolden from our buffs.
function M.get_spell_duration(spell_id, own_copy, context, received)
    local entry = spells[spell_id]
    if not entry then return nil end
    context = context or M.new_context()
    local player, buffs = context_player(context)
    if not player then return nil end

    local duration = entry.base
    local steps = {('base %.0f'):format(duration)}
    local function step(label)
        steps[#steps + 1] = ('%-34s -> %.1f'):format(label, duration)
    end
    local totals = entry.kind ~= 'fixed' and context_totals(context) or nil
    local capped = false
    if entry.regen_gear then
        duration = duration + totals.regen
        step(('regen gear +%.0f'):format(totals.regen))
    end

    if entry.kind == 'enhancing' then
        -- Order from bg-wiki "Enhancing Magic": flat seconds, Composure set
        -- bonus, duration gear %, augment %, Perpetuance. Composure's own x3 is
        -- self-only.
        local flat, detail = flat_seconds(entry, totals, player, buffs)
        duration = duration + flat
        step(('flat %+.0f (%s)'):format(flat, detail ~= '' and detail or 'none'))
        local tripled = false
        if buffs[COMPOSURE] and own_copy then
            -- bg-wiki: tripled on the caster, capped at 30 minutes, and never
            -- below what the spell would last without Composure.
            duration = duration * 3
            tripled  = true
            step('composure x3 (own copy)')
        elseif buffs[COMPOSURE] then
            duration = duration * (1 + totals.composure)
            step(('composure set +%.0f%% (%s)'):format(totals.composure * 100, totals.set_counts))
        else
            step('composure not active')
        end
        received = received or {}
        local roll = received.naturalist or 0
        duration = duration * (1 + totals.enh + roll)
        if roll ~= 0 then
            step(('gear enhancing +%.0f%%, naturalist\'s roll %+.1f%%'):format(totals.enh * 100, roll * 100))
        else
            step(('gear enhancing duration +%.0f%%'):format(totals.enh * 100))
        end
        duration = duration * (1 + totals.aug)
        step(('augments +%.0f%%'):format(totals.aug * 100))
        local gifts = received.gifts
        if gifts == nil and own_copy then gifts = M.own_rune_fencer_gifts(player) end
        if gifts and gifts > 0 then
            duration = duration * (1 + gifts)
            step(('rune fencer gifts +%.0f%%%s'):format(gifts * 100, own_copy and '' or ' (mastered)'))
        end
        local embolden = received.embolden
        if embolden == nil and own_copy then embolden = buffs[M.EMBOLDEN] == true end
        if embolden then
            duration = duration * EMBOLDEN_DURATION
            step(('embolden -%.0f%%'):format((1 - EMBOLDEN_DURATION) * 100))
        end
        if buffs[PERPETUANCE] then
            duration = duration * (2 + totals.perp)
            step(('perpetuance x%.2f'):format(2 + totals.perp))
        end
        if tripled then
            local uncapped = duration
            duration = math.max(duration / 3, math.min(duration, COMPOSURE_CAP))
            capped = duration < uncapped
            step(('composure cap %d min'):format(COMPOSURE_CAP / 60))
        end
    elseif entry.kind == 'song' and totals.song_fixed then
        -- Miracle Cheer: every song lasts exactly this long; nothing else applies.
        duration = totals.song_fixed
        step(('fixed by gear (%.0f min)'):format(duration / 60))
    elseif entry.kind == 'song' then
        -- Gear read from the worn set when the song completes (the midcast set): the
        -- all-songs bonuses plus the bonus for this song's own family, e.g. a
        -- piece that says "Minuet"+1 adds 10% to Valor Minuet only.
        local family_bonus = totals.fam[entry.family] or 0
        local multiplier   = 1 + totals.song + family_bonus
        -- Bard job points (main BRD at 99): +5% song duration once 1200 JP are
        -- spent, then flat seconds while Tenuto / Clarion Call / Marcato is up.
        -- Troubadour, Tenuto, Clarion Call, Marcato and the job points were
        -- checked against in-game timers.
        local points = player.main_job_id == BRD and player.main_job_level == 99
                       and player.job_points and player.job_points.brd
        local gift = points and (points.jp_spent or 0) >= 1200
        if gift then multiplier = multiplier + 0.05 end
        duration = duration * multiplier
        step(('song multiplier x%.2f (all songs +%.0f%%, %s +%.0f%%%s)'):format(multiplier, totals.song * 100,
            entry.family or 'no family', family_bonus * 100, gift and ', 1200 JP gift +5%' or ''))
        if points then
            if buffs[TENUTO]       then duration = duration + 2 * (points.tenuto_effect or 0) end
            if buffs[CLARION_CALL] then duration = duration + 2 * (points.clarion_call_effect or 0) end
            if buffs[MARCATO]      then duration = duration + (points.marcato_effect or 0) end
            step('job point seconds')
        end
        -- bg-wiki "Songs": Troubadour doubles the total after every other bonus,
        -- and decimals are dropped after totaling.
        if buffs[TROUBADOUR] then duration = duration * 2; step('troubadour x2') end
        duration = math.floor(duration)
    elseif entry.kind == 'blu' then
        -- Diffusion merit ranks after the first (+5% each) and the Diffusion
        -- Charuqs (+5% per rank) add together; the Unbridled Learning Effect II job
        -- points (+1% per level) then multiply the result. Measured on Mighty Guard
        -- with 5/5 Diffusion, Luhlaza Charuqs +1 and job points 20/20:
        --   180 x 1.45 x 1.20 = 313s                     (seen 5:11-5:13, as on bg-wiki)
        -- Carcharian Verve is the exception (spells[745].jp_additive): its job points
        -- add to the Diffusion/Charuqs percentage instead of multiplying it.
        -- Diffusion on its own (no Charuqs) was checked in game as well.
        local bonus, parts = 0, {}
        if entry.diffusion and buffs[DIFFUSION] then
            local rank = math.max(player.merits and player.merits.diffusion or 0, 1)
            bonus = bonus + (rank - 1) * 0.05
            parts[#parts + 1] = ('diffusion rank %d +%.0f%%'):format(rank, (rank - 1) * 5)
            if totals.diffusion then
                bonus = bonus + rank * 0.05
                parts[#parts + 1] = ('charuqs +%.0f%%'):format(rank * 5)
            end
        end
        local unbridled = 0
        if entry.unbridled and player.main_job_id == BLU and player.main_job_level == 99 then
            local points = player.job_points and player.job_points.blu
            unbridled = (points and points.unbridled_learning_effect_ii or 0) / 100
        end
        if entry.jp_additive then
            duration = duration * (1 + bonus + unbridled)
        else
            duration = duration * (1 + bonus) * (1 + unbridled)
        end
        step(('diffusion + charuqs +%.0f%% (%s), unbridled job points +%.0f%% (%s)'):format(
            bonus * 100, #parts > 0 and table.concat(parts, ', ') or 'none',
            unbridled * 100, entry.jp_additive and 'added' or 'multiplied'))
    end

    if entry.cap and duration > entry.cap then duration = entry.cap; capped = true; step('cap') end
    steps[#steps + 1] = ('final %.1f seconds'):format(duration)
    local info = res.spells and res.spells[spell_id]
    local name = info and info.en or '?'
    -- The gear report is only read by `//timers2 last`, so it is built from
    -- these totals there rather than on every cast.
    local which = own_copy and 'own' or 'others'
    last_traces[which] = {spell_id = spell_id, name = name, steps = steps, totals = totals}
    -- What naturalist.lua needs to measure or apply a received bonus: the
    -- gear term it adds to, and whether a cap hid part of the result.
    context.results = context.results or {}
    context.results[which] = {
        duration = duration, name = name, capped = capped,
        enh_term = entry.kind == 'enhancing' and (1 + totals.enh) or nil,
    }
    return duration
end

-- True for spells Naturalist's Roll lengthens: Enhancing Magic with a
-- computed duration (not the fixed Reraise, songs or Blue Magic).
function M.naturalist_applies(spell_id)
    local entry = spells[spell_id]
    return entry ~= nil and entry.kind == 'enhancing'
end

-- True when the game picks the base duration at random (Sneak, Plasma Charge):
-- the estimate is only the middle of the range, so it measures nothing.
function M.random_duration(spell_id)
    local entry = spells[spell_id]
    return entry ~= nil and entry.random == true
end

return M
