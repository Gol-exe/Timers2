--[[
    Packet tracking for Timers2.
    Turns what the server sends into the buff timers held in data.lua:

      0x028  our own casts and job abilities
      0x029  wear-off and death messages
      0x063  our own buff list (exact remaining times)
      0x076  other party members' buff lists
      0x0DD  party members changing zone
      0x050  gear changes (passed to the duration helper)

    Interface: init(settings), incoming(id, raw), login(), logout(),
    job_change(), zone_change(), tick()
]]

local res           = require('resources')
local data          = require('data')
local buff_duration = require('buff_duration')
local formatting    = require('formatting')
local naturalist    = require('naturalist')

local M = {}

local settings  = {}    -- set by init; read for the calibrate switch
local player_id = nil

local resist_msgs    = {[75] = true, [283] = true}
local buff_wore_msgs = {[64] = true, [204] = true, [206] = true, [350] = true, [531] = true}
local death_msgs     = {[6] = true, [20] = true, [113] = true, [406] = true, [605] = true, [646] = true}

-- Cache of server-reported buff expiry as absolute os.clock() values, refreshed
-- every 0x063 packet. Storing expiry (not remaining) keeps the value accurate
-- regardless of how much time passes before handle_action consults it.
local buff_sync_expiry = {}

-- [member_id] = {[buff_id] = copies}, rebuilt from every 0x076 party-buff packet.
-- Only holds members currently visible to the client; absent means "unknown".
local party_buffs = {}

-- [member_id] = {job, level, master_level, stars}: main job, its level and
-- master level from 0x0DD, and whether 0x00D has shown their job mastery stars.
-- Used for what they receive on top of our estimate (Rune Fencer gifts).
local members = {}

-- Rune Fencer gifts a party member receives Enhancing Magic with. Their job
-- points are hidden from us, but a mastered job (2100 spent) holds both gifts.
-- Mastery shows as the stars over their head, which a player can switch off,
-- or as a master level above 0, which only a mastered job can earn. A Rune
-- Fencer that shows neither might have none, one or both: counted as none.
local function member_gifts(member_id)
    local m = members[member_id]
    if not m or m.job ~= buff_duration.RUNE_FENCER or m.level ~= 99 then return 0 end
    if m.stars or (m.master_level or 0) > 0 then return buff_duration.MASTERED_RUNE_FENCER_GIFTS end
    return 0
end

-- A party timer is not checked against 0x076 until it is this old, so a packet
-- sent before the cast's buff lands cannot remove a fresh timer.
local PARTY_BUFF_GRACE = 5

-- The buff packets (0x063 for us, 0x076 for the party) and the action packet
-- (0x028) of one cast can arrive in either order. When the buff packet comes
-- first it is processed before the cast's timers exist, so a packet younger
-- than this is applied again once they do.
local RACE_WINDOW       = 0.5

-- Some buffs survive zoning and some do not. Our own timers are kept through a
-- zone change and only the ones our first 0x063 after the zone confirms stay (it
-- carries the exact remaining times); whatever is still unconfirmed after
-- ZONE_SETTLE seconds is dropped. Other players' timers are never kept: each
-- character zones on its own, so nothing we saw about them can be checked
-- afterwards.
local ZONE_SETTLE = 20
local zone_check  = nil   -- {time =, self = awaiting our 0x063} after a zone change
local self_slots        = {}           -- [status] = sorted absolute expiries from the last 0x063
local previous_slots    = {}           -- the same from the 0x063 before that
local last_self_packet  = -math.huge

-- A cast can find a copy of its buff already on us (a recast before it ran
-- out), and the first buff list after the cast may still show that old copy:
-- one sent as Perpetuance or Accession was used up, just before the buff
-- landed. Calibrating or measuring the roll from it would compare our estimate
-- with the old copy's time. So a cast remembers the expiries already listed for
-- its status (from before the race window, as the latest list may already be
-- the new state), and a slot within this many seconds of one is the old copy.
local SAME_COPY = 2

local function slots_before_cast(status_id, clock)
    local slots = clock - last_self_packet <= RACE_WINDOW and previous_slots or self_slots
    return slots[status_id]
end

local function is_new_copy(prior, expiry)
    for _, old in ipairs(prior or {}) do
        if math.abs(expiry - old) <= SAME_COPY then return false end
    end
    return true
end
local last_party_packet = -math.huge

function M.init(addon_settings)
    settings = addon_settings
end

-- With `//timers2 calibrate` on, the first time the server reports a buff we just
-- cast (0x063), print the helper's calculation next to the real remaining time.
-- One line per cast; it shows exactly how far a duration calculation is off.
-- The timer's own expiry is not the number to compare: for a buff on ourselves it
-- starts from the resource duration, or from what is left of a buff we already
-- had, so it only holds a placeholder until this first packet arrives.
local function report_calibration(entry, now, remaining)
    if not settings.calibrate or entry.calibrated or not remaining then return end
    local estimate = (entry.model_expires or entry.expires) - now
    if estimate == math.huge or math.abs(estimate - remaining) <= 2 then return end
    windower.add_to_chat(8, ('[Timers2] calibrate: %s estimated %s, server %s (%+.1f%%)%s'):format(
        entry.name, formatting.mmss(estimate), formatting.mmss(remaining), (remaining - estimate) / estimate * 100,
        (entry.own_copy and ' [your own copy: Naturalist\'s Roll is measured rather than estimated]' or '')
            .. (entry.note and (' [' .. entry.note .. ']') or '')
            .. (entry.naturalist and (' [this difference measures Naturalist\'s Roll at %+.1f%%]'):format(entry.naturalist * 100) or '')))
end

-- Songs of different tiers share one status id (Valor Minuet IV and V are both
-- "Minuet") and the game keeps both, so song timers are tracked per spell
-- instead of per status.
local function timer_id(spell, spell_id, status_id)
    return spell.type == 'BardSong' and ('song' .. spell_id) or status_id
end

-- Removes the timer of a buff that just wore off. Songs sharing a status wear off
-- one at a time, so the song closest to expiry goes.
local function remove_worn_song(timers, status_id, target_id)
    local soonest_key, soonest
    for key, entry in pairs(timers) do
        if entry.song and not entry.is_aoe and entry.status_id == status_id
                and (target_id == nil or entry.target_id == target_id)
                and (not soonest or entry.expires < soonest) then
            soonest_key, soonest = key, entry.expires
        end
    end
    if soonest_key then timers[soonest_key] = nil end
end

-------------------------------------------------------------------------------
-- Buff list syncing
-------------------------------------------------------------------------------
-- All k-element subsets of 1..n, each in ascending order ({} once for k = 0).
-- Only used for the few slots one song status can hold, so n stays small.
local function subsets(n, k)
    local result, current = {}, {}
    local function walk(start)
        if #current == k then
            local copy = {}
            for i, value in ipairs(current) do copy[i] = value end
            result[#result + 1] = copy
            return
        end
        for i = start, n do
            current[#current + 1] = i
            walk(i + 1)
            current[#current] = nil
        end
    end
    walk(1)
    return result
end

-- Matches our song timers to the buff slots the server last reported (0x063).
-- A status can hold several songs (Valor Minuet IV and V), and the game keeps
-- the newest casts when it has fewer slots than we have timers, so the newest
-- timers survive and take over the server's remaining times, paired in cast
-- order. If the server lists more slots than we track (songs we did not cast),
-- the closest slots are used. A status with no slot at all drops its timers
-- unless they were only just cast.
local function apply_song_sync(timers, now)
    -- Our own song timers, plus party rows from casts that also hit us
    -- (shared_with_self): those songs hold a slot in our buff list too.
    local by_status = {}
    local function collect(holder, own)
        for key, entry in pairs(holder) do
            if entry.song and (own or entry.shared_with_self) then
                by_status[entry.status_id] = by_status[entry.status_id] or {}
                table.insert(by_status[entry.status_id], {holder = holder, key = key, entry = entry, own = own})
            end
        end
    end
    collect(timers, true)
    collect(data.party_buff_timers, false)

    for status, entries in pairs(by_status) do
        table.sort(entries, function(x, y) return (x.entry.created_order or 0) < (y.entry.created_order or 0) end)
        local slots = self_slots[status] or {}
        local count = math.min(#entries, #slots)
        local first = #entries - count + 1          -- survivors are entries[first .. #entries]

        local best_cost, best_slots
        for _, slot_set in ipairs(subsets(#slots, count)) do
            local cost = 0
            for i = 1, count do
                cost = cost + math.abs((slots[slot_set[i]] - now) - (entries[first + i - 1].entry.expires - now))
            end
            if not best_cost or cost < best_cost then best_cost, best_slots = cost, slot_set end
        end

        for i, e in ipairs(entries) do
            local entry = e.entry
            if count > 0 and i >= first then
                local remaining = slots[best_slots[i - first + 1]] - now
                report_calibration(entry, now, remaining)
                if e.own then
                    entry.duration = math.max(entry.duration, remaining)
                else
                    -- total time since the cast began, so the bar's length is right too
                    entry.duration = (now + remaining) - (entry.expires - entry.duration)
                end
                entry.expires    = now + remaining
                entry.calibrated = true
            elseif e.own and (count > 0 or now - (entry.expires - entry.duration) > PARTY_BUFF_GRACE) then
                e.holder[e.key] = nil    -- party rows are never dropped here; the 0x076 check owns that
            end
        end
    end
end

-- Non-song party rows from a cast that also hit us (shared_with_self): the
-- buff lasts as long on everyone, and our own 0x063 slot is exact, so the row
-- takes the slot closest to its estimate.
local function sync_shared_from_self(now)
    for _, entry in pairs(data.party_buff_timers) do
        local slots = entry.shared_with_self and not entry.song and self_slots[entry.status_id]
        if slots and #slots > 0 then
            local best
            for _, expiry in ipairs(slots) do
                if not best or math.abs(expiry - entry.expires) < math.abs(best - entry.expires) then best = expiry end
            end
            report_calibration(entry, now, best - now)
            entry.duration   = best - (entry.expires - entry.duration)
            entry.expires    = best
            entry.calibrated = true
        end
    end
end

-- AOE rows whose cast hit us too but whose copy on us can differ (entry.own,
-- Enhancing Magic): the row keeps the party's estimate, while the first slot
-- our 0x063 shows for the status calibrates our own estimate and, holding the
-- roll, measures Naturalist's Roll. Returns true when it measured.
local function check_own_copies(now)
    local measured = false
    for _, entry in pairs(data.party_buff_timers) do
        local own   = entry.own
        local slots = own and not own.calibrated and self_slots[own.status_id]
        local best
        for _, expiry in ipairs(slots or {}) do
            if is_new_copy(own.prior, expiry)
                    and (not best or math.abs(expiry - own.model_expires) < math.abs(best - own.model_expires)) then
                best = expiry
            end
        end
        if best then
            local remaining, probe = best - now, own.naturalist_probe
            if probe then
                own.naturalist = naturalist.measure(probe, remaining + (now - probe.cast_time))
                measured = measured or own.naturalist ~= nil
            end
            report_calibration(own, now, remaining)
            own.calibrated = true
        end
    end
    return measured
end

-- Drops party timers whose buff is no longer on the target.
--  * Songs: a member can hold several copies of one status (Valor Minuet IV and
--    V), so when they hold fewer copies than we have timers the oldest timers go.
--  * Other buffs: the timer goes when the member no longer has the status.
--  * AOE timers go only when they are lost on every member we can see from the
--    original cast.
-- Timers younger than PARTY_BUFF_GRACE are never removed, but they still count
-- toward the copies a member holds.
local function reconcile_party_timers()
    local now = os.clock()
    local groups = {}         -- "member:status" -> {copies, songs...}
    local seen, lost = {}, {}
    for key, entry in pairs(data.party_buff_timers) do
        if entry.verify_status then
            for _, member in ipairs(entry.is_aoe and entry.target_ids or {entry.target_id}) do
                local buffs = party_buffs[member]
                if buffs then
                    local copies = buffs[entry.status_id] or 0
                    if entry.song then
                        local group_key = member .. ':' .. entry.status_id
                        groups[group_key] = groups[group_key] or {copies = copies}
                        table.insert(groups[group_key], {key = key, created = entry.created_order or 0})
                    else
                        seen[key] = (seen[key] or 0) + 1
                        if copies == 0 then lost[key] = (lost[key] or 0) + 1 end
                    end
                end
            end
        end
    end
    for _, group in pairs(groups) do
        table.sort(group, function(a, b) return a.created < b.created end)
        local surplus = #group - group.copies
        for i, item in ipairs(group) do
            seen[item.key] = (seen[item.key] or 0) + 1
            if i <= surplus then lost[item.key] = (lost[item.key] or 0) + 1 end
        end
    end
    for key, members in pairs(seen) do
        local entry = data.party_buff_timers[key]
        if lost[key] == members and now - (entry.expires - entry.duration) > PARTY_BUFF_GRACE then
            data.party_buff_timers[key] = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Naturalist's Roll on party members
--
-- A party timer cast on members who all hold the roll carries `roll` =
-- {enh_term, potency, generation}: the gear term of its estimate, the potency
-- applied to it (nil while we have not measured one) and which of our rolls
-- that was. See naturalist.lua for the measurement.
-------------------------------------------------------------------------------

-- Party timers cast before we had measured the roll take the measurement once
-- we have it, as long as it is still the roll that was up when they were cast.
local function apply_measured_roll()
    local potency = naturalist.potency()
    if not potency then return end
    for _, entry in pairs(data.party_buff_timers) do
        local roll = entry.roll
        if roll and roll.potency == nil and roll.generation == naturalist.generation() then
            local duration = naturalist.scale(entry.duration, roll.enh_term, 0, potency)
            entry.expires  = entry.expires + (duration - entry.duration)
            entry.duration = duration
            roll.potency   = potency
        end
    end
end

-------------------------------------------------------------------------------
-- Packet handlers
-------------------------------------------------------------------------------
local function next_order()
    local order = data.next_order
    data.next_order = order + 1
    return order
end

local function handle_spell(act)
    local spell = res.spells[act.param]
    if not spell then return end

    -- One context for both duration estimates below, so the caster and the
    -- worn gear are read once per cast.
    local context = buff_duration.new_context()

    -- The helper also covers spells the resources list without a duration
    -- (Invisible, Plenilune Embrace, ...), so it decides whether to track.
    local party_d = buff_duration.get_spell_duration(act.param, false, context) or spell.duration
    if not party_d or party_d <= 0 then return end

    local real_status = buff_duration.get_status(act.param) or spell.status
    local status_id   = real_status or act.param
    local song        = spell.type == 'BardSong'
    local key_id      = timer_id(spell, act.param, status_id)
    local group_id    = song and key_id or nil
    -- Only a real status id can be matched against buff lists; for spells
    -- without one status_id falls back to the spell id.
    local verify_status = real_status ~= nil

    -- Collect all non-resisted targets first so we can detect AOE.
    local hit_self   = false
    local party_hits = {}
    for _, target in ipairs(act.targets) do
        for _, action in ipairs(target.actions) do
            if not resist_msgs[action.message] then
                if target.id == player_id then
                    hit_self = true
                else
                    local mob = windower.ffxi.get_mob_by_id(target.id)
                    if mob and not mob.is_npc then
                        table.insert(party_hits, {id = target.id, name = mob.name})
                    end
                end
                break
            end
        end
    end

    -- Our own copy: the helper's geared duration (including Composure's x3);
    -- spells it does not cover start from the resource value.
    local now_clock = os.clock()
    local own_d = hit_self and buff_duration.get_spell_duration(act.param, true, context) or nil

    if hit_self and #party_hits <= 1 then
        local d = own_d or spell.duration or party_d
        -- Derive remaining from cached server expiry (os.clock()-based) so the
        -- value is accurate even if the last 0x063 arrived minutes ago.
        local cached_expiry = not song and buff_sync_expiry[status_id] or nil   -- shared by song tiers
        local synced_remaining = cached_expiry and math.max(0, cached_expiry - now_clock) or 0
        if synced_remaining > d then d = synced_remaining end

        -- Without a real status our 0x063 can never confirm the timer, so it is
        -- keyed apart from the buff ids and simply runs out.
        local self_key = (verify_status or song) and key_id or ('spell' .. act.param)
        local existing_entry     = data.self_buff_timers[self_key]
        local existing_remaining = existing_entry and (existing_entry.expires - now_clock) or 0
        if existing_remaining <= d then
            data.self_buff_timers[self_key] = {
                name=spell.name, expires=now_clock+d, duration=d,
                status_id=status_id, song=song, group_id=group_id,
                unsynced = not verify_status and not song or nil,
                model_expires = now_clock + (own_d or party_d),
                naturalist_probe = own_d and naturalist.probe(act.param, context, now_clock) or nil,
                prior = slots_before_cast(status_id, now_clock),
                note = buff_duration.duration_note(act.param),
                own_copy = not buff_duration.same_on_self(act.param),
                created_order=existing_entry and existing_entry.created_order or next_order(),
            }
        end
    end

    -- Naturalist's Roll: when every target holds it, the row takes the potency
    -- measured on our own buffs, or waits for that measurement. A row covering
    -- anyone without the roll keeps the plain estimate, the soonest of them.
    local function roll_for(target_ids)
        local others = context.results and context.results.others
        if not buff_duration.naturalist_applies(act.param) or not others
                or others.capped or not others.enh_term then
            return nil
        end
        for _, id in ipairs(target_ids) do
            local buffs = party_buffs[id]
            if not (buffs and buffs[naturalist.BUFF]) then return nil end
        end
        return {enh_term = others.enh_term, potency = naturalist.potency(), generation = naturalist.generation()}
    end
    -- What one target receives on top of our estimate, or nil for nothing:
    -- the roll (once measured), Rune Fencer gifts and Embolden.
    local function received_by(id)
        local buffs = party_buffs[id] or {}
        local received = {
            naturalist = buffs[naturalist.BUFF] and naturalist.potency() or nil,
            gifts      = member_gifts(id),
            embolden   = buffs[buff_duration.EMBOLDEN] and true or nil,
        }
        if received.naturalist or received.gifts > 0 or received.embolden then return received end
        return nil
    end

    -- The estimate for these targets: each target's own duration, and the row
    -- keeps the shortest (the soonest any of them runs out). So the roll and the
    -- gifts lengthen a row only when every target has them, and one Emboldened
    -- target is enough to halve it. Embolden is used up by the spell. Returns the
    -- duration and the roll to keep on the row (dropped when a cap shaped the
    -- result: a later measurement could not simply rescale it).
    local function received_duration(target_ids)
        local roll = roll_for(target_ids)
        if not buff_duration.naturalist_applies(act.param) then return party_d, roll end
        local shortest, shortest_received, capped, any = nil, nil, false, false
        for _, id in ipairs(target_ids) do
            local received = received_by(id)
            local d = party_d
            if received then
                any = true
                d = buff_duration.get_spell_duration(act.param, false, context, received)
                capped = capped or context.results.others.capped
                if received.embolden then party_buffs[id][buff_duration.EMBOLDEN] = nil end
            end
            if not shortest or d < shortest then shortest, shortest_received = d, received end
        end
        -- `//timers2 last` shows the calculation the row uses
        if any then buff_duration.get_spell_duration(act.param, false, context, shortest_received) end
        if capped then roll = nil end
        return shortest, roll
    end

    if #party_hits > 1 then
        -- AOE: compress all party targets into one entry.
        local target_ids = {}
        for _, hit in ipairs(party_hits) do table.insert(target_ids, hit.id) end
        local d, roll = received_duration(target_ids)
        data.party_buff_timers['aoe_' .. tostring(key_id)] = {
            name=spell.name, expires=os.clock()+d, duration=d, roll=roll,
            is_aoe=true, status_id=status_id, song=song, group_id=group_id,
            shared_with_self = hit_self and buff_duration.same_on_self(act.param),
            -- An AOE that hit us too, of a spell whose copy on us can differ from
            -- the party's (Enhancing Magic): no row of our own, but our 0x063
            -- slot still calibrates our estimate and can measure the roll.
            own = hit_self and own_d and not buff_duration.same_on_self(act.param) and {
                name = spell.name, status_id = status_id, own_copy = true,
                model_expires = now_clock + own_d,
                note = buff_duration.duration_note(act.param),
                naturalist_probe = naturalist.probe(act.param, context, now_clock),
                prior = slots_before_cast(status_id, now_clock),
            } or nil,
            note = buff_duration.duration_note(act.param),
            target_ids=target_ids, verify_status=verify_status,
            created_order=next_order(),
        }
    elseif #party_hits == 1 then
        local target  = party_hits[1]
        local d, roll = received_duration({target.id})
        data.party_buff_timers[tostring(key_id) .. '_' .. tostring(target.id)] = {
            name=spell.name, expires=os.clock()+d, duration=d, roll=roll,
            target_name = target.name,
            target_id   = target.id,
            status_id   = status_id,
            song = song, group_id = group_id,
            verify_status = verify_status,
            created_order=next_order(),
        }
    end

    -- The buff packets for this cast can arrive before its action packet, in
    -- which case they were processed without these new timers. A packet that
    -- recent belongs to this cast: apply it now.
    local clock = os.clock()
    if hit_self and clock - last_self_packet <= RACE_WINDOW then
        if song then apply_song_sync(data.self_buff_timers, clock) end
        sync_shared_from_self(clock)
        if check_own_copies(clock) then apply_measured_roll() end
    end
    if #party_hits > 0 and clock - last_party_packet <= RACE_WINDOW then
        reconcile_party_timers()
    end
end

local function handle_ability(act)
    local ability = res.job_abilities[act.param]
    if not ability or not ability.duration or ability.duration <= 0 then return end
    -- Only an ability that lands on us is one of our buffs; one aimed at a
    -- monster (Bully, steps) or only at a pet is not.
    local on_self = false
    for _, target in ipairs(act.targets) do
        if target.id == player_id then on_self = true; break end
    end
    if not on_self then return end
    -- An ability without a status id (Spectral Jig, Konzen-ittai, ...) cannot be
    -- confirmed by 0x063, so it is keyed apart from the buff ids and runs out.
    local key = ability.status or ('ja' .. act.param)
    data.self_buff_timers[key] = {
        name=ability.name, expires=os.clock()+ability.duration, duration=ability.duration,
        unsynced = ability.status == nil or nil,
        created_order=next_order(),
    }
end

local function handle_action(act)
    if not player_id or act.actor_id ~= player_id then return end
    if act.category == 4 then
        handle_spell(act)
    elseif act.category == 6 or act.category == 14 or act.category == 15 then
        handle_ability(act)
    end
end

local function handle_self_buff_update(raw)
    local new = {}
    local now = os.clock()
    buff_sync_expiry = {}  -- Rebuild cache from current server state
    previous_slots   = self_slots
    self_slots       = {}  -- [status] = sorted absolute expiries, one per slot

    -- Pass 1: every slot in the packet.
    local listed = {}      -- {buff_id, remaining} in packet order
    for i = 0, 31 do
        local buff_id = raw:unpack('H', 9  + i * 2)
        local ts      = raw:unpack('I', 73 + i * 4)
        if buff_id and buff_id > 0 and buff_id ~= 0xFF and buff_id ~= 0xFFFF then
            local remaining = data.buff_remaining(ts)
            -- Cache as absolute os.clock() expiry so the value stays accurate
            -- over time without needing to account for elapsed wall time later.
            if remaining and remaining > 0 then
                buff_sync_expiry[buff_id] = now + remaining
                self_slots[buff_id] = self_slots[buff_id] or {}
                table.insert(self_slots[buff_id], now + remaining)
            end
            listed[#listed + 1] = {buff_id, remaining}
        end
    end
    for _, slots in pairs(self_slots) do table.sort(slots) end
    last_self_packet = now
    if zone_check then zone_check.self = false end

    -- Whether we still hold the same Naturalist's Roll decides whether a cast in
    -- this packet may measure it, so this comes before the timers.
    local roll = self_slots[naturalist.BUFF]
    naturalist.observe_roll(roll and roll[1])
    local measured = false

    -- Pass 2: only refresh buffs we actively tracked via a cast; ignore anything
    -- else in the packet so pre-existing buffs are never introduced.
    for _, slot in ipairs(listed) do
        local buff_id, remaining = slot[1], slot[2]
        local existing = data.self_buff_timers[buff_id]
        local stale = existing and not existing.calibrated and remaining
                      and not is_new_copy(existing.prior, now + remaining)
        if stale then
            -- Still the copy from before the cast: our timer keeps its estimate
            -- until a list shows the new one.
            new[buff_id] = existing
        elseif existing and (remaining == nil or remaining > 0) then
            -- The first report after a cast holding the roll measures it.
            local probe = existing.naturalist_probe
            if probe and remaining and not existing.calibrated then
                existing.naturalist = naturalist.measure(probe, remaining + (now - probe.cast_time))
                measured = measured or existing.naturalist ~= nil
            end
            report_calibration(existing, now, remaining)
            if remaining == nil then
                existing.duration = math.huge
            elseif existing.duration == math.huge or existing.duration < remaining then
                existing.duration = remaining
            end
            existing.expires    = remaining and (now + remaining) or math.huge
            existing.calibrated = true
            new[buff_id] = existing
        end
        -- remaining == 0: buff expired, omit from new (drops the entry)
    end
    if check_own_copies(now) then measured = true end
    if measured then apply_measured_roll() end

    -- Song timers are matched to the slots as a group (see apply_song_sync);
    -- timers without a status cannot be matched at all and run on their own clock.
    for key, entry in pairs(data.self_buff_timers) do
        if entry.song or entry.unsynced then new[key] = entry end
    end
    data.self_buff_timers = new
    apply_song_sync(new, now)
    sync_shared_from_self(now)
end

-- 0x076 holds up to five other party members, 48 bytes each: id at +0, a 2-bit
-- high part per buff packed into the 8 bytes at +8, and 32 low bytes at +16
-- (255 ends the list).
local function handle_party_buff_update(raw)
    party_buffs = {}
    for i = 0, 4 do
        local base      = i * 48 + 5
        local member_id = raw:unpack('I', base)
        if member_id == 0 then break end
        -- Out of zone / out of sight members can report an empty list while still
        -- buffed, so only trust members the client can currently see.
        if windower.ffxi.get_mob_by_id(member_id) then
            local buffs = {}
            for j = 1, 32 do
                local low = raw:byte(base + 16 + j - 1)
                if low == 255 then break end
                local high = math.floor(raw:byte(base + 8 + math.floor((j - 1) / 4)) / 4 ^ ((j - 1) % 4)) % 4
                local buff_id = low + 256 * high
                buffs[buff_id] = (buffs[buff_id] or 0) + 1
            end
            party_buffs[member_id] = buffs
        end
    end
    last_party_packet = os.clock()
    reconcile_party_timers()
end

-- Drops every timer for one party member: their single-target rows, and their
-- share of AOE rows (an AOE row with nobody left goes too).
local function drop_member_timers(member_id)
    party_buffs[member_id] = nil
    for key, entry in pairs(data.party_buff_timers) do
        if entry.is_aoe then
            local remaining = {}
            for _, id in ipairs(entry.target_ids) do
                if id ~= member_id then table.insert(remaining, id) end
            end
            if #remaining == 0 then
                data.party_buff_timers[key] = nil
            else
                entry.target_ids = remaining
            end
        elseif entry.target_id == member_id then
            data.party_buff_timers[key] = nil
        end
    end
end

-- 0x0DD (party / alliance member update): a non-zero zone field means the member
-- is in another zone. Their buffs and ours are no longer in step, so their timers go.
-- It also carries their main job (0x22), its level (0x23) and master level (0x26).
local function handle_member_update(raw)
    local member = raw:unpack('I', 5)
    if not member or member == player_id then return end
    local zone = raw:unpack('H', 33)
    if zone ~= 0 then drop_member_timers(member) end

    local job, level, master_level = raw:byte(35), raw:byte(36), raw:byte(39)
    local m = members[member]
    if not m or m.job ~= job then
        m = {}                      -- a new job: its stars are not known yet
        members[member] = m
    end
    m.job, m.level, m.master_level = job, level, master_level
end

-- 0x00D (another player's update) arrives constantly for everyone in range, so
-- anyone not in our party is dropped after reading the id. The job mastery stars
-- flag (0x33 bit 0x40) is only read from updates that carry the vitals block
-- (0x0A bit 0x04), and once seen it stays until their job changes: hiding the
-- stars, or an update without them, does not unmaster a job.
local function handle_player_update(raw)
    local m = members[raw:unpack('I', 5)]
    if not m then return end
    local update_vitals = math.floor(raw:byte(11) / 4) % 2 == 1
    if update_vitals and math.floor(raw:byte(52) / 64) % 2 == 1 then m.stars = true end
end

-- 0x029 arrives for every battle message in range, so the message id is read
-- first (offset 0x18) and only wear-off and death messages read the target
-- (0x08) and status (0x0C).
local function handle_action_message(raw)
    local message_id = raw:unpack('H', 25)
    local wore, died = buff_wore_msgs[message_id], death_msgs[message_id]
    if not wore and not died then return end
    local target_id = raw:unpack('I', 9)

    if wore then
        local status_id = raw:unpack('I', 13)
        if target_id == player_id then
            data.self_buff_timers[status_id] = nil
            remove_worn_song(data.self_buff_timers, status_id, nil)
        end
        data.party_buff_timers[tostring(status_id) .. '_' .. tostring(target_id)] = nil
        remove_worn_song(data.party_buff_timers, status_id, target_id)
    end
    if died then
        if target_id == player_id then
            data.self_buff_timers  = {}
            data.party_buff_timers = {}
        else
            -- Buffs are lost on death; drop that member's timers.
            drop_member_timers(target_id)
        end
    end
end

function M.incoming(id, raw)
    if id == 0x028 then
        -- Every action in range arrives here. The actor id (offset 0x05) is read
        -- before the full parse, which builds tables for every target and effect.
        if player_id and raw:unpack('I', 6) == player_id then
            handle_action(windower.packets.parse_action(raw))
        end
    elseif id == 0x029 then
        handle_action_message(raw)
    elseif id == 0x063 and raw:byte(5) == 0x09 then
        handle_self_buff_update(raw)
    elseif id == 0x076 then
        handle_party_buff_update(raw)
    elseif id == 0x0DD then
        handle_member_update(raw)
    elseif id == 0x00D then
        handle_player_update(raw)
    elseif id == 0x050 then
        buff_duration.handle_equipment_packet(raw)
    end
end

-------------------------------------------------------------------------------
-- Session events
-------------------------------------------------------------------------------
local function refresh_player()
    local player = windower.ffxi.get_player()
    if player then
        player_id        = player.id
        data.main_job_id = player.main_job_id
    end
end

-- Addon load and login.
function M.login()
    local info = windower.ffxi.get_info()
    if info.logged_in then
        refresh_player()
        buff_duration.sync_equipment()
    end
end

function M.job_change()
    refresh_player()
end

-- Drops every cache built from what the server told us about the current zone.
local function reset_server_state()
    data.party_buff_timers   = {}
    data.spell_recast_peak   = {}
    data.ability_recast_peak = {}
    buff_sync_expiry         = {}
    party_buffs              = {}
    self_slots               = {}
    previous_slots           = {}
end

function M.logout()
    player_id        = nil
    data.main_job_id = nil
    zone_check       = nil
    data.self_buff_timers = {}
    reset_server_state()
    naturalist.reset()
    members = {}    -- kept through zoning: a job, and its mastery, do not change there
end

-- A zone change drops other players' timers and everything the server told us
-- about the old zone; our own timers wait for the first 0x063 (see ZONE_SETTLE).
function M.zone_change()
    buff_duration.sync_equipment()  -- the server re-sends gear on zoning; re-seed in case that burst came first
    reset_server_state()
    zone_check = {time = os.clock(), self = true}
end

-- Runs every display tick. While a zone check is open and our first 0x063 never
-- arrived by ZONE_SETTLE, our own timers cannot be trusted and go.
function M.tick()
    if not zone_check or os.clock() - zone_check.time < ZONE_SETTLE then return end
    if zone_check.self then data.self_buff_timers = {} end
    zone_check = nil
end

return M
