--[[
    Tank, damage dealer, support, and mage behavior.
    Healer cures stay in healer.lua. This file adds hate, runes,
    skillchain weaponskills, songs, rolls, bubbles, and magic bursts.
]]

local res = require('resources')
local healer = require('healer')
local joblevels = require('levels')

local M = { line = '' }

local used_at = {}
local spell_by_en
local ws_by_en
local detected, detected_at
local chain_name, chain_at

local ELEMENT_NAME = {
    [0] = 'Fire', [1] = 'Ice', [2] = 'Wind', [3] = 'Earth',
    [4] = 'Lightning', [5] = 'Water', [6] = 'Light', [7] = 'Dark',
}

local RUNE = {
    Fire = { name = 'Ignis', status = 523 },
    Ice = { name = 'Gelus', status = 524 },
    Wind = { name = 'Flabra', status = 525 },
    Earth = { name = 'Tellus', status = 526 },
    Lightning = { name = 'Sulpor', status = 527 },
    Water = { name = 'Unda', status = 528 },
    Light = { name = 'Lux', status = 529 },
    Dark = { name = 'Tenebrae', status = 530 },
}

-- Resonance already on the monster, then a property on the closing weaponskill.
local CHART = {
    Transfixion = { Compression = 'Compression', Scission = 'Distortion', Reverberation = 'Reverberation' },
    Compression = { Transfixion = 'Transfixion', Detonation = 'Detonation' },
    Liquefaction = { Impaction = 'Fusion', Scission = 'Scission' },
    Scission = { Liquefaction = 'Liquefaction', Detonation = 'Detonation', Reverberation = 'Gravitation' },
    Reverberation = { Induration = 'Induration', Impaction = 'Impaction' },
    Detonation = { Compression = 'Gravitation', Scission = 'Scission' },
    Induration = { Compression = 'Compression', Reverberation = 'Fragmentation', Impaction = 'Impaction' },
    Impaction = { Liquefaction = 'Liquefaction', Detonation = 'Detonation' },
    Gravitation = { Distortion = 'Darkness', Fragmentation = 'Fragmentation' },
    Distortion = { Gravitation = 'Darkness', Fusion = 'Fusion' },
    Fusion = { Gravitation = 'Gravitation', Fragmentation = 'Light' },
    Fragmentation = { Distortion = 'Distortion', Fusion = 'Light' },
    Light = { Light = 'Light' },
    Darkness = { Darkness = 'Darkness' },
}

local RANK = {
    Light = 100, Darkness = 100,
    Fusion = 80, Fragmentation = 80, Gravitation = 80, Distortion = 80,
    Liquefaction = 20, Impaction = 20, Detonation = 20, Scission = 20,
    Reverberation = 20, Induration = 20, Compression = 20, Transfixion = 20,
}

local CHAIN_NAMES = {
    'Fragmentation', 'Gravitation', 'Reverberation', 'Liquefaction', 'Compression',
    'Transfixion', 'Induration', 'Detonation', 'Distortion', 'Scission',
    'Darkness', 'Impaction', 'Fusion', 'Light',
}

-- Strongest magic-burst element first. Light and dark are included.
local BURST = {
    Light = { 'Lightning', 'Fire', 'Wind', 'Light' },
    Darkness = { 'Dark', 'Earth', 'Water', 'Ice' },
    Fusion = { 'Fire', 'Light' },
    Fragmentation = { 'Lightning', 'Wind' },
    Gravitation = { 'Dark', 'Earth' },
    Distortion = { 'Ice', 'Water' },
    Liquefaction = { 'Fire' },
    Impaction = { 'Lightning' },
    Detonation = { 'Wind' },
    Scission = { 'Earth' },
    Reverberation = { 'Water' },
    Induration = { 'Ice' },
    Compression = { 'Dark' },
    Transfixion = { 'Light' },
}

local function window_for(name)
    if name == 'Light' or name == 'Darkness' then return 10 end
    if (RANK[name] or 0) >= 80 then return 8 end
    return 6
end

local function has_buff(player, id)
    local buffs = player.buffs or {}
    for i = 1, #buffs do
        if buffs[i] == id then return true end
    end
    return false
end

local function buff_count(player, id)
    local n = 0
    local buffs = player.buffs or {}
    for i = 1, #buffs do
        if buffs[i] == id then n = n + 1 end
    end
    return n
end

local function job_is(player, job)
    return player.main_job == job or player.sub_job == job
end

local function tp_now(player)
    return (player.vitals and player.vitals.tp) or 0
end

local function find_ability(name)
    local want = name:lower()
    for _, ability in pairs(res.job_abilities) do
        if type(ability) == 'table' and type(ability.en) == 'string' and ability.en:lower() == want then
            return ability
        end
    end
    return nil
end

local function ability_ready(name)
    local now = os.clock()
    local ability = find_ability(name)
    if not ability then return false end
    if not ability.recast_id or ability.recast_id == 0 then
        return not used_at[name] or (now - used_at[name]) > 3600
    end
    if used_at[name] and (now - used_at[name]) < 8 then return false end
    local recasts = windower.ffxi.get_ability_recasts()
    local timer = recasts and recasts[ability.recast_id]
    return timer == nil or timer <= 0
end

local function use_ja(env, name, target)
    if not joblevels.allows(env.player, name) then return false end
    if not ability_ready(name) then return false end
    local cmd = string.format('/ja "%s" %s', name:gsub('"', ''), target or '<me>')
    if env.act(cmd, 2) then
        used_at[name] = os.clock()
        M.line = name
        return true
    end
    return false
end

local function lookup_spell(name)
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

local function knows_spell(player, spell)
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

local function cast_spell(env, name, target)
    local player = env.player
    local spell = lookup_spell(name)
    if not spell or not knows_spell(player, spell) or not spell_ready(spell) then return false end
    local mp = (player.vitals and player.vitals.mp) or 0
    if mp < (spell.mp_cost or 0) then return false end
    if has_buff(player, 6) then return false end
    local who = target or '<me>'
    local cmd = string.format('/ma "%s" %s', spell.en:gsub('"', ''), who)
    if env.act(cmd, (spell.cast_time or 2) + 1.8) then
        M.line = spell.en
        return true
    end
    return false
end

local last_song = {}

local function known_spell(player, name)
    local spell = lookup_spell(name)
    if not spell then return false end
    return knows_spell(player, spell)
end

local function any_known(player, names)
    for i = 1, #names do
        if known_spell(player, names[i]) then return true end
    end
    return false
end

local function locked_on(env)
    if not env.target then return false end
    if env.ensure then return env.ensure(env.target) end
    local current = windower.ffxi.get_mob_by_target('t')
    return current and current.id == env.target.id
end

-- rotate_key skips the song just sung so a second march is a different one.
local function cast_known(env, names, target, rotate_key)
    local player = env.player
    local start = 1
    if rotate_key and last_song[rotate_key] then
        for i = 1, #names do
            if names[i] == last_song[rotate_key] then
                start = i + 1
                break
            end
        end
    end
    for n = 0, #names - 1 do
        local name = names[((start - 1 + n) % #names) + 1]
        local spell = lookup_spell(name)
        if spell and knows_spell(player, spell) then
            if not spell_ready(spell) then
                if not rotate_key then return false end
            elseif cast_spell(env, name, target) then
                if rotate_key then last_song[rotate_key] = name end
                return true
            else
                return false
            end
        end
    end
    return false
end

function M.chain_name()
    if not chain_name or not chain_at then return nil end
    if os.clock() > chain_at + window_for(chain_name) then return nil end
    return chain_name
end

function M.burst_element()
    local name = M.chain_name()
    local list = name and BURST[name]
    return list and list[1] or nil
end

function M.enemy_element(settings)
    local pick = settings and settings.enemy_element or 'Auto'
    if pick and pick ~= 'Auto' and pick ~= '' then return pick end
    if detected and os.clock() - detected_at < 45 then return detected end
    return nil
end

function M.detail()
    local parts = {}
    local chain = M.chain_name()
    if chain then
        local left = math.max(0, math.floor(chain_at + window_for(chain) - os.clock()))
        parts[#parts + 1] = 'Chain ' .. chain .. ' ' .. tostring(left) .. 's'
    end
    if detected and os.clock() - detected_at < 45 then
        parts[#parts + 1] = 'Enemy ' .. detected
    end
    return table.concat(parts, '   ')
end

local function ws_props(name)
    if not ws_by_en then
        ws_by_en = {}
        for _, ws in pairs(res.weapon_skills) do
            if type(ws) == 'table' and type(ws.en) == 'string' then
                ws_by_en[ws.en:lower()] = ws
            end
        end
    end
    local ws = ws_by_en[name:lower()]
    local props = {}
    if not ws then return props end
    if ws.skillchain_a and ws.skillchain_a ~= '' then props[#props + 1] = ws.skillchain_a end
    if ws.skillchain_b and ws.skillchain_b ~= '' then props[#props + 1] = ws.skillchain_b end
    if ws.skillchain_c and ws.skillchain_c ~= '' then props[#props + 1] = ws.skillchain_c end
    return props
end

local function close_with(resonance, prop)
    local row = CHART[resonance]
    return row and row[prop] or nil
end

function M.pick_ws(prof, player, target)
    if not prof or not prof.ws then return nil end
    local tp = tp_now(player)
    local hpp = (target and target.hpp) or 0
    local ready = {}
    for i = 1, #prof.ws do
        local ws = prof.ws[i]
        if tp >= (ws.tp or 1000) and hpp >= (ws.min_hpp or 0) then
            ready[#ready + 1] = ws
        end
    end
    if #ready == 0 then return nil end

    local resonance = M.chain_name()
    if resonance then
        local best, best_rank, best_result
        for i = 1, #ready do
            local props = ws_props(ready[i].name)
            for p = 1, #props do
                local result = close_with(resonance, props[p])
                local rank = result and (RANK[result] or 0) or 0
                if rank > 0 and (not best or rank > best_rank) then
                    best, best_rank, best_result = ready[i], rank, result
                end
            end
        end
        if best then
            M.line = best.name .. ' -> ' .. best_result
            return best
        end
        M.line = 'Holding TP for ' .. resonance
        return nil
    end

    local best, best_rank, best_tp
    for i = 1, #ready do
        local props = ws_props(ready[i].name)
        local rank = 0
        for p = 1, #props do rank = math.max(rank, RANK[props[p]] or 1) end
        local need = ready[i].tp or 1000
        if not best or rank > best_rank or (rank == best_rank and need > best_tp) then
            best, best_rank, best_tp = ready[i], rank, need
        end
    end
    if best then M.line = best.name end
    return best
end

local function try_listed(env, list, dist, tp)
    local player = env.player
    for i = 1, #list do
        local entry = list[i]
        if job_is(player, entry.job) then
            local far = entry.enemy and dist > (entry.reach or 8)
            local early = entry.min_tp and tp < entry.min_tp
            local up = entry.status and has_buff(player, entry.status)
            if not far and not early and not up then
                local who = entry.enemy and '<t>' or '<me>'
                if use_ja(env, entry.name, who) then return true end
            end
        end
    end
    return false
end

local DD_BUFFS = {
    { name = 'Berserk', job = 'WAR', status = 56 },
    { name = 'Aggressor', job = 'WAR', status = 58 },
    { name = 'Warcry', job = 'WAR', status = 68 },
    { name = 'Boost', job = 'MNK' },
    { name = 'Focus', job = 'MNK', status = 59 },
    { name = 'Impetus', job = 'MNK', status = 461 },
    { name = 'Dodge', job = 'MNK', status = 60 },
    { name = 'Sneak Attack', job = 'THF', status = 65, min_tp = 800 },
    { name = 'Trick Attack', job = 'THF', status = 87, min_tp = 800 },
    { name = "Assassin's Charge", job = 'THF', status = 342 },
    { name = 'Last Resort', job = 'DRK', status = 64 },
    { name = 'Hasso', job = 'SAM', status = 353 },
    { name = 'Sengikori', job = 'SAM', status = 440, min_tp = 1000 },
    { name = 'Velocity Shot', job = 'RNG', status = 371 },
    { name = 'Sharpshot', job = 'RNG', status = 72 },
    { name = 'Double Shot', job = 'RNG', status = 433 },
    { name = 'Haste Samba', job = 'DNC', status = 370, min_tp = 350 },
    { name = 'Building Flourish', job = 'DNC', status = 375 },
    { name = 'Killer Instinct', job = 'BST', status = 349 },
    { name = 'Composure', job = 'RDM', status = 419 },
    { name = 'Saboteur', job = 'RDM', status = 454 },
}

local DD_PRE_WS = {
    { name = 'Sekkanoki', job = 'SAM', min_tp = 1000 },
    { name = 'Konzen-ittai', job = 'SAM', enemy = true, min_tp = 1000 },
    { name = 'Barrage', job = 'RNG', status = 73, min_tp = 1000 },
    { name = 'Climactic Flourish', job = 'DNC', status = 443, min_tp = 1000 },
}

local DD_HITS = {
    { name = 'Jump', job = 'DRG', enemy = true },
    { name = 'High Jump', job = 'DRG', enemy = true },
    { name = 'Spirit Jump', job = 'DRG', enemy = true },
    { name = 'Soul Jump', job = 'DRG', enemy = true },
    { name = 'Box Step', job = 'DNC', enemy = true, min_tp = 100 },
}

function M.dd(env)
    if not env.can_act() then return false end
    local player = env.player
    local target = env.target
    local dist = 999
    if target and target.distance then dist = math.sqrt(target.distance) end
    local tp = tp_now(player)
    if dist <= 8 and tp >= 1000 and M.chain_name() then
        return false
    end
    if dist <= 8 and tp >= 1000 and try_listed(env, DD_PRE_WS, dist, tp) then return true end
    if try_listed(env, DD_BUFFS, dist, tp) then return true end
    if dist <= 8 and try_listed(env, DD_HITS, dist, tp) then return true end
    return false
end

local TANK_SELF = {
    { name = 'Defender', job = 'WAR', status = 57 },
    { name = 'Warcry', job = 'WAR', status = 68 },
    { name = 'Sentinel', job = 'PLD', status = 62 },
    { name = 'Rampart', job = 'PLD', status = 93 },
    { name = 'Palisade', job = 'PLD', status = 478 },
    { name = 'Fealty', job = 'PLD', status = 344 },
    { name = 'Majesty', job = 'PLD', status = 621 },
    { name = 'Yonin', job = 'NIN', status = 420 },
    { name = 'Seigan', job = 'SAM', status = 354 },
    { name = 'Third Eye', job = 'SAM', status = 67 },
    { name = 'Swordplay', job = 'RUN', status = 532 },
    { name = 'Battuta', job = 'RUN', status = 570 },
    { name = 'Pflug', job = 'RUN', status = 533 },
    { name = 'One for All', job = 'RUN', status = 152 },
}

local TANK_HATE = {
    { name = 'Provoke', job = 'WAR', enemy = true, reach = 18 },
    { name = 'Shield Bash', job = 'PLD', enemy = true, reach = 5 },
    { name = 'Weapon Bash', job = 'DRK', enemy = true, reach = 5 },
    { name = 'Gambit', job = 'RUN', enemy = true, reach = 15 },
    { name = 'Rayke', job = 'RUN', enemy = true, reach = 15 },
}

local function rune_count(player, status)
    return buff_count(player, status)
end

local function maintain_runes(env)
    local player = env.player
    if not job_is(player, 'RUN') then return false end
    local element = M.enemy_element(env.settings)
    local rune = element and RUNE[element]
    if rune and rune_count(player, rune.status) < 3 then
        if use_ja(env, rune.name, '<me>') then
            M.line = rune.name .. ' vs ' .. element
            return true
        end
    end
    if not has_buff(player, 535) and not has_buff(player, 531) then
        if use_ja(env, 'Valiance', '<me>') then return true end
        if use_ja(env, 'Vallation', '<me>') then return true end
    end
    return false
end

function M.tank(env)
    if not env.can_act() then return false end
    local player = env.player
    local target = env.target
    local dist = 999
    if target and target.distance then dist = math.sqrt(target.distance) end
    if maintain_runes(env) then return true end
    if not has_buff(player, 403) and cast_spell(env, 'Reprisal', '<me>') then return true end
    if try_listed(env, TANK_SELF, dist, tp_now(player)) then return true end
    if dist > 20 then return false end
    if not locked_on(env) then
        M.line = 'Targeting ' .. ((env.target and env.target.name) or 'enemy')
        return true
    end
    if cast_spell(env, 'Flash', '<t>') then return true end
    if try_listed(env, TANK_HATE, dist, tp_now(player)) then return true end
    return false
end

local SONGS_DAMAGE = {
    { names = { 'Honor March', 'Victory March', 'Advancing March' }, status = 214, need = 2 },
    { names = { 'Valor Minuet V', 'Valor Minuet IV', 'Valor Minuet III', 'Valor Minuet II' }, status = 198, need = 1 },
    { names = { 'Blade Madrigal', 'Sword Madrigal' }, status = 199, need = 1 },
    { names = { "Mage's Ballad III", "Mage's Ballad II", "Mage's Ballad" }, status = 196, need = 1 },
}

local SONGS_GRIND = {
    { names = { 'Honor March', 'Victory March', 'Advancing March' }, status = 214, need = 1 },
    { names = { "Mage's Ballad III", "Mage's Ballad II", "Mage's Ballad" }, status = 196, need = 1 },
    { names = { "Army's Paeon VI", "Army's Paeon V", "Army's Paeon IV", "Army's Paeon III" }, status = 195, need = 1 },
    { names = { 'Valor Minuet V', 'Valor Minuet IV', 'Valor Minuet III', 'Valor Minuet II' }, status = 198, need = 1 },
    { names = { 'Blade Madrigal', 'Sword Madrigal' }, status = 199, need = 1 },
}

local function sing(env, slots, groups)
    local player = env.player
    if has_buff(player, 6) then return false end
    local active = 0
    for g = 1, #groups do
        if active >= slots then return false end
        local group = groups[g]
        local room = math.min(group.need, slots - active)
        local have = buff_count(player, group.status)
        if have >= room then
            active = active + room
        elseif any_known(player, group.names) then
            if not has_buff(player, 347) and use_ja(env, 'Nightingale', '<me>') then return true end
            if not has_buff(player, 348) and use_ja(env, 'Troubadour', '<me>') then return true end
            if active == 0 and have == 0 and use_ja(env, 'Marcato', '<me>') then return true end
            local key = (group.need > 1) and tostring(group.status) or nil
            if cast_known(env, group.names, '<me>', key) then return true end
        end
    end
    return false
end

local ROLLS_DAMAGE = {
    { name = 'Chaos Roll', status = 317 },
    { name = "Fighter's Roll", status = 310 },
}

local ROLLS_GRIND = {
    { name = 'Samurai Roll', status = 321 },
    { name = "Evoker's Roll", status = 324 },
}

local function roll(env, list)
    local player = env.player
    for i = 1, #list do
        local entry = list[i]
        if not has_buff(player, entry.status) then
            if not has_buff(player, 601) and use_ja(env, 'Crooked Cards', '<me>') then return true end
            if use_ja(env, entry.name, '<me>') then return true end
        end
    end
    return false
end

local GEO_INDI_DAMAGE = {
    { name = 'Indi-Fury', status = 549 },
    { name = 'Indi-Precision', status = 553 },
    { name = 'Indi-Haste', status = 580 },
    { name = 'Indi-Barrier', status = 550 },
}

local GEO_INDI_GRIND = {
    { name = 'Indi-Refresh', status = 541 },
    { name = 'Indi-Regen', status = 539 },
    { name = 'Indi-Haste', status = 580 },
    { name = 'Indi-Barrier', status = 550 },
    { name = 'Indi-Fend', status = 552 },
}

local geo_until = {}

local function geo_bubble(env, names, target)
    local id = (target == '<t>' and env.target and env.target.id) or target
    local key = names[1] .. ':' .. tostring(id)
    if geo_until[key] and os.clock() < geo_until[key] then return false end
    if cast_known(env, names, target, nil) then
        geo_until[key] = os.clock() + 180
        return true
    end
    return false
end

local function place_indi(env, list)
    local player = env.player
    local names = {}
    for i = 1, #list do
        if has_buff(player, list[i].status) then return false end
        names[#names + 1] = list[i].name
    end
    if not any_known(player, names) then return false end
    if not has_buff(player, 569) and use_ja(env, 'Blaze of Glory', '<me>') then return true end
    return cast_known(env, names, '<me>', nil)
end

local function do_geo(env)
    local grind = env.settings.goal == 'grind'
    local indi = grind and GEO_INDI_GRIND or GEO_INDI_DAMAGE
    if place_indi(env, indi) then return true end
    local target = env.target
    if not grind and target then
        local reach = (env.settings.heal and env.settings.heal.cast_range) or 20
        local spaced = tonumber(env.settings.combat and env.settings.combat.distance) or 0
        if spaced > reach then reach = spaced + 2 end
        local dist = math.sqrt(target.distance or 0)
        if dist > reach then
            M.line = 'Closing to ' .. (target.name or 'target')
            if not env.steer(env.me, target, dist) then env.set_run(false) end
            return true
        end
        env.set_run(false)
        if not locked_on(env) then
            M.line = 'Targeting ' .. (target.name or 'enemy')
            return true
        end
        if geo_bubble(env, { 'Geo-Frailty', 'Geo-Slow' }, '<t>') then return true end
    else
        if geo_bubble(env, { 'Geo-Regen', 'Geo-Refresh', 'Geo-Haste' }, '<me>') then return true end
    end
    return false
end

local song_at = {}

local function song_due(key)
    local at = song_at[key]
    return not at or os.clock() > at + 100
end

local function configured_names(book)
    if type(book) ~= 'table' then return false end
    local function named(list)
        if type(list) ~= 'table' then return false end
        for i = 1, #list do
            local item = list[i]
            if type(item) == 'string' and item ~= '' then return true end
            if type(item) == 'table' and type(item.name) == 'string' and item.name ~= '' then return true end
        end
        return false
    end
    return named(book.base) or named(book.dummy) or named(book.pia)
end

local function song_openers(env, player, marcato)
    if not has_buff(player, 347) and use_ja(env, 'Nightingale', '<me>') then return true end
    if not has_buff(player, 348) and use_ja(env, 'Troubadour', '<me>') then return true end
    if marcato and not has_buff(player, 231) and use_ja(env, 'Marcato', '<me>') then return true end
    return false
end

function M.perform_songs(env)
    local book = env.settings.songs
    local player = env.player
    if not player or not job_is(player, 'BRD') or not configured_names(book) then return false end
    if not env.can_act() then
        env.set_run(false)
        return true
    end
    if has_buff(player, 6) then return false end

    local function sing(name, target, key)
        if not song_due(key) then return false end
        if cast_spell(env, name, target) then
            song_at[key] = os.clock()
            return true
        end
        return false
    end

    if book.dummy_first then
        for i = 1, #(book.dummy or {}) do
            local name = book.dummy[i]
            if type(name) == 'string' and name ~= '' and song_due('d:' .. name:lower()) then
                if song_openers(env, player, false) then return true end
                if sing(name, '<me>', 'd:' .. name:lower()) then return true end
            end
        end
    end

    local limit = tonumber(book.count) or 2
    local used = 0
    for i = 1, #(book.base or {}) do
        if used >= limit then break end
        local name = book.base[i]
        if type(name) == 'string' and name ~= '' then
            used = used + 1
            if song_due('b:' .. name:lower()) then
                if song_openers(env, player, used == 1) then return true end
                if sing(name, '<me>', 'b:' .. name:lower()) then return true end
            end
        end
    end

    for i = 1, #(book.pia or {}) do
        local row = book.pia[i]
        if type(row) == 'table' and type(row.name) == 'string' and row.name ~= '' then
            local who = row.target or 'me'
            local key = 'p:' .. row.name:lower() .. ':' .. who:lower()
            if song_due(key) then
                local mine = who:lower() == 'me' or (player.name and who:lower() == player.name:lower())
                if mine and not has_buff(player, 455) and use_ja(env, 'Tenuto', '<me>') then return true end
                if not has_buff(player, 409) and use_ja(env, 'Pianissimo', '<me>') then return true end
                local tgt = mine and '<me>' or who
                if sing(row.name, tgt, key) then return true end
            end
        end
    end
    return false
end

function M.support(env)
    if not env.can_act() then
        env.set_run(false)
        return true
    end
    local player = env.player
    local grind = env.settings.goal == 'grind'
    local slots = tonumber(env.settings.songs) or 2
    if job_is(player, 'BRD') then
        if configured_names(env.settings.songs) then
            if M.perform_songs(env) then return true end
        else
            local songs = grind and SONGS_GRIND or SONGS_DAMAGE
            if player.main_job ~= 'BRD' then slots = 1 end
            if sing(env, slots, songs) then return true end
        end
    end
    if job_is(player, 'COR') then
        if roll(env, grind and ROLLS_GRIND or ROLLS_DAMAGE) then return true end
    end
    if job_is(player, 'GEO') then
        if do_geo(env) then return true end
    end
    if not job_is(player, 'BRD') and not job_is(player, 'COR') and not job_is(player, 'GEO') then
        M.line = 'Support wants BRD, COR, or GEO'
    end
    env.set_run(false)
    return false
end

local function caster_prep(env)
    local player = env.player
    if job_is(player, 'RDM') and not has_buff(player, 419) and use_ja(env, 'Composure', '<me>') then
        return true
    end
    if job_is(player, 'RDM') and not has_buff(player, 454) and use_ja(env, 'Saboteur', '<me>') then
        return true
    end
    if job_is(player, 'BLM') and not has_buff(player, 599) and use_ja(env, 'Consume Mana', '<me>') then
        return true
    end
    return false
end

function M.mage(env)
    local player = env.player
    local heal = env.settings.heal or {}
    if not env.can_act() then
        env.set_run(false)
        return true
    end
    if caster_prep(env) then return true end
    local target = env.target
    if not target or not target.distance then
        M.line = 'No enemy'
        env.set_run(false)
        return false
    end
    local reach = heal.cast_range or 20
    local spaced = tonumber(env.settings.combat and env.settings.combat.distance) or 0
    if spaced > reach then reach = spaced + 2 end
    local dist = math.sqrt(target.distance)
    if dist > reach then
        M.line = 'Closing to ' .. (target.name or 'target')
        if not env.steer(env.me, target, dist) then env.set_run(false) end
        return true
    end
    env.set_run(false)
    if not locked_on(env) then
        M.line = 'Targeting ' .. (target.name or 'enemy')
        return true
    end
    local chain = M.chain_name()
    local reserve = heal.mp_reserve or 40
    if heal.nuke ~= false and chain and BURST[chain] then
        local elements = BURST[chain]
        if heal.element and heal.element ~= 'Burst' then
            local pinned = false
            for i = 1, #elements do
                if elements[i] == heal.element then pinned = true break end
            end
            if pinned then elements = { heal.element } end
        end
        if healer.burst(env, player, elements, reserve) then
            M.line = 'Burst ' .. chain
            return true
        end
    end
    if healer.dispel(env, player, target) then return true end
    if heal.enfeeble ~= false and healer.enfeeble(env, player, target) then return true end
    if heal.nuke ~= false and healer.nuke(env, player, heal.element, reserve, false) then return true end
    if M.line == '' then M.line = 'Mage watching' end
    return false
end

windower.register_event('action', function(act)
    if not act or act.category ~= 4 or not act.param then return end
    local target = windower.ffxi.get_mob_by_target('t')
    if not target or act.actor_id ~= target.id then return end
    local spell = res.spells[act.param]
    if spell and ELEMENT_NAME[spell.element] then
        detected = ELEMENT_NAME[spell.element]
        detected_at = os.clock()
    end
end)

windower.register_event('incoming text', function(original)
    local text = original or ''
    local lower = text:lower()
    if not lower:find('skillchain', 1, true) then return end
    for i = 1, #CHAIN_NAMES do
        if lower:find(CHAIN_NAMES[i]:lower(), 1, true) then
            chain_name = CHAIN_NAMES[i]
            chain_at = os.clock()
            return
        end
    end
end)

return M
