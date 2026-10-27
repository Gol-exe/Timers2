--[[
    Data layer for Timers2.
    Owns all runtime state and produces a theme-agnostic result table each frame.
    No display primitives, texts, or images here. tracker.lua fills the timer
    tables from packets; other modules always reach them through this module
    (data.self_buff_timers, ...), since a reset replaces the tables.

    Return value of collect():
      { left = sections[], right = sections[], custom = sections[] }

    Section contract:  { title, rows[] }
    Row contract:      { cat, name, remaining, total, created_order,
                         [party_name],    -- party buff rows (none mode display)
                         [target_name],   -- party buff rows (player sort)
                         [count],         -- condensed party rows: members holding it
                         [spell_id],      -- spell recast rows
                         [recast_id],     -- ability recast rows
                         [job_id],        -- shared SP ability recast rows (ids 0 / 254)
                         [buff_id] }      -- buff rows (status id)

    left   = merged recast timers (abilities + spells), always headerless
    right  = persistent buff timers (self / AOE / party), layout by group_type
    custom = custom timers, rendered at settings.custom_pos

    group_type controls right-column layout:
      'start'     -- BUFFS - SELF / BUFFS - AOE / BUFFS - PARTY / [player]
      'character' -- SELF / AOE / PARTY / [player]
      'none'      -- single flat list; party rows carry [CharacterName]/[AOE] suffix

    sort_mode controls row order within every section:
      'duration'  -- by time remaining
      'name'      -- alphabetical
      'player'    -- by target name, then duration
      'creation'  -- by creation order (oldest cast shown first when asc)

    Per-bucket sort direction:
      recast_low_to_high  true  = soonest ready first  (default true)
      buff_low_to_high    true  = soonest expiring first (default false)
      custom_low_to_high  true  = soonest expiring first (default false)
]]

local res = require('resources')
local M   = {}

-- Valid sort modes, in the order the commands list them.
M.sort_modes = {'duration', 'name', 'player', 'creation'}

-------------------------------------------------------------------------------
-- Built-in filters — always available for selection alongside user filters.
-- Same structure as user filters, with optional exclude predicates:
--   spell_exclude(spell_id, spell)   -> true to hide that spell recast row
--   ability_exclude(recast_id, name) -> true to hide that ability recast row
--   buff_exclude(buff_id, name)      -> true to hide that buff row
-- Built-in filter names are reserved; they cannot be created, modified, or
-- deleted by the user via commands.
-------------------------------------------------------------------------------
M.builtin_filters = {
    ['trust magic'] = {
        label       = 'Trust Magic',
        description = 'Hides recast timers for Trust (Alter Ego) summoning spells.',
        categories  = {},
        sort        = '',
        whitelist   = {},
        spell_exclude = function(spell_id, spell)
            -- Trust spells have type == 'Trust' in Windower resources.
            -- Unity Concord trusts share the same type field so are covered.
            return spell ~= nil and spell.type == 'Trust'
        end,
    },
}

-------------------------------------------------------------------------------
-- Mutable state — written by tracker.lua and the commands
-------------------------------------------------------------------------------
M.self_buff_timers     = {}   -- [buff_id]   = {name, expires, duration, created_order}
M.party_buff_timers    = {}   -- [key]       = {name, expires, duration, ..., created_order}
M.custom_timers        = {}   -- [name]      = {expires, duration, created_order}
M.spell_recast_peak    = {}   -- [spell_id]  = seconds at first observation
M.ability_recast_peak  = {}   -- [recast_id] = seconds at first observation
M.spell_recast_order   = {}   -- [spell_id]  = created_order number
M.ability_recast_order = {}   -- [recast_id] = created_order number
M.next_order           = 1
M.main_job_id          = nil

-------------------------------------------------------------------------------
-- Static lookups
-------------------------------------------------------------------------------
local ability_recasts_res = res.ability_recasts

-- Every job's one-hour ability shares recast_id 0, and its second SP ability shares
-- recast_id 254, so the recast id alone cannot say which one is on cooldown. The
-- main job decides, through these res.job_abilities ids, indexed by job id (WAR = 1
-- ... RUN = 22). They are not consecutive: the first 15 jobs' abilities are ids 16
-- to 30, and the later jobs' (Azure Lore, Wild Card, ...) were added much later.
local SP_ABILITY_ID = {
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,    -- WAR to SMN: Mighty Strikes ... Astral Flow
    93,                                                                -- BLU Azure Lore
    96,                                                                -- COR Wild Card
    135,                                                               -- PUP Overdrive
    181,                                                               -- DNC Trance
    210,                                                               -- SCH Tabula Rasa
    343,                                                               -- GEO Bolster
    356,                                                               -- RUN Elemental Sforzo
}
local SP2_ABILITY_ID = {
    323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337,   -- WAR to SMN: Brazen Rush ... Astral Conduit
    338, 339, 340, 341, 342,                                                      -- BLU to SCH: Unbridled Wisdom ... Caper Emissarius
    -- Geomancer and Rune Fencer have no second SP ability
}

-- The name of a job's one-hour ability (or its second SP ability), or nil.
function M.sp_ability_name(job_id, second)
    local ability = res.job_abilities[(second and SP2_ABILITY_ID or SP_ABILITY_ID)[job_id] or -1]
    return ability and (ability.en or ability.name) or nil
end

-- Section titles for the buff column, per group_type ('none' has no titles).
local SECTION_TITLES = {
    start     = {self = 'BUFFS - SELF', aoe = 'BUFFS - AOE', party = 'BUFFS - PARTY'},
    character = {self = 'SELF',         aoe = 'AOE',         party = 'PARTY'},
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local FFXI_EPOCH = 1009810800          -- Unix timestamp of FFXI's internal clock epoch (~Jan 2002)
local WRAP_SECS  = 0x100000000 / 60   -- Seconds per uint32 overflow cycle (~2.27 years)

function M.buff_remaining(ts)
    if ts == 0 then return nil end
    local now = os.time()
    -- Determine how many full wrap cycles have elapsed since the FFXI epoch.
    local base_wraps = math.floor((now - FFXI_EPOCH) / WRAP_SECS)
    -- Reconstruct the Unix expiry time for this cycle. If it's already in the
    -- past the buff's expiry has crossed into the next cycle, so advance by one.
    local expiry = FFXI_EPOCH + base_wraps * WRAP_SECS + ts / 60
    if expiry < now then
        expiry = expiry + WRAP_SECS
    end
    return math.max(0, math.floor(expiry - now))
end

local function append(dst, src)
    for _, v in ipairs(src) do table.insert(dst, v) end
end

local function apply_limit(rows, limit)
    if limit and limit > 0 then
        for i = #rows, limit + 1, -1 do rows[i] = nil end
    end
end

-------------------------------------------------------------------------------
-- collect(settings) -> { left, right, custom }
-------------------------------------------------------------------------------
function M.collect(settings)
    local now        = os.clock()
    local flt        = settings.filters[settings.active_filter]
                    or M.builtin_filters[settings.active_filter]
    local group_type = settings.group_type or 'start'
    local sort_key   = (flt and flt.sort ~= '' and flt.sort) or settings.sort_mode or 'duration'

    -- Returns the display name for a recast group.
    -- recast_id=0 and 254 are shared SP ability slots; the per-job name comes from
    -- M.sp_ability_name (the explicit id tables above).
    local function get_ability_name(recast_id)
        if (recast_id == 0 or recast_id == 254) and M.main_job_id then
            local name = M.sp_ability_name(M.main_job_id, recast_id == 254)
            if name then return name end       -- otherwise fall back to the generic recast name
        end
        if ability_recasts_res then
            local ar = ability_recasts_res[recast_id]
            if ar then return ar.en end
        end
        return nil
    end

    local recast_asc = settings.recast_low_to_high ~= false  -- default true
    local buff_asc   = settings.buff_low_to_high   == true   -- default false
    local custom_asc = settings.custom_low_to_high == true   -- default false

    local function cat_ok(cat)
        if not flt or not flt.categories or not next(flt.categories) then return true end
        return flt.categories[cat] == true
    end

    local function wl_ok(name)
        if flt and flt.whitelist and next(flt.whitelist) then
            return flt.whitelist[name:lower()] ~= nil
        end
        return true
    end

    local function cmp(x, y)
        if x < y then return -1 elseif x > y then return 1 end
        return 0
    end

    -- Strict ordering for table.sort: primary key by direction, then creation
    -- order and name so rows that tie keep a fixed position between refreshes.
    local function apply_sort_dir(rows, asc)
        local dir = asc and 1 or -1
        table.sort(rows, function(a, b)
            local c
            if sort_key == 'name' then
                c = dir * cmp(a.name, b.name)
            elseif sort_key == 'creation' then
                c = dir * cmp(a.created_order or 0, b.created_order or 0)
            elseif sort_key == 'player' then
                c = cmp(a.target_name or '', b.target_name or '')   -- players always A-Z
                if c == 0 then c = dir * cmp(a.remaining, b.remaining) end
            else  -- 'duration'
                c = dir * cmp(a.remaining, b.remaining)
            end
            if c == 0 then c = cmp(a.created_order or 0, b.created_order or 0) end
            if c == 0 then c = cmp(a.name, b.name) end
            return c < 0
        end)
    end

    --------------------------------------------------------------------------
    -- Gather
    --------------------------------------------------------------------------

    -- A recast's bar length is the first value seen for it, which only means
    -- something while the section keeps watching. A hidden section forgets its
    -- peaks, so a recast that restarted meanwhile is not drawn against the old one.
    local function forget_peaks(peaks, orders)
        for id in pairs(peaks) do peaks[id] = nil end
        for id in pairs(orders) do orders[id] = nil end
    end

    -- Ability recasts
    local ability_rows = {}
    if not (settings.show_abilities and cat_ok('ability')) then
        forget_peaks(M.ability_recast_peak, M.ability_recast_order)
    else
        local recasts = windower.ffxi.get_ability_recasts()
        if recasts then
            for recast_id, seconds in pairs(recasts) do
                if seconds > 0 then
                    local peak = M.ability_recast_peak[recast_id]
                    if not peak then
                        peak = seconds
                        M.ability_recast_peak[recast_id]  = peak
                        M.ability_recast_order[recast_id] = M.next_order
                        M.next_order = M.next_order + 1
                    end
                    local aname = get_ability_name(recast_id)
                    if aname then
                        local show = wl_ok(aname)
                            and not (flt and flt.ability_exclude and flt.ability_exclude(recast_id, aname))
                        if next(settings.ability_whitelist) then
                            show = show and settings.ability_whitelist[aname:lower()] ~= nil
                        end
                        if show then
                            table.insert(ability_rows, {
                                cat='ability',
                                name=aname,
                                recast_id=recast_id,
                                -- recast ids 0 and 254 are shared by every job's SP abilities;
                                -- the job tells the theme which icon file to use
                                job_id=(recast_id == 0 or recast_id == 254) and M.main_job_id or nil,
                                remaining=seconds, total=peak,
                                created_order=M.ability_recast_order[recast_id] or 0,
                            })
                        end
                    end
                else
                    M.ability_recast_peak[recast_id]  = nil
                    M.ability_recast_order[recast_id] = nil
                end
            end
        end
    end

    -- Spell recasts
    local spell_rows = {}
    if not (settings.show_spells and cat_ok('spell')) then
        forget_peaks(M.spell_recast_peak, M.spell_recast_order)
    else
        local recasts = windower.ffxi.get_spell_recasts()
        if recasts then
            for spell_id, cs in pairs(recasts) do
                local seconds = cs / 60
                if seconds > 0 then
                    local peak = M.spell_recast_peak[spell_id]
                    if not peak then
                        peak = seconds
                        M.spell_recast_peak[spell_id]  = peak
                        M.spell_recast_order[spell_id] = M.next_order
                        M.next_order = M.next_order + 1
                    end
                    local spell = res.spells[spell_id]
                    if spell and spell.name then
                        local show = wl_ok(spell.name)
                            and not (flt and flt.spell_exclude and flt.spell_exclude(spell_id, spell))
                        if next(settings.spell_whitelist) then
                            show = show and settings.spell_whitelist[spell.name:lower()] ~= nil
                        end
                        if show then
                            table.insert(spell_rows, {
                                cat='spell',
                                name=spell.english_short or spell.name,
                                spell_id=spell_id,
                                remaining=seconds, total=peak,
                                created_order=M.spell_recast_order[spell_id] or 0,
                            })
                        end
                    end
                else
                    M.spell_recast_peak[spell_id]  = nil
                    M.spell_recast_order[spell_id] = nil
                end
            end
        end
    end

    -- Buff timers, ours and the party's. Expired entries are dropped from the
    -- table; a live one becomes a row unless the blacklist or filter hides it.
    local show_buffs = settings.show_buffs and cat_ok('buff')
    local function buff_rows(timers, each)
        if not show_buffs then return end
        for key, entry in pairs(timers) do
            local remaining = entry.expires - now
            if remaining <= 0 then
                timers[key] = nil
            elseif entry.name
                   and not settings.buff_blacklist[entry.name:lower()]
                   and wl_ok(entry.name)
                   and not (flt and flt.buff_exclude and flt.buff_exclude(entry.status_id or key, entry.name)) then
                -- The name is shown with its suffix (a roll's total, "Chaos Roll
                -- XI"); filters and icons go by the plain name.
                each(entry, {
                    cat='buff', name=entry.suffix and (entry.name .. ' ' .. entry.suffix) or entry.name,
                    icon_name=entry.name,
                    buff_id=entry.status_id or key,
                    remaining=remaining, total=entry.duration,
                    created_order=entry.created_order or 0,
                })
            end
        end
    end

    local self_buff_rows = {}
    buff_rows(M.self_buff_timers, function(_, row) table.insert(self_buff_rows, row) end)

    -- Party buffs — AOE into aoe_rows, single-target into by_player
    local by_player    = {}
    local player_order = {}
    local aoe_rows     = {}
    buff_rows(M.party_buff_timers, function(entry, row)
        if entry.is_aoe then
            row.target_name = 'AOE'
            table.insert(aoe_rows, row)
            return
        end
        if not entry.target_name and entry.target_id then
            local mob = windower.ffxi.get_mob_by_id(entry.target_id)
            if mob and mob.name then entry.target_name = mob.name end
        end
        local pname = entry.target_name or 'Unknown'
        if not by_player[pname] then
            by_player[pname] = {}
            table.insert(player_order, pname)
        end
        row.group_id    = entry.group_id
        row.target_name = entry.target_name
        table.insert(by_player[pname], row)
    end)
    table.sort(player_order)

    -- Custom timers
    local custom_rows = {}
    if cat_ok('custom') then
        for name, entry in pairs(M.custom_timers) do
            local remaining = entry.expires - now
            if remaining > 0 then
                table.insert(custom_rows, {
                    cat='custom', name=name,
                    remaining=remaining, total=entry.duration,
                    created_order=entry.created_order or 0,
                })
            else
                M.custom_timers[name] = nil
            end
        end
    end

    --------------------------------------------------------------------------
    -- Condense party buffs: when the same buff appears on N+ party members,
    -- collapse all their rows into one synthetic row showing the earliest
    -- expiry, with a `count` field for the theme to display (e.g. "Shell V [6]").
    -- This looks at every row, so it runs before the row limits below. The
    -- player rows are sorted first: a condensed row takes its name and total
    -- from the first row of its group, which must not change between refreshes.
    --------------------------------------------------------------------------
    for _, pname in ipairs(player_order) do
        apply_sort_dir(by_player[pname], buff_asc)
    end

    local condense_threshold = settings.condense_party_threshold or 2
    local condensed_party_rows = {}
    if condense_threshold > 0 then
        -- Tally how many player buckets carry each buff_id (one count per pname, not per row).
        -- Counting per-row instead would inflate the count when multiple players share the
        -- same pname bucket (e.g. all resolve to 'Unknown'), triggering premature condensation.
        local buff_tally = {}  -- [group] = {buff_id, name, total, min_remaining, min_created, count}
        -- A group is the status id, except songs, where each spell is its own group
        -- (Valor Minuet IV and V share a status but are separate buffs).
        for _, pname in ipairs(player_order) do
            local seen = {}  -- buff_ids already counted for this pname bucket
            for _, row in ipairs(by_player[pname]) do
                local bid = row.group_id or row.buff_id
                if bid ~= nil then
                    if not buff_tally[bid] then
                        buff_tally[bid] = {
                            buff_id=row.buff_id,
                            name=row.name, icon_name=row.icon_name, total=row.total,
                            min_remaining=row.remaining,
                            min_created=row.created_order,
                            count=0,
                        }
                    end
                    local t = buff_tally[bid]
                    if not seen[bid] then
                        seen[bid] = true
                        t.count = t.count + 1
                    end
                    if row.remaining < t.min_remaining then t.min_remaining = row.remaining end
                    if row.created_order < t.min_created then t.min_created = row.created_order end
                end
            end
        end

        -- For each buff that meets the threshold, build a condensed row.
        -- Track condensed buff_ids so the player sections can skip those rows.
        local condensed_ids = {}
        for bid, tally in pairs(buff_tally) do
            if tally.count >= condense_threshold then
                condensed_ids[bid] = true
                table.insert(condensed_party_rows, {
                    cat='buff', name=tally.name, icon_name=tally.icon_name,
                    buff_id=tally.buff_id,
                    remaining=tally.min_remaining, total=tally.total,
                    count=tally.count,
                    target_name='Party',
                    created_order=tally.min_created,
                })
            end
        end

        -- Player sections keep only the rows that were not condensed.
        for _, pname in ipairs(player_order) do
            local filtered = {}
            for _, row in ipairs(by_player[pname]) do
                if not condensed_ids[row.group_id or row.buff_id] then
                    table.insert(filtered, row)
                end
            end
            by_player[pname] = filtered
        end
    end

    --------------------------------------------------------------------------
    -- Sort and limit (per-bucket direction, then truncate)
    --------------------------------------------------------------------------
    local recast_limit = settings.recast_limit or 0
    local buff_limit   = settings.buff_limit   or 0
    local custom_limit = settings.custom_limit or 0

    local recast_rows = {}
    append(recast_rows, ability_rows)
    append(recast_rows, spell_rows)
    apply_sort_dir(recast_rows, recast_asc)
    apply_limit(recast_rows, recast_limit)

    for _, rows in ipairs({self_buff_rows, aoe_rows, condensed_party_rows}) do
        apply_sort_dir(rows, buff_asc)
        apply_limit(rows, buff_limit)
    end
    for _, pname in ipairs(player_order) do
        apply_limit(by_player[pname], buff_limit)   -- already sorted for condensing
    end

    apply_sort_dir(custom_rows, custom_asc)
    apply_limit(custom_rows, custom_limit)

    --------------------------------------------------------------------------
    -- Assemble sections
    --------------------------------------------------------------------------
    local left_sections   = {}
    local right_sections  = {}
    local custom_sections = {}

    -- Left: merged recasts, always headerless
    if #recast_rows > 0 then
        table.insert(left_sections, {title=nil, rows=recast_rows})
    end

    -- Custom: separate position
    if #custom_rows > 0 then
        table.insert(custom_sections, {title='CUSTOM', rows=custom_rows})
    end

    -- Right: buff timers
    local titles = group_type ~= 'none' and (SECTION_TITLES[group_type] or SECTION_TITLES.start)
    if not titles then  -- 'none': one flat list, party rows tagged with their target
        local all = {}
        append(all, self_buff_rows)
        for _, row in ipairs(aoe_rows) do
            row.party_name = 'AOE'
            table.insert(all, row)
        end
        append(all, condensed_party_rows)
        for _, pname in ipairs(player_order) do
            for _, row in ipairs(by_player[pname]) do
                row.party_name = pname
                table.insert(all, row)
            end
        end
        apply_sort_dir(all, buff_asc)
        if #all > 0 then
            table.insert(right_sections, {title=nil, rows=all})
        end
    else
        local function section(title, rows)
            if #rows > 0 then table.insert(right_sections, {title=title, rows=rows}) end
        end
        section(titles.self,  self_buff_rows)
        section(titles.aoe,   aoe_rows)
        section(titles.party, condensed_party_rows)
        for _, pname in ipairs(player_order) do
            section(pname, by_player[pname])
        end
    end

    return {left=left_sections, right=right_sections, custom=custom_sections}
end

return M
