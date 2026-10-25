--[[
    Naturalist's Roll helper for Timers2.

    The roll lengthens Enhancing Magic its holders receive, by an amount that
    depends on the roll number and the Corsair's gear, none of which we can see.
    What we can see is our own buff list: when we hold the roll and cast an
    Enhancing spell on ourselves, the server's duration differs from the
    duration helper's estimate by exactly the roll (if nothing else unmodelled
    is in play), so the potency can be measured. It is kept only while we keep
    that roll, and assumed to be the same on party members who hold it too.

    bg-wiki "Enhancing Magic": the roll is additive with the gear-listed
    duration percentage,
        ... x (1 + gear% + roll) x (1 + augments%) x gifts x Perpetuance
    so with our estimate M (no roll), its gear term E = 1 + gear% and the
    server's duration A:
        A = M x (E + roll) / E      =>      roll = E x (A / M - 1)

    Interface:
      probe(spell_id, context, cast_time)  at a self-cast: what a later
                                           measurement needs, or nil
      measure(probe, actual)               from our first 0x063 after that cast:
                                           the potency, or nil when rejected
      observe_roll(expiry)                 every 0x063: the roll's expiry, or nil
      potency(), generation()              the current measurement
      scale(duration, enh_term, from, to)  a duration under another potency
      forget(), describe()
]]

local buff_duration = require('buff_duration')

local M = {}

M.BUFF = 339                -- Naturalist's Roll (res.buffs)

-- One second of server rounding may move a measurement by at most this much;
-- shorter spells cannot tell roll numbers apart (they are a percent apart).
local MAX_ERROR = 0.02
-- Outside this the difference is not the roll (it runs -5% to about +35%):
-- most likely gear the duration helper could not read.
local LOWEST, HIGHEST = -0.10, 0.60
-- The roll's remaining time growing by more than this means it was rolled again.
local REROLL_SLACK = 2

local state = {
    potency    = nil,    -- fraction (0.12 = +12%), or nil when not measured
    spell      = nil,    -- name of the spell it was measured on
    generation = 0,      -- bumped whenever the roll we hold changes or goes
    expiry     = nil,    -- the roll's absolute os.clock() expiry from our last 0x063
}

function M.potency() return state.potency end
function M.generation() return state.generation end

function M.forget()
    state.potency, state.spell, state.inputs = nil, nil, nil
    state.generation = state.generation + 1
end

-- Called with our own copy's estimate already computed in `context` (see
-- buff_duration.get_spell_duration). Returns nil when this cast cannot
-- measure the roll: not Enhancing Magic, no roll on us, another received
-- bonus mixed in, or a cap that hides part of the difference.
function M.probe(spell_id, context, cast_time)
    local own    = context.results and context.results.own
    local player = context.player
    local buffs  = context.buffs or {}
    if not own or not player or not buff_duration.naturalist_applies(spell_id) then return nil end
    -- A random base (Sneak, Invisible) would be measured as the roll.
    if buff_duration.random_duration(spell_id) then return nil end
    if not buffs[M.BUFF] then return nil end
    -- Embolden halves the spell in our estimate, but its factor comes from an
    -- old bg-wiki revision and gear can change it: not trusted to measure with.
    if buffs[buff_duration.EMBOLDEN] then return nil end
    -- Our own Rune Fencer gifts are in the estimate, unless the client hides our
    -- job points: then they would be measured as part of the roll.
    if buff_duration.own_rune_fencer_gifts(player) == nil then return nil end
    if own.capped or not own.enh_term or own.duration <= 0 then return nil end
    return {
        model      = own.duration,
        enh_term   = own.enh_term,
        cast_time  = cast_time,
        generation = state.generation,
        spell      = own.name,
    }
end

-- `actual` is the full duration the server gave the buff (its remaining time
-- plus the time since the cast).
function M.measure(probe, actual)
    if probe.generation ~= state.generation then return nil end   -- the roll changed since the cast
    if probe.enh_term / probe.model > MAX_ERROR then return nil end
    local potency = probe.enh_term * (actual / probe.model - 1)
    if potency < LOWEST or potency > HIGHEST then return nil end
    -- Latest wins: Double-Up can change the roll without it ever leaving us.
    state.potency, state.spell = potency, probe.spell
    state.inputs = {model = probe.model, actual = actual, enh_term = probe.enh_term}
    return potency
end

-- Our 0x063 lists the roll with its expiry (nil when we no longer hold it).
-- Losing it, or the expiry jumping forward (a new roll), forgets the potency.
function M.observe_roll(expiry)
    local previous = state.expiry
    state.expiry = expiry
    if not expiry then
        if previous or state.potency then M.forget() end
    elseif previous and expiry > previous + REROLL_SLACK then
        M.forget()
    end
end

-- A duration whose gear term was enh_term, moved from one potency to another.
function M.scale(duration, enh_term, from, to)
    return duration * (enh_term + to) / (enh_term + from)
end

function M.describe()
    if state.potency then
        -- The inputs, so a wrong measurement shows which side is off.
        local inputs = state.inputs or {}
        return ('Naturalist\'s Roll: %+.1f%% (measured on %s: our estimate %.0fs, server %.0fs, gear term x%.2f)'):format(
            state.potency * 100, state.spell or '?', inputs.model or 0, inputs.actual or 0, inputs.enh_term or 0)
    elseif state.expiry then
        return 'Naturalist\'s Roll: active, not measured yet (cast an Enhancing spell on yourself)'
    end
    return 'Naturalist\'s Roll: not active'
end

-- Logout: nothing about the roll carries over.
function M.reset()
    M.forget()
    state.expiry = nil
end

return M
