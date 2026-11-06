--[[
    Party cures, enhancing magic, enfeebles, and nukes.
    Only spells this character has learned and can currently cast are used.
]]

local res = require('resources')
local joblevels = require('levels')

local M = { line = '' }

local spell_by_en
local buff_until = {}
local debuff_until = {}
local summary_at, summary_text = 0, ''

local ENHANCE = {
    { key = 'haste', names = { 'Haste II', 'Haste' }, status = 33, party = true, duration = 180 },
    { key = 'protect', names = { 'Protectra V', 'Protectra IV', 'Protectra III', 'Protectra II', 'Protectra', 'Protect V', 'Protect IV', 'Protect III', 'Protect II', 'Protect' }, status = 40, aoe = true, duration = 1800 },
    { key = 'shell', names = { 'Shellra V', 'Shellra IV', 'Shellra III', 'Shellra II', 'Shellra', 'Shell V', 'Shell IV', 'Shell III', 'Shell II', 'Shell' }, status = 41, aoe = true, duration = 1800 },
    { key = 'refresh', names = { 'Refresh III', 'Refresh II', 'Refresh' }, status = 43, party = true, duration = 150, mp = true },
    { key = 'regen', names = { 'Regen V', 'Regen IV', 'Regen III', 'Regen II', 'Regen' }, status = 42, party = true, duration = 60, hurt = true },
    { key = 'stoneskin', names = { 'Stoneskin' }, status = 37, self_only = true, duration = 300 },
    { key = 'aquaveil', names = { 'Aquaveil' }, status = 39, self_only = true, duration = 600 },
    { key = 'blink', names = { 'Blink' }, status = 36, self_only = true, duration = 300 },
    { key = 'phalanx', names = { 'Phalanx' }, status = 116, self_only = true, duration = 180 },
}

local ENFEEBLE = {
    { key = 'dia', names = { 'Dia III', 'Dia II', 'Dia' } },
    { key = 'slow', names = { 'Slow II', 'Slow' } },
    { key = 'paralyze', names = { 'Paralyze II', 'Paralyze' } },
    { key = 'blind', names = { 'Blind II', 'Blind' } },
    { key = 'silence', names = { 'Silence' } },
    { key = 'addle', names = { 'Addle II', 'Addle' } },
    { key = 'distract', names = { 'Distract III', 'Distract II', 'Distract' } },
    { key = 'frazzle', names = { 'Frazzle III', 'Frazzle II', 'Frazzle' } },
    { key = 'poison', names = { 'Poison II', 'Poison' } },
    { key = 'bind', names = { 'Bind' } },
    { key = 'gravity', names = { 'Gravity II', 'Gravity' } },
}

local NUKES = {
    Fire = { 'Fire VI', 'Firaja', 'Firaga III', 'Fire V', 'Firaga II', 'Fire IV', 'Firaga', 'Fire III', 'Fire II', 'Fire' },
    Ice = { 'Blizzard VI', 'Blizzaja', 'Blizzaga III', 'Blizzard V', 'Blizzaga II', 'Blizzard IV', 'Blizzaga', 'Blizzard III', 'Blizzard II', 'Blizzard' },
    Wind = { 'Aero VI', 'Aeroja', 'Aeroga III', 'Aero V', 'Aeroga II', 'Aero IV', 'Aeroga', 'Aero III', 'Aero II', 'Aero' },
    Earth = { 'Stone VI', 'Stoneja', 'Stonega III', 'Stone V', 'Stonega II', 'Stone IV', 'Stonega', 'Stone III', 'Stone II', 'Stone' },
    Lightning = { 'Thunder VI', 'Thundaja', 'Thundaga III', 'Thunder V', 'Thundaga II', 'Thunder IV', 'Thundaga', 'Thunder III', 'Thunder II', 'Thunder' },
    Water = { 'Water VI', 'Waterja', 'Waterga III', 'Water V', 'Waterga II', 'Water IV', 'Waterga', 'Water III', 'Water II', 'Water' },
    Light = { 'Holy II', 'Holy', 'Banishga II', 'Banishga', 'Banish V', 'Banish IV', 'Banish III', 'Banish II', 'Banish' },
    Dark = { 'Comet', 'Noctohelix' },
}

local BARS = {
    Fire = { names = { 'Barfira', 'Barfire' }, status = 100, duration = 480 },
    Ice = { names = { 'Barblizzara', 'Barblizzard' }, status = 101, duration = 480 },
    Wind = { names = { 'Baraera', 'Baraero' }, status = 102, duration = 480 },
    Earth = { names = { 'Barstonra', 'Barstone' }, status = 103, duration = 480 },
    Lightning = { names = { 'Barthundra', 'Barthunder' }, status = 104, duration = 480 },
    Water = { names = { 'Barwatera', 'Barwater' }, status = 105, duration = 480 },
}

local STATUS_BARS = {
    { names = { 'Barsleepra', 'Barsleep' }, status = 106, duration = 480 },
    { names = { 'Barparalyzra', 'Barparalyze' }, status = 108, duration = 480 },
    { names = { 'Barsilencera', 'Barsilence' }, status = 110, duration = 480 },
}

local function lookup(name)
    if not spell_by_en then
        spell_by_en = {}
        for _, spell in pairs(res.spells) do
            if type(spell) == 'table' and type(spell.en) == 'string' then
                spell_by_en[spell.en:lower()] = spell
            end
        end
    end
    return spell_by_en[name:lower()]
end

local function max_mp(player)
    if player.max_mp and player.max_mp > 0 then return player.max_mp end
    if player.vitals and player.vitals.max_mp and player.vitals.max_mp > 0 then return player.vitals.max_mp end
    return 0
end

local function mp_now(player)
    return (player.vitals and player.vitals.mp) or 0
end

local function knows(player, spell)
    local known = windower.ffxi.get_spells()
    if not known or not known[spell.id] then return false end
    local levels = spell.levels
    if type(levels) ~= 'table' then return true end
    local any = false
    for _ in pairs(levels) do any = true break end
    if not any then return true end
    local main = levels[player.main_job_id]
    local sub = levels[player.sub_job_id]
    if main and main > 99 and player.main_job_level >= 99 then return true end
    if main and player.main_job_level >= main then return true end
    if sub and player.sub_job_level >= sub then return true end
    return false
end

local function spell_ready(spell)
    local recasts = windower.ffxi.get_spell_recasts()
    if not recasts then return true end
    local timer = recasts[spell.recast_id]
    return timer == nil or timer <= 0
end

local function can_pay(player, spell, reserve)
    local cost = spell.mp_cost or 0
    local mp = mp_now(player)
    if mp < cost then return false end
    if not reserve then return true end
    local cap = max_mp(player)
    if cap <= 0 then return true end
    return (100 * (mp - cost) / cap) >= reserve
end

local function best_spell(player, names, reserve)
    for i = 1, #names do
        local spell = lookup(names[i])
        if spell and knows(player, spell) and spell_ready(spell) and can_pay(player, spell, reserve) then
            return spell
        end
    end
    return nil
end

local function has_buff(player, id)
    local buffs = player.buffs or {}
    for i = 1, #buffs do
        if buffs[i] == id then return true end
    end
    return false
end

local function silenced(player)
    return has_buff(player, 6)
end

local function party_members()
    local party = windower.ffxi.get_party()
    local out = {}
    if not party or not party.p0 then return out end
    local zone = party.p0.zone
    for i = 0, 5 do
        local m = party['p' .. i]
        if type(m) == 'table' and m.name and m.name ~= '' and m.hpp and m.hpp > 0 and m.zone == zone then
            local dist = 999
            if m.mob and m.mob.distance then dist = math.sqrt(m.mob.distance) end
            out[#out + 1] = {
                name = m.name,
                hpp = m.hpp,
                mpp = m.mpp or 100,
                dist = dist,
                self = i == 0,
                mob = m.mob,
            }
        end
    end
    return out
end

local function cast(env, spell, target)
    local who = target
    if who ~= '<me>' and who ~= '<t>' then who = '"' .. who .. '"' end
    -- names are passed quoted only when they are player names; <me> and <t> stay bare.
    local cmd
    if target == '<me>' or target == '<t>' then
        cmd = string.format('/ma "%s" %s', spell.en:gsub('"', ''), target)
    else
        cmd = string.format('/ma "%s" %s', spell.en:gsub('"', ''), target)
    end
    if env.act(cmd, (spell.cast_time or 2) + 1.8) then
        M.line = spell.en .. ' -> ' .. target
        return true
    end
    return false
end

local function mark_party(members, status, duration)
    local until_t = os.clock() + duration
    for i = 1, #members do
        buff_until[members[i].name .. ':' .. status] = until_t
    end
end

local function buff_marked(member, status)
    local until_t = buff_until[member.name .. ':' .. status]
    return until_t ~= nil and os.clock() < until_t
end

local function needs_buff(player, member, group)
    if member.self and has_buff(player, group.status) then return false end
    if buff_marked(member, group.status) then return false end
    if group.mp and not member.self and member.mpp >= 90 then return false end
    if group.hurt and member.hpp >= 100 then return false end
    return true
end

local function cure_names(hpp)
    if hpp <= 30 then return { 'Cure VI', 'Cure V', 'Cure IV', 'Cure III' } end
    if hpp <= 50 then return { 'Cure V', 'Cure IV', 'Cure III', 'Cure II' } end
    if hpp <= 70 then return { 'Cure IV', 'Cure III', 'Cure II' } end
    return { 'Cure III', 'Cure II', 'Cure' }
end

local function curaga_names(hpp)
    if hpp <= 40 then return { 'Curaga V', 'Curaga IV', 'Curaga III', 'Curaga II' } end
    return { 'Curaga III', 'Curaga II', 'Curaga' }
end

local ja_used = {}
local ja_by_en

local function find_ja(name)
    if not ja_by_en then
        ja_by_en = {}
        for _, ability in pairs(res.job_abilities) do
            if type(ability) == 'table' and type(ability.en) == 'string' then
                ja_by_en[ability.en:lower()] = ability
            end
        end
    end
    return ja_by_en[name:lower()]
end

local function ja_ready(name)
    local now = os.clock()
    local ability = find_ja(name)
    if not ability then return false end
    if not ability.recast_id or ability.recast_id == 0 then
        return not ja_used[name] or (now - ja_used[name]) > 3600
    end
    if ja_used[name] and (now - ja_used[name]) < 8 then return false end
    local recasts = windower.ffxi.get_ability_recasts()
    local timer = recasts and recasts[ability.recast_id]
    return timer == nil or timer <= 0
end

local function use_ja(env, name, target)
    if not joblevels.allows(env.player, name) then return false end
    if not ja_ready(name) then return false end
    local cmd = string.format('/ja "%s" %s', name:gsub('"', ''), target or '<me>')
    if env.act(cmd, 2) then
        ja_used[name] = os.clock()
        M.line = name
        return true
    end
    return false
end

local function job_is(player, job)
    return player.main_job == job or player.sub_job == job
end

local function self_hpp(env, members)
    if env.me and env.me.hpp then return env.me.hpp end
    for i = 1, #members do
        if members[i].self then return members[i].hpp end
    end
    return 100
end

local function lowest_hpp(members)
    local low = 100
    for i = 1, #members do
        if members[i].hpp < low then low = members[i].hpp end
    end
    return low
end

local function try_mp(env, player, members, heal)
    local cap = max_mp(player)
    local mpp = 100
    if cap > 0 then mpp = 100 * mp_now(player) / cap end
    local low = lowest_hpp(members)
    local mine = self_hpp(env, members)

    if job_is(player, 'WHM') and low <= 15 and use_ja(env, 'Benediction', '<me>') then
        return true
    end
    if job_is(player, 'WHM') and heal.cure ~= false and low <= 35 and not has_buff(player, 78) and use_ja(env, 'Divine Seal', '<me>') then
        return true
    end
    if job_is(player, 'WHM') and low <= 30 and use_ja(env, 'Sacrosanctity', '<me>') then
        return true
    end
    if job_is(player, 'WHM') and not has_buff(player, 417) and use_ja(env, 'Afflatus Solace', '<me>') then
        return true
    end
    if job_is(player, 'SCH') then
        if has_buff(player, 188) and mpp < 40 and use_ja(env, 'Sublimation', '<me>') then return true end
        if not has_buff(player, 187) and not has_buff(player, 188) and use_ja(env, 'Sublimation', '<me>') then return true end
    end
    if job_is(player, 'RDM') and not has_buff(player, 419) and use_ja(env, 'Composure', '<me>') then
        return true
    end
    if job_is(player, 'RDM') and mpp < 20 and mine > 40 and use_ja(env, 'Convert', '<me>') then
        return true
    end
    if job_is(player, 'BLM') and mpp < 15 and use_ja(env, 'Manafont', '<me>') then
        return true
    end
    return false
end

local function mark_near(members, status, duration, reach)
    local until_t = os.clock() + duration
    for i = 1, #members do
        local m = members[i]
        if m.self or m.dist <= reach then
            buff_until[m.name .. ':' .. status] = until_t
        end
    end
end

local function apply_group(env, player, members, reach, group)
    local spell = best_spell(player, group.names, nil)
    if not spell then return false end
    local duration = group.duration or spell.duration or 480
    if (spell.range or 0) > 0 then
        local someone = false
        for i = 1, #members do
            local m = members[i]
            if (m.self or m.dist <= reach) and needs_buff(player, m, group) then
                someone = true
                break
            end
        end
        if someone and cast(env, spell, '<me>') then
            mark_near(members, group.status, duration, reach)
            return true
        end
        return false
    end
    for i = 1, #members do
        local m = members[i]
        if m.self and needs_buff(player, m, group) and cast(env, spell, '<me>') then
            buff_until[m.name .. ':' .. group.status] = os.clock() + duration
            return true
        end
    end
    return false
end

local function try_bars(env, player, members, reach)
    local element = env.enemy_element
    if element and BARS[element] then
        if apply_group(env, player, members, reach, BARS[element]) then return true end
    end
    if env.settings.goal == 'grind' then
        for i = 1, #STATUS_BARS do
            if apply_group(env, player, members, reach, STATUS_BARS[i]) then return true end
        end
    end
    return false
end

local function try_cure(env, player, heal, members)
    local threshold = heal.cure_hpp or 75
    local reach = heal.cast_range or 20
    local hurt, hurt_near, closest = {}, 0, nil
    for i = 1, #members do
        local m = members[i]
        if m.hpp < threshold then
            hurt[#hurt + 1] = m
            if m.dist <= 10 then hurt_near = hurt_near + 1 end
            if not closest or m.dist < closest.dist then closest = m end
        end
    end
    if #hurt == 0 then return false end

    local in_range
    for i = 1, #hurt do
        if hurt[i].dist <= reach and (not in_range or hurt[i].hpp < in_range.hpp) then
            in_range = hurt[i]
        end
    end

    if hurt_near >= 2 then
        local spell = best_spell(player, curaga_names(in_range and in_range.hpp or hurt[1].hpp), nil)
        if spell and cast(env, spell, '<me>') then return true end
    end
    if env.main_name and in_range then
        local want = env.main_name:lower()
        for i = 1, #hurt do
            local m = hurt[i]
            if m.name:lower() == want and m.dist <= reach then
                if m.hpp <= in_range.hpp + 25 or in_range.hpp > 40 then in_range = m end
                break
            end
        end
    end
    if in_range then
        local spell = best_spell(player, cure_names(in_range.hpp), nil)
        if spell and cast(env, spell, in_range.name) then return true end
    end
    if closest and closest.mob and closest.dist > reach then
        M.line = 'Moving to ' .. closest.name
        env.steer(env.me, closest.mob, closest.dist)
        return true
    end
    return false
end

local function try_enhance(env, player, members, reach)
    for g = 1, #ENHANCE do
        local group = ENHANCE[g]
        local spell = best_spell(player, group.names, nil)
        if spell then
            if group.aoe then
                local me
                for i = 1, #members do if members[i].self then me = members[i] break end end
                if me and needs_buff(player, me, group) then
                    if cast(env, spell, '<me>') then
                        mark_party(members, group.status, group.duration)
                        return true
                    end
                end
            else
                for i = 1, #members do
                    local m = members[i]
                    local ok_range = m.self or m.dist <= reach
                    if ok_range and (not group.self_only or m.self) and needs_buff(player, m, group) then
                        local who = m.self and '<me>' or m.name
                        if cast(env, spell, who) then
                            buff_until[m.name .. ':' .. group.status] = os.clock() + group.duration
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function try_enfeeble(env, player, target)
    debuff_until[target.id] = debuff_until[target.id] or {}
    local book = debuff_until[target.id]
    local now = os.clock()
    for i = 1, #ENFEEBLE do
        local group = ENFEEBLE[i]
        if not book[group.key] or now > book[group.key] then
            local spell = best_spell(player, group.names, nil)
            if spell and cast(env, spell, '<t>') then
                book[group.key] = now + (spell.duration or 90)
                return true
            end
            if spell then return true end
        end
    end
    return false
end

local function heavy_name(name)
    if name:find('VI', 1, true) then return true end
    if name:find('ja', 1, true) then return true end
    if name:find('ga', 1, true) then return true end
    return false
end

local function nuke_names(element, heavy)
    local names = NUKES[element] or NUKES.Lightning
    if heavy then return names end
    local out = {}
    for i = 1, #names do
        if not heavy_name(names[i]) then out[#out + 1] = names[i] end
    end
    if #out == 0 then return names end
    return out
end

function M.nuke(env, player, element, reserve, heavy)
    if element == 'Burst' or element == nil or element == '' then
        element = env.burst_element or 'Lightning'
    end
    if element == 'Thunder' then element = 'Lightning' end
    local spell = best_spell(player, nuke_names(element, heavy), reserve)
    if spell and cast(env, spell, '<t>') then return true end
    return false
end

function M.burst(env, player, elements, reserve)
    for i = 1, #elements do
        local spell = best_spell(player, nuke_names(elements[i], true), reserve)
        if spell then return cast(env, spell, '<t>') end
    end
    return false
end

function M.dispel(env, player, target)
    debuff_until[target.id] = debuff_until[target.id] or {}
    local book = debuff_until[target.id]
    if book.dispel and os.clock() < book.dispel then return false end
    local spell = best_spell(player, { 'Dispel', 'Dispelga' }, nil)
    if not spell then return false end
    if cast(env, spell, '<t>') then
        book.dispel = os.clock() + 25
        return true
    end
    return false
end

function M.enfeeble(env, player, target)
    return try_enfeeble(env, player, target)
end

local function try_nuke(env, player, heal)
    local heavy = heal.element == 'Burst' and env.burst_element ~= nil
    return M.nuke(env, player, heal.element, heal.mp_reserve or 40, heavy)
end

function M.summary(player)
    if not player then return '' end
    local now = os.clock()
    if now - summary_at < 2 then return summary_text end
    local picks = {}
    local function add(label, names)
        local spell = best_spell(player, names, nil)
        if spell then picks[#picks + 1] = label .. ' ' .. spell.en end
    end
    add('Cure', { 'Cure VI', 'Cure V', 'Cure IV', 'Cure III', 'Cure II', 'Cure' })
    add('Haste', ENHANCE[1].names)
    add('Dia', ENFEEBLE[1].names)
    local element = M.element or 'Lightning'
    if element == 'Thunder' then element = 'Lightning' end
    local label = element
    if element == 'Burst' then element = 'Lightning' end
    add(label, NUKES[element] or NUKES.Lightning)
    summary_text = table.concat(picks, '  ')
    summary_at = now
    return summary_text
end

function M.think(env)
    local player = env.player
    local heal = env.settings.heal or {}
    M.element = heal.element
    if silenced(player) then
        M.line = 'Silenced'
        env.set_run(false)
        return false
    end
    if not env.can_act() then
        env.set_run(false)
        return true
    end

    local members = party_members()
    local reach = heal.cast_range or 20

    if try_mp(env, player, members, heal) then return true end
    if heal.cure ~= false and try_cure(env, player, heal, members) then return true end
    if heal.enhance ~= false and try_bars(env, player, members, reach) then return true end
    if heal.enhance ~= false and try_enhance(env, player, members, reach) then return true end

    local fighting = player.status == 1
    if not fighting then
        for i = 1, #members do
            local mob = members[i].mob
            if mob and mob.status == 1 then fighting = true break end
        end
    end
    local target = env.target
    local want_enemy = heal.enfeeble ~= false or heal.nuke
    if fighting and want_enemy and target and target.distance then
        local dist = math.sqrt(target.distance)
        if dist > reach then
            M.line = 'Closing to ' .. (target.name or 'target')
            if not env.steer(env.me, target, dist) then env.set_run(false) end
            return true
        end
        env.set_run(false)
        if env.ensure and not env.ensure(target) then
            M.line = 'Targeting ' .. (target.name or 'enemy')
            return true
        end
        if heal.enfeeble ~= false and try_enfeeble(env, player, target) then return true end
        local someone_hurt = false
        if heal.cure ~= false then
            for i = 1, #members do
                if members[i].hpp < (heal.cure_hpp or 75) then someone_hurt = true break end
            end
        end
        if heal.nuke and not someone_hurt and try_nuke(env, player, heal) then return true end
    end

    env.set_run(false)
    if M.line == '' then M.line = 'Watching party' end
    return false
end

return M
