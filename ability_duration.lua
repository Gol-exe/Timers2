--[[
    Ability duration helper for Timers2.
    Estimates how long a job ability's buff lasts, in seconds, for the abilities
    whose duration depends on the user's gear, merits, job points or skill.
    Returns nil for everything else so the caller keeps the resource duration.

    Shares buff_duration.lua's caster read and gear scan (the same context), so
    gear is read from the game's item descriptions and augments, with
    buff_gear.lua for the few items whose text has no number.

    Modelled:
      Phantom Roll (bg-wiki "Phantom Roll"): 300s, +20s per Winning Streak merit
        level (+6s more with the relic head), +2s per Phantom Roll Duration job
        point level, plus gear seconds. Everyone in range gets the same time.
      Blood Pact: Ward (bg-wiki "Summoning Magic"): the 1, 2 and 3 minute wards
        gain 1s per Summoning magic skill over 300, then 1% per Astral Conduit
        Effect job point level while Astral Conduit is active. The 15 and 60
        minute wards are flat.
      Our own job abilities (SPECS below): job point seconds (Windower's job
        point text), group 2 merits after the first level, and gear read from
        '"<Ability>" duration +N' or '+N%' text. Seconds are added to the base
        and percentages then multiply it, as bg-wiki states for Jigs ("added to
        base duration before modification").

    Not modelled: SP abilities and the Circles, whose relic / empyrean / AF
    pieces only say "Enhances ... effect" with no value known; Hide, Camouflage
    and Meditate, which have no duration in the resources (so are not timed);
    weapons that extend a buff during a weapon skill or skillchain.
]]

local res           = require('resources')
local buff_duration = require('buff_duration')

local M = {}

local PLD, DRK, BST, SMN, COR, DNC, RUN = 7, 8, 9, 15, 17, 19, 22
local SABER_DANCE    = 410                  -- buff id
local ASTRAL_CONDUIT = 504                  -- buff id
local WINNING_STREAK = 20                   -- seconds per merit level
local ROLL_JP        = 2                    -- seconds per job point level
local SKILL_FLOOR    = 300
local SCALING_WARDS  = {[60] = true, [120] = true, [180] = true}

local function phantom_roll(ability, player, totals, step)
    local duration = ability.duration
    local main, level = player.main_job_id, player.main_job_level
    if main == COR and level >= 75 then
        local merits = player.merits and player.merits.winning_streak or 0
        duration = duration + merits * (WINNING_STREAK + totals.winning)
        step(('winning streak %d x%d'):format(merits, WINNING_STREAK + totals.winning), duration)
    end
    if main == COR and level == 99 then
        local points = player.job_points and player.job_points.cor
        local jp = points and points.phantom_roll_duration or 0
        duration = duration + jp * ROLL_JP
        step(('phantom roll duration JP %d x%d'):format(jp, ROLL_JP), duration)
    end
    duration = duration + totals.roll
    step(('gear +%.0f'):format(totals.roll), duration)
    return duration
end

local function ward(ability, player, buffs, totals, step)
    local duration = ability.duration
    if not SCALING_WARDS[duration] then
        step('flat duration', duration)
        return duration
    end
    local base_skill = player.skills and player.skills.summoning_magic or 0
    local skill = base_skill + totals.summoning
    duration = duration + math.max(skill - SKILL_FLOOR, 0)
    step(('summoning skill %d (+%d gear) over %d'):format(skill, totals.summoning, SKILL_FLOOR), duration)
    if buffs[ASTRAL_CONDUIT] and player.main_job_id == SMN and player.main_job_level == 99 then
        local points = player.job_points and player.job_points.smn
        local jp = points and points.astral_conduit_effect or 0
        duration = duration * (1 + jp / 100)
        step(('astral conduit JP +%d%%'):format(jp), duration)
    end
    return duration
end

-------------------------------------------------------------------------------
-- Job abilities
--
-- [ability id] = {
--   gear   = the name gear text uses ('"Jig" duration +40%')
--   jp     = {job id, job key, job point key, seconds per level}: main job at 99
--   merit  = {job id, merit key, seconds per level after the first}: main job, 75+
--   saber  = true: Saber Dance merits, +5% per level after the first while
--            Saber Dance is up (Windower's merit text, bg-wiki "Category:Samba")
--   status = the buff a timer follows when the resources name none
--   caster = true: the buff lands on the user whoever the target is (Cover)
-- }
-- Job point and merit values are Windower's own text for them.
-------------------------------------------------------------------------------
local SPECS = {}
local function spec(ids, fields)
    for _, id in ipairs(ids) do SPECS[id] = fields end
end
local JIG_JP = {DNC, 'dnc', 'jig_duration', 1}
-- Spectral Jig grants Sneak and Invisible, which last as long: the timer
-- follows Invisible, so our buff list corrects it.
spec({196},      {gear = 'Jig', jp = JIG_JP, status = 69})
spec({197, 381}, {gear = 'Jig', jp = JIG_JP})                          -- Chocobo Jig, II
-- Sambas keep the resources' 90s base: Drain / Aspir Samba with 20 job point
-- levels measured 2:09 on the server = 90 + 40 (bg-wiki's 2:00 base is wrong).
spec({184, 185, 186, 187, 188, 189}, {gear = 'Samba', jp = {DNC, 'dnc', 'samba_duration', 2}, saber = true})
spec({31},  {gear = 'Berserk'})
spec({32},  {gear = 'Warcry'})
spec({33},  {gear = 'Defender'})
spec({34},  {gear = 'Aggressor'})
spec({267}, {gear = 'Blood Rage'})
spec({42},  {gear = 'Flee'})
spec({79},  {gear = 'Cover', jp = {PLD, 'pld', 'cover_duration', 1}, caster = true})
spec({92},  {gear = 'Rampart'})
spec({157}, {merit = {PLD, 'fealty', 5}})
spec({49},  {gear = 'Souleater', jp = {DRK, 'drk', 'souleater_duration', 1}})
spec({51},  {gear = 'Last Resort'})
spec({280}, {jp = {DRK, 'drk', 'scarlet_delirium_duration', 1}})
spec({162}, {merit = {BST, 'killer_instinct', 10}})
spec({366}, {gear = 'Vallation', jp = {RUN, 'run', 'vallation_duration', 1}})
spec({371}, {gear = 'Valiance',  jp = {RUN, 'run', 'vallation_duration', 1}})
spec({373}, {gear = 'Liement'})
spec({374}, {jp = {RUN, 'run', 'one_for_all_effect_duration', 1}})

local function job_ability(ability, entry, player, buffs, totals, step)
    local duration = ability.duration
    local main, level = player.main_job_id, player.main_job_level
    if entry.jp and main == entry.jp[1] and level == 99 then
        local points = player.job_points and player.job_points[entry.jp[2]]
        local jp = points and points[entry.jp[3]] or 0
        duration = duration + jp * entry.jp[4]
        step(('%s %d x%d'):format(entry.jp[3], jp, entry.jp[4]), duration)
    end
    if entry.merit and main == entry.merit[1] and level >= 75 then
        local merits = player.merits and player.merits[entry.merit[2]] or 0
        duration = duration + math.max(merits - 1, 0) * entry.merit[3]
        step(('%s merits %d (x%d after the first)'):format(entry.merit[2], merits, entry.merit[3]), duration)
    end
    local bonus = entry.gear and totals.ja[entry.gear] or {sec = 0, pct = 0}
    duration = duration + bonus.sec
    local percent = bonus.pct
    if entry.saber and buffs[SABER_DANCE] and main == DNC and level >= 75 then
        local merits = player.merits and player.merits.saber_dance or 0
        percent = percent + math.max(merits - 1, 0) * 0.05
    end
    duration = duration * (1 + percent)
    if entry.gear or entry.saber then
        step(('gear +%.0fs, %+.0f%%'):format(bonus.sec, percent * 100), duration)
    end
    return duration
end

-- The buff id an ability's timer follows when the resources name none, or nil.
function M.get_status(ability_id)
    local entry = SPECS[ability_id]
    return entry and entry.status
end

-- True for an ability whose buff lands on the user whatever it targets (Cover).
function M.lands_on_caster(ability_id)
    local entry = SPECS[ability_id]
    return entry ~= nil and entry.caster == true
end

-- Seconds the buff of ability `ability_id` lasts, or nil when it is not
-- modelled (or nobody is logged in). `context` comes from
-- buff_duration.new_context(); a new one is made when it is nil.
function M.get_ability_duration(ability_id, context)
    local ability = res.job_abilities[ability_id]
    if not ability or not ability.duration then return nil end
    local kind = ability.type == 'CorsairRoll' and 'roll'
              or ability.type == 'BloodPactWard' and 'ward'
              or SPECS[ability_id] and 'job' or nil
    if not kind then return nil end
    context = context or buff_duration.new_context()
    local player, buffs = buff_duration.context_player(context)
    if not player then return nil end
    local totals = buff_duration.context_totals(context)

    local steps = {}
    local function step(label, value)
        steps[#steps + 1] = ('%-34s -> %.1f'):format(label, value)
    end
    step('base', ability.duration)
    local duration
    if kind == 'roll' then
        duration = phantom_roll(ability, player, totals, step)
    elseif kind == 'job' then
        duration = job_ability(ability, SPECS[ability_id], player, buffs, totals, step)
    else
        duration = ward(ability, player, buffs, totals, step)
    end
    steps[#steps + 1] = ('final %.1f seconds'):format(duration)
    buff_duration.record_ability_trace({ability_id = ability_id, name = ability.name or ability.en or '?',
                                        steps = steps, totals = totals})
    return duration
end

return M
