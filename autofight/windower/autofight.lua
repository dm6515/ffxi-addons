--[[
    autofight - per-job engage, weaponskills, and job abilities.

    Target modes
      priority     fight typed names, earlier names first, inside //af distance
      aggressive   fight the nearest monster inside //af distance
      manual       fight only the monster you already have targeted

    Closing in walks straight at the target. If you stop gaining ground it
    turns out around the obstacle, then straightens out once the gap closes.

    Starts off.   lua load autofight
                  //af help
]]

_addon.name = 'autofight'
_addon.author = 'local'
_addon.version = '1.5.1'
_addon.commands = {'autofight', 'af'}

require('logger')
local files = require('files')
local packets = require('packets')
local res = require('resources')
local texts = require('texts')
local healer = require('healer')
local roles = require('roles')
local levels = require('levels')
local scan = require('scan')
local gui = require('gui')

local JOBS = {
    WAR = true, MNK = true, WHM = true, BLM = true, RDM = true, THF = true,
    PLD = true, DRK = true, BST = true, BRD = true, RNG = true, SAM = true,
    NIN = true, DRG = true, SMN = true, BLU = true, COR = true, PUP = true,
    DNC = true, SCH = true, GEO = true, RUN = true,
}

local enabled = false
local running = false
local next_act = 0
local too_far_until = 0
local pending_id, pending_at = nil, 0
local blacklist = {}
local used_at = {}
local hud
local settings
local warned_names = false
local forced_id = nil
local trip = nil
local warp = nil
local lock_at = 0
local box_applied = nil

local path = {
    id = nil,
    bias = 0,
    side = 1,
    stuck_for = 0,
    since = 0,
    sample_x = nil,
    sample_y = nil,
    sample_dist = nil,
    sample_at = 0,
}

--------------------------------------------------------------------------------
-- Settings (data/settings.lua, one profile per main job)
--------------------------------------------------------------------------------

local function default_settings()
    return {
        mode = 'priority',
        distance = 20,
        height = 8,
        face = true,
        run = true,
        action_delay = 1.2,
        priority = {},
        jobs = {},
        role = 'dd',
        goal = 'damage',
        songs = 2,
        enemy_element = 'Auto',
        main = 'me',
        follow = 4,
        gui_x = 40,
        gui_y = 60,
        heal = {
            cure = true,
            cure_hpp = 75,
            enhance = true,
            enfeeble = true,
            nuke = false,
            element = 'Lightning',
            mp_reserve = 40,
            cast_range = 20,
        },
    }
end

local function blank_job()
    return { engage_range = 5, ws = {}, abilities = {} }
end

local function serialize(v)
    local kind = type(v)
    if kind == 'string' then return string.format('%q', v) end
    if kind == 'number' then return (v == v) and tostring(v) or '0' end
    if kind == 'boolean' then return v and 'true' or 'false' end
    if kind ~= 'table' then return 'nil' end

    local max, array = 0, true
    for k in pairs(v) do
        if type(k) ~= 'number' or k < 1 or k ~= math.floor(k) then
            array = false
            break
        end
        if k > max then max = k end
    end
    if array then
        local parts = {}
        for i = 1, max do parts[i] = serialize(v[i]) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    local parts = {}
    for k, val in pairs(v) do
        local key = (type(k) == 'string' and k:match('^[%a_][%w_]*$')) and k or ('[' .. serialize(k) .. ']')
        parts[#parts + 1] = key .. '=' .. serialize(val)
    end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
end

local function normalize()
    local base = default_settings()
    settings = settings or base
    if settings.mode ~= 'priority' and settings.mode ~= 'aggressive' and settings.mode ~= 'manual' then
        settings.mode = 'priority'
    end
    settings.distance = tonumber(settings.distance) or base.distance
    settings.height = tonumber(settings.height) or base.height
    settings.action_delay = tonumber(settings.action_delay) or base.action_delay
    if settings.face == nil then settings.face = true end
    if settings.run == nil then settings.run = true end
    settings.priority = settings.priority or {}
    settings.jobs = settings.jobs or {}
    for _, prof in pairs(settings.jobs) do
        if type(prof) == 'table' then
            prof.engage_range = tonumber(prof.engage_range) or 5
            prof.ws = prof.ws or {}
            prof.abilities = prof.abilities or {}
            for i = 1, #prof.abilities do
                local ja = prof.abilities[i]
                if type(ja) == 'table' then
                    ja.tp = tonumber(ja.tp) or 0
                    if type(ja.target) ~= 'string' or ja.target == '' then ja.target = '<me>' end
                end
            end
        end
    end
    if settings.role == 'melee' or settings.role == 'damage' then settings.role = 'dd' end
    if settings.role == 'buffer' then settings.role = 'support' end
    if settings.role == 'debuffer' or settings.role == 'nuker' then settings.role = 'mage' end
    local roles_ok = { tank = true, dd = true, healer = true, support = true, mage = true }
    if not roles_ok[settings.role] then settings.role = 'dd' end
    if settings.goal ~= 'grind' and settings.goal ~= 'damage' then settings.goal = 'damage' end
    if type(settings.songs) ~= 'table' or not settings.songs.base then
        local count = tonumber(settings.songs) or 2
        if count < 1 then count = 1 end
        if count > 4 then count = 4 end
        settings.songs = {
            count = count,
            dummy_first = false,
            base = { '', '', '', '' },
            dummy = { '', '', '' },
            pia = {
                { name = '', target = 'me' },
                { name = '', target = 'me' },
                { name = '', target = 'me' },
                { name = '', target = 'me' },
            },
        }
    else
        local book = settings.songs
        book.count = tonumber(book.count) or 2
        if book.count < 1 then book.count = 1 end
        if book.count > 4 then book.count = 4 end
        book.dummy_first = book.dummy_first and true or false
        book.base = book.base or {}
        book.dummy = book.dummy or {}
        book.pia = book.pia or {}
        for i = 1, 4 do
            if type(book.base[i]) ~= 'string' then book.base[i] = '' end
            local row = book.pia[i]
            if type(row) ~= 'table' then
                book.pia[i] = { name = '', target = 'me' }
            else
                row.name = type(row.name) == 'string' and row.name or ''
                if type(row.target) ~= 'string' or row.target == '' then row.target = 'me' end
            end
        end
        for i = 1, 3 do
            if type(book.dummy[i]) ~= 'string' then book.dummy[i] = '' end
        end
    end
    settings.combat = type(settings.combat) == 'table' and settings.combat or {}
    if settings.combat.face ~= 'toward' and settings.combat.face ~= 'away' and settings.combat.face ~= 'hold' then
        settings.combat.face = 'toward'
    end
    settings.combat.lock = settings.combat.lock and true or false
    settings.combat.distance = tonumber(settings.combat.distance) or 0
    if settings.combat.distance < 0 then settings.combat.distance = 0 end
    if settings.combat.distance > 30 then settings.combat.distance = 30 end
    local enemy_ok = {
        Auto = true, Fire = true, Ice = true, Wind = true, Earth = true,
        Lightning = true, Water = true, Light = true, Dark = true,
    }
    if not enemy_ok[settings.enemy_element or ''] then settings.enemy_element = 'Auto' end
    settings.gui_x = tonumber(settings.gui_x) or 40
    settings.gui_y = tonumber(settings.gui_y) or 60
    settings.heal = settings.heal or {}
    local h = settings.heal
    if h.cure == nil then h.cure = true end
    if h.enhance == nil then h.enhance = true end
    if h.enfeeble == nil then h.enfeeble = true end
    if h.nuke == nil then h.nuke = false end
    h.cure_hpp = tonumber(h.cure_hpp) or 75
    h.mp_reserve = tonumber(h.mp_reserve) or 40
    h.cast_range = tonumber(h.cast_range) or 20
    if h.element == 'Thunder' then h.element = 'Lightning' end
    local nuke_ok = {
        Burst = true, Fire = true, Ice = true, Wind = true, Earth = true,
        Lightning = true, Water = true, Light = true, Dark = true,
    }
    if not nuke_ok[h.element or ''] then h.element = 'Lightning' end
    if type(settings.main) ~= 'string' or settings.main == '' then settings.main = 'me' end
    settings.follow = tonumber(settings.follow) or 4
    settings.distance = tonumber(settings.distance) or 20
    if settings.distance < 0 then settings.distance = 0 end
    if settings.distance > 500 then settings.distance = 500 end
    settings.box = settings.box or {}
end

local function copy_heal(heal)
    local out = {}
    if type(heal) == 'table' then
        for k, v in pairs(heal) do out[k] = v end
    end
    return out
end

local function save_settings()
    normalize()
    local player = windower.ffxi.get_player()
    local f = files.new('data/settings.lua')
    if f:exists() then
        local chunk = loadstring(f:read())
        if chunk then
            local ok, data = pcall(chunk)
            if ok and type(data) == 'table' and type(data.box) == 'table' then
                settings.box = settings.box or {}
                for name, data in pairs(data.box) do
                    if not player or name ~= player.name then settings.box[name] = data end
                end
            end
        end
    end
    if player and player.name then
        local prof = player.main_job and settings.jobs[player.main_job]
        settings.box[player.name] = {
            role = settings.role,
            goal = settings.goal,
            songs = settings.songs,
            heal = copy_heal(settings.heal),
            combat = settings.combat,
            abilities = prof and prof.abilities or nil,
            ws = prof and prof.ws or nil,
        }
        box_applied = player.name
    end
    f:write('return ' .. serialize(settings) .. '\n')
end

local function load_settings()
    local f = files.new('data/settings.lua')
    if not f:exists() then
        settings = default_settings()
        save_settings()
        return
    end
    local chunk, err = loadstring(f:read())
    if not chunk then
        log('Could not read settings: ' .. tostring(err))
        settings = default_settings()
        return
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= 'table' then
        log('Could not read settings.')
        settings = default_settings()
        return
    end
    settings = data
    normalize()
end

local function job_profile(job)
    job = (job or ''):upper()
    if not settings.jobs[job] or type(settings.jobs[job]) ~= 'table' then
        settings.jobs[job] = blank_job()
    end
    local prof = settings.jobs[job]
    prof.ws = prof.ws or {}
    prof.abilities = prof.abilities or {}
    for i = 1, #prof.abilities do
        local ja = prof.abilities[i]
        if type(ja) == 'table' then
            ja.tp = tonumber(ja.tp) or 0
            if type(ja.target) ~= 'string' or ja.target == '' then ja.target = '<me>' end
        end
    end
    prof.engage_range = tonumber(prof.engage_range) or 5
    return prof
end

local function current_job()
    local player = windower.ffxi.get_player()
    return player and player.main_job or nil
end

--------------------------------------------------------------------------------
-- Small parsers
--------------------------------------------------------------------------------

local function trim(s)
    return (s and s:match('^%s*(.-)%s*$')) or ''
end

local function join_args(args, from)
    local parts = {}
    for i = from, #args do parts[#parts + 1] = args[i] end
    return trim(table.concat(parts, ' '))
end

local function find_ability(name)
    if not name or name == '' then return nil end
    local want = name:lower()
    for _, ability in pairs(res.job_abilities) do
        if type(ability) == 'table' and type(ability.en) == 'string' and ability.en:lower() == want then
            return ability
        end
    end
    return nil
end

local function default_ja_target(name)
    local ability = find_ability(name)
    if ability and type(ability.targets) == 'number' and (ability.targets % 2 == 1) then
        return 'me'
    end
    return 't'
end

local function ability_ready(name)
    local now = os.clock()
    local ability = find_ability(name)
    if not ability or not ability.recast_id or ability.recast_id == 0 then
        local wait = ability and 3600 or 20
        return not used_at[name] or (now - used_at[name]) > wait
    end
    if used_at[name] and (now - used_at[name]) < 3 then return false end
    local recasts = windower.ffxi.get_ability_recasts()
    local timer = recasts and recasts[ability.recast_id]
    return timer == nil or timer <= 0
end

local function party_ids()
    local ids = {}
    local party = windower.ffxi.get_party()
    if not party then return ids end
    local keys = {
        'p0','p1','p2','p3','p4','p5',
        'a10','a11','a12','a13','a14','a15',
        'a20','a21','a22','a23','a24','a25',
    }
    for i = 1, #keys do
        local member = party[keys[i]]
        if type(member) == 'table' and type(member.mob) == 'table' and member.mob.id then
            ids[member.mob.id] = true
        end
    end
    return ids
end

local function blacklisted(id)
    local exp = blacklist[id]
    if not exp then return false end
    if os.clock() > exp then
        blacklist[id] = nil
        return false
    end
    return true
end

local function claim_ok(mob, player, ids)
    local claim = mob.claim_id
    if not claim or claim == 0 then return true end
    if claim == player.id then return true end
    return ids[claim] == true
end

local function is_monster(mob, player)
    if type(mob) ~= 'table' or mob.id == nil or mob.id == player.id then return false end
    if mob.spawn_type ~= 16 or not mob.valid_target or mob.charmed then return false end
    if not mob.hpp or mob.hpp <= 0 then return false end
    if mob.status == 2 or mob.status == 3 then return false end
    if not mob.distance or not mob.name or mob.name == '' then return false end
    return true
end

local function name_rank(mob_name)
    local n = mob_name:lower()
    for i, pat in ipairs(settings.priority) do
        if n:find(pat:lower(), 1, true) then return i end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

local function set_run(on)
    if running == on then return end
    running = on
    windower.ffxi.run(on and true or false)
end

local function reset_path()
    path.id = nil
    path.bias = 0
    path.side = 1
    path.stuck_for = 0
    path.since = 0
    path.sample_x = nil
    path.sample_y = nil
    path.sample_dist = nil
    path.sample_at = 0
end

local function face_toward(me, target, bias_deg)
    if not me.x or not target.x then return end
    local rad = -math.atan2(target.y - me.y, target.x - me.x) + math.rad(bias_deg or 0)
    windower.ffxi.turn(rad)
end

-- Straight at the target, then a widening side-step when progress stalls.
-- Returns false when the monster should be skipped.
local function steer(me, target, dist)
    local now = os.clock()
    if path.id ~= target.id then
        reset_path()
        path.id = target.id
        path.since = now
        path.sample_x, path.sample_y = me.x, me.y
        path.sample_dist, path.sample_at = dist, now
    end

    if now - path.sample_at >= 1 then
        local moved = 0
        if path.sample_x then
            local dx, dy = me.x - path.sample_x, me.y - path.sample_y
            moved = math.sqrt(dx * dx + dy * dy)
        end
        local gained = (path.sample_dist or dist) - dist
        if gained >= 0.7 then
            path.stuck_for = 0
            path.bias = path.bias * 0.4
            if math.abs(path.bias) < 10 then path.bias = 0 end
        elseif moved < 0.5 or gained < 0.2 then
            path.stuck_for = path.stuck_for + 1
            if path.stuck_for % 4 == 0 then path.side = -path.side end
            path.bias = math.min(140, 40 + path.stuck_for * 25) * path.side
        end
        path.sample_x, path.sample_y = me.x, me.y
        path.sample_dist, path.sample_at = dist, now
    end

    if path.stuck_for >= 8 and (now - path.since) > 10 then
        return false
    end
    if settings.face then face_toward(me, target, path.bias) end
    if settings.run and settings.face then set_run(true) end
    return true
end

local function skip_target(mob)
    blacklist[mob.id] = os.clock() + 45
    reset_path()
    set_run(false)
    log(string.format("Can't reach %s; ignoring it for 45s.", mob.name or 'that monster'))
end

--------------------------------------------------------------------------------
-- Combat
--------------------------------------------------------------------------------

local function act(cmd, wait)
    if os.clock() < next_act then return false end
    windower.chat.input(cmd)
    next_act = os.clock() + (wait or settings.action_delay or 1.2)
    return true
end

local function select_target(mob)
    local player = windower.ffxi.get_player()
    if not player or not mob then return end
    local ok, err = pcall(function()
        packets.inject(packets.new('incoming', 0x058, {
            ['Player'] = player.id,
            ['Target'] = mob.id,
            ['Player Index'] = player.index,
        }))
    end)
    if not ok then log('Could not target: ' .. tostring(err)) end
end

local function ensure_selected(mob)
    local current = windower.ffxi.get_mob_by_target('t')
    if current and current.id == mob.id then
        pending_id = nil
        return true
    end
    local now = os.clock()
    if pending_id ~= mob.id or (now - pending_at) > 1 then
        select_target(mob)
        pending_id = mob.id
        pending_at = now
    end
    return false
end

local function better(candidate, best)
    if not best then return true end
    if settings.mode == 'priority' then
        if candidate.rank ~= best.rank then return candidate.rank < best.rank end
    end
    return candidate.dist < best.dist
end

local function choose_target(me, player)
    if forced_id then
        local locked = windower.ffxi.get_mob_by_id(forced_id)
        if locked and is_monster(locked, player) then return locked end
        forced_id = nil
    end
    local ids = party_ids()
    local mode = settings.mode
    local leash = tonumber(settings.distance) or 20
    if leash <= 0 then leash = 2000 end
    local max_z = settings.height or 8
    if leash >= 50 then max_z = math.max(max_z, 25) end

    if mode == 'manual' then
        local current = windower.ffxi.get_mob_by_target('t') or windower.ffxi.get_mob_by_target('bt')
        if current and is_monster(current, player) and claim_ok(current, player, ids) and not blacklisted(current.id) then
            local limit = leash
            if current.claim_id == player.id then limit = limit + 10 end
            if math.sqrt(current.distance) <= limit then return current end
        end
        return nil
    end

    if mode == 'priority' and #settings.priority == 0 then
        if not warned_names then
            warned_names = true
            log('Priority list is empty. Example: //af names Beetle, Sapling')
        end
        return nil
    end

    local best
    local mobs = windower.ffxi.get_mob_array()
    if not mobs then return nil end
    for _, mob in pairs(mobs) do
        if is_monster(mob, player) and claim_ok(mob, player, ids) and not blacklisted(mob.id) then
            local dz = math.abs((mob.z or 0) - (me.z or 0))
            local dist = math.sqrt(mob.distance)
            local limit = (mob.claim_id == player.id) and (leash + 10) or leash
            local rank = name_rank(mob.name)
            local allowed = dz <= max_z and dist <= limit
            if allowed and mode == 'priority' then allowed = rank ~= nil end
            if allowed then
                local candidate = { mob = mob, dist = dist, rank = rank or 9999 }
                if better(candidate, best) then best = candidate end
            end
        end
    end
    return best and best.mob or nil
end

local function try_abilities(prof, engaged)
    local player = windower.ffxi.get_player()
    local tp = player and player.vitals and player.vitals.tp or 0
    for i = 1, #prof.abilities do
        local entry = prof.abilities[i]
        local need = tonumber(entry.tp) or 0
        if need <= tp and (engaged or entry.target == '<me>') and levels.allows(player, entry.name) and ability_ready(entry.name) then
            local cmd = string.format('/ja "%s" %s', entry.name:gsub('"', ''), entry.target)
            if act(cmd, 2) then
                used_at[entry.name] = os.clock()
                return true
            end
        end
    end
    return false
end

local function pick_ws(prof, tp, hpp)
    local best, best_i
    for i = 1, #prof.ws do
        local ws = prof.ws[i]
        if tp >= (ws.tp or 1000) and hpp >= (ws.min_hpp or 0) then
            if not best or ws.tp > best.tp or (ws.tp == best.tp and i > best_i) then
                best, best_i = ws, i
            end
        end
    end
    return best
end

local function try_ws(prof, player, target)
    local tp = player.vitals and player.vitals.tp or 0
    local ws
    if settings.role == 'dd' or settings.role == 'tank' then
        local chained = roles.chain_name()
        ws = roles.pick_ws(prof, player, target)
        if chained and not ws then return false end
    end
    if not ws then ws = pick_ws(prof, tp, target.hpp or 0) end
    if not ws or not ws.name then return false end
    return act(string.format('/ws "%s" <t>', ws.name:gsub('"', '')), 4)
end

local function engage_range(prof)
    local range = prof.engage_range or 5
    if os.clock() < too_far_until then range = math.max(1.5, range - 1.5) end
    return range
end

local function face_away(me, target)
    if not me.x or not target.x then return end
    local rad = -math.atan2(target.y - me.y, target.x - me.x) + math.pi
    windower.ffxi.turn(rad)
end

local function try_lock(player)
    local combat = settings.combat or {}
    if not combat.lock or combat.face == 'away' then return end
    if player.target_locked then return end
    if os.clock() < lock_at then return end
    lock_at = os.clock() + 2
    windower.chat.input('/lockon')
end

-- true while the character is still moving into the chosen spacing.
local function hold_position(me, target, player, prof)
    if not target or not target.distance then return false end
    local combat = settings.combat or {}
    local dist = math.sqrt(target.distance)
    local spaced = tonumber(combat.distance) or 0
    local want = spaced > 0 and spaced or engage_range(prof or {})
    local band = spaced > 0 and 1.5 or 0.4
    if dist > want + band then
        if not steer(me, target, dist) then
            if spaced <= 0 then skip_target(target) else set_run(false) end
        end
        return true
    end
    if spaced > 0 and dist + band < want then
        face_away(me, target)
        set_run(true)
        roles.line = 'Backing to ' .. tostring(math.floor(want)) .. 'y'
        return true
    end
    reset_path()
    set_run(false)
    local face = combat.face or 'toward'
    if face == 'away' then face_away(me, target)
    elseif face == 'toward' then face_toward(me, target, 0) end
    if player then try_lock(player) end
    return false
end

local function fight(player, me, target, prof)
    if not ensure_selected(target) then
        set_run(false)
        return
    end

    if player.status == 33 then
        set_run(false)
        act('/heal', 2)
        return
    end

    if hold_position(me, target, player, prof) then return end
    if os.clock() < next_act then return end

    local engaged = player.status == 1
    if not engaged and try_abilities(prof, false) then return end
    if not engaged then
        act('/attack', settings.action_delay)
        return
    end
    local tp_now = player.vitals and player.vitals.tp or 0
    local closing = (settings.role == 'dd' or settings.role == 'tank')
        and roles.chain_name() and tp_now >= 1000
    if not closing and try_abilities(prof, true) then return end
    try_ws(prof, player, target)
end

--------------------------------------------------------------------------------
-- Commands and display
--------------------------------------------------------------------------------

local function hud_text()
    if not settings then return 'Autofight ...' end
    local player = windower.ffxi.get_player()
    local target = windower.ffxi.get_mob_by_target('t')
    local tp = (player and player.vitals and player.vitals.tp) or 0
    local job = (player and player.main_job) or '--'
    local who = (target and target.name) or 'no target'
    return string.format('Autofight %s | %s | %s | %s | %s | TP %d',
        enabled and 'ON' or 'off', job, settings.mode, who, tostring(settings.distance) .. 'y', tp)
end

local function update_hud()
    if hud then hud:hide() end
    if gui and gui.refresh then gui.refresh() end
end

local function show_job(job)
    local prof = settings.jobs[job]
    if not prof then
        log(job .. ': no weaponskills or job abilities saved yet.')
        return
    end
    log(string.format('%s engage range %.1f yalms', job, prof.engage_range or 5))
    if #prof.ws == 0 then
        log('  weaponskill: (none)')
    end
    for i = 1, #prof.ws do
        local ws = prof.ws[i]
        log(string.format('  ws %s at %d TP, skip under %d%% HP', ws.name, ws.tp or 1000, ws.min_hpp or 0))
    end
    if #prof.abilities == 0 then
        log('  job ability: (none)')
    end
    for i = 1, #prof.abilities do
        local ja = prof.abilities[i]
        log(string.format('  ja %s %s', ja.name, ja.target))
    end
end

local function print_status()
    local job = current_job() or '--'
    log(string.format('Autofight %s | mode %s | distance %.1f | height %.1f | job %s',
        enabled and 'ON' or 'off', settings.mode, settings.distance, settings.height, job))
    if #settings.priority == 0 then
        log('Priority names: (none)')
    else
        log('Priority names: ' .. table.concat(settings.priority, ', '))
    end
    if job ~= '--' then show_job(job) end
end

local function parse_ws(args, from)
    local tokens = {}
    for i = from, #args do tokens[#tokens + 1] = args[i] end
    local tp, min_hpp = 1000, 0
    if #tokens >= 2 and tonumber(tokens[#tokens]) and tonumber(tokens[#tokens - 1]) then
        min_hpp = tonumber(table.remove(tokens))
        tp = tonumber(table.remove(tokens))
    elseif #tokens >= 1 and tonumber(tokens[#tokens]) then
        tp = tonumber(table.remove(tokens))
    end
    tp = math.max(1000, math.min(3000, math.floor(tp)))
    min_hpp = math.max(0, math.min(100, math.floor(min_hpp)))
    return trim(table.concat(tokens, ' ')), tp, min_hpp
end

local function parse_ja(args, from)
    local tokens = {}
    for i = from, #args do tokens[#tokens + 1] = args[i] end
    local tp = 0
    if #tokens >= 2 and tonumber(tokens[#tokens]) then
        tp = math.max(0, math.min(3000, math.floor(tonumber(table.remove(tokens)))))
    end
    local who
    if #tokens >= 2 then
        local last = tokens[#tokens]:lower()
        if last == 'me' or last == '<me>' then
            who = 'me'
            table.remove(tokens)
        elseif last == 't' or last == '<t>' then
            who = 't'
            table.remove(tokens)
        end
    end
    local name = trim(table.concat(tokens, ' '))
    return name, who or default_ja_target(name), tp
end

local function replace_named(list, name, entry)
    local out, replaced = {}, false
    for i = 1, #list do
        if list[i].name and list[i].name:lower() == name:lower() then
            if not replaced then out[#out + 1] = entry end
            replaced = true
        else
            out[#out + 1] = list[i]
        end
    end
    if not replaced then out[#out + 1] = entry end
    return out
end

local function drop_named(list, name)
    local out = {}
    for i = 1, #list do
        if not (list[i].name and list[i].name:lower() == name:lower()) then
            out[#out + 1] = list[i]
        end
    end
    return out
end

local function require_job(forced)
    local job = forced or current_job()
    if not job then
        log('Not in game. Use //af for WAR ... to edit a job.')
        return nil
    end
    job = job:upper()
    if not JOBS[job] then
        log('Unknown job ' .. job)
        return nil
    end
    return job
end

local HELP = {
    'Autofight (//af). Profiles are saved per main job.',
    'Click the overlay. //af role tank | dd | healer | support | mage',
    '  //af focus damage | grind     grind picks XP songs, rolls, and bars',
    '  //af element auto | fire | ice | wind | earth | lightning | water | light | dark',
    '  //af on | off | status',
    '  //af mode priority | aggressive | manual',
    '  //af distance <yalms|loaded>   chase range, loaded keeps anything the client can see',
    '  //af main <name|me>            other instances follow and assist this character',
    '  //af follow <yalms>            how close supporters stay to the main',
    '  Overlay: Face, Lock on, Spacing, job abilities with a TP step, and bard songs.',
    '  //af ja add <Name> [me|t] [tp]   use the ability once TP is at least this value',
    '  //af names <a, b, c>      priority list, first name wins',
    '  //af priority             show the list',
    '  //af priority add <name> | remove <name> | clear',
    '  //af ws add <name> [tp] [min hp%]     this job, highest ready TP is used',
    '  //af ws remove <name> | clear | show',
    '  //af ja add <name> [me|t]',
    '  //af ja remove <name> | clear',
    '  //af range <yalms>        how close this job gets before it engages',
    '  //af for <JOB> <command>  edit a job you are not currently on',
    '  //af job                  show this job    //af jobs   list saved jobs',
    'Example:',
    '  //af mode priority',
    '  //af names Beetle, Sapling',
    '  //af distance 22',
    '  //af for WAR ws add Savage Blade 1000',
    '  //af for WAR ws add King\'s Justice 1750',
    '  //af for WAR ja add Berserk me',
    '  //af for WAR ja add Provoke t',
    '  //af for WAR range 4',
    '  //af on',
}

local function handle(args, forced_job)
    local cmd = (args[1] or 'toggle'):lower()

    if cmd == 'help' then
        for i = 1, #HELP do log(HELP[i]) end
    elseif cmd == 'toggle' then
        enabled = not enabled
        if not enabled then set_run(false) end
        print_status()
    elseif cmd == 'on' or cmd == 'start' then
        enabled = true
        print_status()
    elseif cmd == 'off' or cmd == 'stop' then
        enabled = false
        set_run(false)
        print_status()
    elseif cmd == 'status' then
        print_status()
    elseif cmd == 'mode' then
        local mode = (args[2] or ''):lower()
        if mode == 'aggro' then mode = 'aggressive' end
        if mode == 'fight' then mode = 'manual' end
        if mode ~= 'priority' and mode ~= 'aggressive' and mode ~= 'manual' then
            log('Mode is priority, aggressive, or manual.')
            return
        end
        settings.mode = mode
        warned_names = false
        save_settings()
        log('Mode set to ' .. mode)
    elseif cmd == 'distance' then
        local word = (args[2] or ''):lower()
        if word == 'loaded' or word == 'all' then
            settings.distance = 0
            save_settings()
            log('Chase distance set to every target the client has loaded.')
            return
        end
        local n = tonumber(args[2])
        if not n or n < 1 or n > 500 then log('Distance is 1 to 500, or loaded.') return end
        settings.distance = n
        save_settings()
        log('Chase distance set to ' .. n)
    elseif cmd == 'main' then
        local name = join_args(args, 2)
        if name == '' or name:lower() == 'me' then name = 'me' end
        settings.main = name
        save_settings()
        log('Main character set to ' .. name)
    elseif cmd == 'follow' then
        local n = tonumber(args[2])
        if not n or n < 1 or n > 30 then log('Follow range is 1 to 30 yalms.') return end
        settings.follow = n
        save_settings()
        log('Follow range set to ' .. n)
    elseif cmd == 'names' then
        local text = join_args(args, 2)
        settings.priority = {}
        for name in (text .. ','):gmatch('%s*(.-)%s*,') do
            if name ~= '' then settings.priority[#settings.priority + 1] = name end
        end
        warned_names = false
        save_settings()
        log('Priority names: ' .. ((#settings.priority > 0 and table.concat(settings.priority, ', ')) or '(none)'))
    elseif cmd == 'priority' then
        local sub = (args[2] or 'show'):lower()
        if sub == 'show' then
            if #settings.priority == 0 then log('Priority names: (none)') end
            for i = 1, #settings.priority do log(string.format('%d. %s', i, settings.priority[i])) end
        elseif sub == 'clear' then
            settings.priority = {}
            save_settings()
            log('Priority names cleared.')
        elseif sub == 'add' or sub == 'top' or sub == 'remove' then
            local name = join_args(args, 3)
            if name == '' then log('Give a monster name.') return end
            local kept = {}
            for i = 1, #settings.priority do
                if settings.priority[i]:lower() ~= name:lower() then kept[#kept + 1] = settings.priority[i] end
            end
            if sub == 'add' then kept[#kept + 1] = name
            elseif sub == 'top' then table.insert(kept, 1, name) end
            settings.priority = kept
            warned_names = false
            save_settings()
            log('Priority names: ' .. ((#kept > 0 and table.concat(kept, ', ')) or '(none)'))
        else
            log('Usage: //af priority add|top|remove <name> | clear')
        end
    elseif cmd == 'range' then
        local job = require_job(forced_job)
        if not job then return end
        local n = tonumber(args[2])
        if not n or n < 1 or n > 30 then log('Range must be 1 to 30 yalms.') return end
        job_profile(job).engage_range = n
        save_settings()
        log(job .. ' engage range set to ' .. n)
    elseif cmd == 'ws' then
        local job = require_job(forced_job)
        if not job then return end
        local prof = job_profile(job)
        local sub = (args[2] or 'show'):lower()
        if sub == 'show' then
            show_job(job)
        elseif sub == 'clear' then
            prof.ws = {}
            save_settings()
            log(job .. ' weaponskills cleared.')
        elseif sub == 'remove' then
            local name = join_args(args, 3)
            prof.ws = drop_named(prof.ws, name)
            save_settings()
            show_job(job)
        elseif sub == 'add' then
            local name, tp, min_hpp = parse_ws(args, 3)
            if name == '' then log('Usage: //af ws add <name> [tp] [min hp%]') return end
            prof.ws = replace_named(prof.ws, name, { name = name, tp = tp, min_hpp = min_hpp })
            save_settings()
            log(string.format('%s will use %s at %d TP (skip under %d%%).', job, name, tp, min_hpp))
        else
            local name, tp, min_hpp = parse_ws(args, 2)
            if name == '' then log('Usage: //af ws add <name> [tp] [min hp%]') return end
            prof.ws = replace_named(prof.ws, name, { name = name, tp = tp, min_hpp = min_hpp })
            save_settings()
            log(string.format('%s will use %s at %d TP (skip under %d%%).', job, name, tp, min_hpp))
        end
    elseif cmd == 'ja' then
        local job = require_job(forced_job)
        if not job then return end
        local prof = job_profile(job)
        local sub = (args[2] or ''):lower()
        if sub == 'clear' then
            prof.abilities = {}
            save_settings()
            log(job .. ' job abilities cleared.')
        elseif sub == 'remove' then
            local name = join_args(args, 3)
            prof.abilities = drop_named(prof.abilities, name)
            save_settings()
            show_job(job)
        elseif sub == 'add' then
            local name, who, tp = parse_ja(args, 3)
            if name == '' then log('Usage: //af ja add <Name> [me|t] [tp]') return end
            prof.abilities = replace_named(prof.abilities, name, { name = name, target = '<' .. who .. '>', tp = tp or 0 })
            save_settings()
            log(string.format('%s will use %s on %s from %d TP.', job, name, who, tp or 0))
        else
            log('Usage: //af ja add <Name> [me|t] | remove <Name> | clear')
        end
    elseif cmd == 'job' then
        local job = (args[2] and args[2]:upper()) or current_job()
        if not job then log('Not in game.') return end
        show_job(job)
    elseif cmd == 'jobs' then
        local keys = {}
        for job in pairs(settings.jobs) do keys[#keys + 1] = job end
        table.sort(keys)
        if #keys == 0 then log('No job profiles yet.') return end
        log('Saved jobs: ' .. table.concat(keys, ', '))
    elseif cmd == 'role' then
        local alias = {
            melee = 'dd', damage = 'dd', dd = 'dd',
            buffer = 'support', support = 'support',
            debuffer = 'mage', mage = 'mage', nuker = 'mage',
            tank = 'tank', healer = 'healer',
        }
        local role = alias[(args[2] or ''):lower()]
        if not role then
            log('Role is tank, dd, healer, support, or mage.')
            return
        end
        settings.role = role
        if role == 'mage' then
            settings.heal.nuke = true
            if not settings.heal.element or settings.heal.element == 'Lightning' then
                settings.heal.element = 'Burst'
            end
        end
        save_settings()
        log('Role set to ' .. role)
    elseif cmd == 'focus' or cmd == 'goal' then
        local goal = (args[2] or ''):lower()
        if goal == 'xp' or goal == 'grind' then goal = 'grind'
        elseif goal == 'damage' or goal == 'dmg' then goal = 'damage'
        else
            log('Focus is damage or grind.')
            return
        end
        settings.goal = goal
        save_settings()
        log('Focus set to ' .. goal)
    elseif cmd == 'element' then
        local names = {
            auto = 'Auto', fire = 'Fire', ice = 'Ice', wind = 'Wind', earth = 'Earth',
            lightning = 'Lightning', thunder = 'Lightning', water = 'Water',
            light = 'Light', dark = 'Dark',
        }
        local element = names[(args[2] or ''):lower()]
        if not element then
            log('Element is auto, fire, ice, wind, earth, lightning, water, light, or dark.')
            return
        end
        settings.enemy_element = element
        save_settings()
        log('Enemy element set to ' .. element)
    else
        log('Unknown command. //af help')
    end
end

windower.register_event('addon command', function(...)
    local args = {...}
    if args[1] and args[1]:lower() == 'for' then
        local job = (args[2] or ''):upper()
        if not JOBS[job] then
            log('Usage: //af for WAR ws add Savage Blade 1000')
            return
        end
        local rest = {}
        for i = 3, #args do rest[#rest + 1] = args[i] end
        if #rest == 0 then show_job(job) return end
        handle(rest, job)
    else
        handle(args, nil)
    end
    update_hud()
end)

windower.register_event('incoming text', function(text)
    if not enabled or type(text) ~= 'string' then return end
    local plain = text:lower()
    if plain:find('too far', 1, true) then
        too_far_until = os.clock() + 4
        next_act = math.max(next_act, os.clock() + 1.5)
    elseif plain:find('unable to see', 1, true) or plain:find('cannot see', 1, true) then
        local target = windower.ffxi.get_mob_by_target('t')
        if target and target.id then skip_target(target) end
    end
end)

windower.register_event('zone change', function()
    blacklist = {}
    pending_id = nil
    reset_path()
    trip = nil
    warp = nil
    forced_id = nil
    set_run(false)
end)

windower.register_event('job change', function(main_id)
    local job = res.jobs[main_id]
    job = job and job.ens or current_job()
    if job then log('Autofight profile: ' .. job) end
    update_hud()
end)


local function is_leader(player)
    local main = settings.main
    if type(main) ~= 'string' or main == '' or main:lower() == 'me' then return true end
    return player and player.name and player.name:lower() == main:lower()
end

local function find_main_mob(player)
    local main = settings.main
    if type(main) ~= 'string' or main:lower() == 'me' then return nil end
    local want = main:lower()
    local party = windower.ffxi.get_party()
    if party then
        local keys = {
            'p0','p1','p2','p3','p4','p5',
            'a10','a11','a12','a13','a14','a15',
            'a20','a21','a22','a23','a24','a25',
        }
        for i = 1, #keys do
            local member = party[keys[i]]
            if type(member) == 'table' and member.name and member.name:lower() == want and type(member.mob) == 'table' then
                return member.mob
            end
        end
    end
    local mobs = windower.ffxi.get_mob_array()
    if not mobs then return nil end
    for _, mob in pairs(mobs) do
        if type(mob) == 'table' and mob.name and mob.name:lower() == want and mob.id ~= player.id then
            local spawn = mob.spawn_type
            if spawn == 1 or spawn == 9 or spawn == 13 or spawn == 14 then return mob end
        end
    end
    return nil
end

local function assist_of(main_mob, player)
    if not main_mob or not main_mob.target_index or main_mob.status ~= 1 then return nil end
    local target = windower.ffxi.get_mob_by_index(main_mob.target_index)
    if target and is_monster(target, player) then return target end
    return nil
end

local function apply_box(player)
    if not player or not player.name then return end
    if box_applied == player.name then return end
    box_applied = player.name
    local box = settings.box and settings.box[player.name]
    if type(box) ~= 'table' then return end
    if box.role then settings.role = box.role end
    if box.goal then settings.goal = box.goal end
    if box.songs then settings.songs = box.songs end
    if type(box.combat) == 'table' then settings.combat = box.combat end
    if player.main_job and type(box.abilities) == 'table' then
        local prof = job_profile(player.main_job)
        prof.abilities = {}
        for i = 1, #box.abilities do
            local entry = box.abilities[i]
            if type(entry) == 'table' and type(entry.name) == 'string' then
                prof.abilities[#prof.abilities + 1] = {
                    name = entry.name,
                    target = entry.target or '<me>',
                    tp = tonumber(entry.tp) or 0,
                }
            end
        end
    end
    if player.main_job and type(box.ws) == 'table' then
        local prof = job_profile(player.main_job)
        prof.ws = {}
        for i = 1, #box.ws do
            local entry = box.ws[i]
            if type(entry) == 'table' and type(entry.name) == 'string' then
                prof.ws[#prof.ws + 1] = {
                    name = entry.name,
                    tp = tonumber(entry.tp) or 1000,
                    min_hpp = tonumber(entry.min_hpp) or 0,
                }
            end
        end
    end
    if type(box.heal) == 'table' then
        settings.heal = settings.heal or {}
        for k, v in pairs(box.heal) do settings.heal[k] = v end
    end
    normalize()
end

local function party_names()
    local names = { 'me' }
    local seen = { me = true }
    local party = windower.ffxi.get_party()
    if not party then return names end
    local keys = {
        'p0','p1','p2','p3','p4','p5',
        'a10','a11','a12','a13','a14','a15',
        'a20','a21','a22','a23','a24','a25',
    }
    for i = 1, #keys do
        local member = party[keys[i]]
        if type(member) == 'table' and member.name and member.name ~= '' and not seen[member.name:lower()] then
            seen[member.name:lower()] = true
            names[#names + 1] = member.name
        end
    end
    return names
end

local function equipped_weapon()
    local items = windower.ffxi.get_items()
    if not items or not items.equipment then return nil, 'empty hands' end
    local eq = items.equipment
    local slot = windower.ffxi.get_items(eq.main_bag, eq.main)
    if (not slot or not slot.id or slot.id == 0) and eq.range_bag then
        slot = windower.ffxi.get_items(eq.range_bag, eq.range)
    end
    if not slot or not slot.id or slot.id == 0 then return nil, 'empty hands' end
    local item = res.items[slot.id]
    if not item then return nil, 'empty hands' end
    local skill_name = 'weapon'
    if item.skill and res.skills[item.skill] then skill_name = res.skills[item.skill].en end
    return item.skill, skill_name
end

local function ws_names()
    local skill = equipped_weapon()
    local names = {}
    if not skill then return names end
    for _, ws in pairs(res.weapon_skills) do
        if type(ws) == 'table' and ws.skill == skill and type(ws.en) == 'string' and ws.en ~= '' then
            names[#names + 1] = ws.en
        end
    end
    table.sort(names)
    return names
end

local function ws_on(name)
    local job = current_job()
    if not job then return false end
    local prof = job_profile(job)
    for i = 1, #prof.ws do
        if prof.ws[i].name and prof.ws[i].name:lower() == name:lower() then return true end
    end
    return false
end

local function ws_toggle(name)
    local job = current_job()
    if not job then return end
    local prof = job_profile(job)
    if ws_on(name) then
        prof.ws = drop_named(prof.ws, name)
    else
        prof.ws[#prof.ws + 1] = { name = name, tp = 1000, min_hpp = 0 }
    end
    save_settings()
end

local JA_TP = { 0, 1000, 1500, 2000, 3000 }

local function ja_names()
    local abilities = windower.ffxi.get_abilities()
    local names, seen = {}, {}
    if not abilities or type(abilities.job_abilities) ~= 'table' then return names end
    for _, id in pairs(abilities.job_abilities) do
        local ja = res.job_abilities[id]
        if ja and type(ja.en) == 'string' and ja.en ~= '' and not seen[ja.en] then
            seen[ja.en] = true
            names[#names + 1] = ja.en
        end
    end
    table.sort(names)
    return names
end

local function ja_tp(name)
    local job = current_job()
    if not job or not name then return nil end
    local prof = job_profile(job)
    for i = 1, #prof.abilities do
        local entry = prof.abilities[i]
        if entry.name and entry.name:lower() == name:lower() then
            return tonumber(entry.tp) or 0
        end
    end
    return nil
end

local function ja_cycle(name)
    local job = current_job()
    if not job or not name then return end
    local prof = job_profile(job)
    local found
    for i = 1, #prof.abilities do
        local entry = prof.abilities[i]
        if entry.name and entry.name:lower() == name:lower() then found = entry break end
    end
    if not found then
        local who = default_ja_target(name)
        prof.abilities[#prof.abilities + 1] = { name = name, target = '<' .. who .. '>', tp = 0 }
    else
        local tp = tonumber(found.tp) or 0
        local next_tp
        for i = 1, #JA_TP do
            if JA_TP[i] == tp then
                next_tp = JA_TP[i + 1]
                break
            end
        end
        if not next_tp and tp == 0 then next_tp = JA_TP[2] end
        if next_tp then found.tp = next_tp
        else prof.abilities = drop_named(prof.abilities, name) end
    end
    save_settings()
end

local function song_known(player, spell)
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

local function song_choices()
    local names = { '' }
    local player = windower.ffxi.get_player()
    if not player then return names end
    for _, spell in pairs(res.spells) do
        if type(spell) == 'table' and spell.type == 'BardSong' and type(spell.en) == 'string' and song_known(player, spell) then
            names[#names + 1] = spell.en
        end
    end
    table.sort(names, function(a, b)
        if a == '' then return true end
        if b == '' then return false end
        return a:lower() < b:lower()
    end)
    return names
end

local function make_env(player, me, target, anchor, main_name)
    return {
        player = player,
        me = me,
        target = target,
        anchor = anchor,
        main_name = main_name,
        settings = settings,
        can_act = function() return os.clock() >= next_act end,
        act = act,
        steer = steer,
        set_run = set_run,
        ensure = ensure_selected,
        enemy_element = roles.enemy_element(settings),
        burst_element = roles.burst_element(),
    }
end

local function run_role(role, env, player, target)
    if roles.perform_songs(env) then return end
    local spaced = tonumber(settings.combat and settings.combat.distance) or 0
    if role == 'healer' then
        local busy = healer.think(env)
        if not busy and target and spaced > 0 then
            hold_position(env.me, target, player, job_profile(player.main_job))
        end
        return
    end
    if (role == 'support' or role == 'mage') and target and spaced > 0 then
        if hold_position(env.me, target, player, job_profile(player.main_job)) then return end
    end
    if role == 'support' then
        roles.support(env)
        return
    end
    if role == 'mage' then
        roles.mage(env)
        return
    end
    if role == 'tank' and target and roles.tank(env) then return end
    if role == 'dd' and target and roles.dd(env) then return end
    if not target then
        set_run(false)
        reset_path()
        return
    end
    fight(player, env.me, target, job_profile(player.main_job))
end

local function clear_warp()
    if warp and warp.nudge then set_run(false) end
    if roles.line and roles.line:find('Warping', 1, true) == 1 then roles.line = '' end
    warp = nil
end

local function queue_warp(x, y, z, me, name)
    if not x or not y or not me then return false end
    local dx, dy = me.x - x, me.y - y
    local len = math.sqrt(dx * dx + dy * dy)
    local px, py = x, y
    if len > 0.2 then
        px = x + dx / len * 2
        py = y + dy / len * 2
    else
        px = x + 2
    end
    warp = {
        x = px,
        y = py,
        z = z or me.z or 0,
        name = name or 'target',
        until_t = os.clock() + 3,
        nudge = not running,
        nudge_until = os.clock() + 0.4,
        sent = false,
    }
    if warp.nudge then set_run(true) end
    roles.line = 'Warping to ' .. warp.name
    return true
end

local function begin_trip(entry)
    if type(entry) ~= 'table' then return end
    local player = windower.ffxi.get_player()
    local me = windower.ffxi.get_mob_by_target('me')
    local mob = entry.index and windower.ffxi.get_mob_by_index(entry.index)
    if (not mob or not mob.name or mob.name == '') and entry.id then
        mob = windower.ffxi.get_mob_by_id(entry.id)
    end
    local name = (mob and mob.name) or entry.name or 'target'
    if mob and player and is_monster(mob, player) then
        select_target(mob)
        forced_id = mob.id
    end
    if mob and mob.x and mob.y and me then
        local dist = math.sqrt((me.x - mob.x) ^ 2 + (me.y - mob.y) ^ 2)
        trip = nil
        if dist > 3 then queue_warp(mob.x, mob.y, mob.z, me, name) end
        return
    end
    if entry.index then scan.track(entry.index) end
    trip = { index = entry.index, id = entry.id, name = name }
    roles.line = 'Tracking ' .. name
end

local function walk_trip(me, player)
    if warp and warp.nudge and os.clock() >= warp.nudge_until then
        warp.nudge = nil
        set_run(false)
    end
    if not trip then return false end
    local x, y, z
    local name = trip.name
    local spawned = trip.index and windower.ffxi.get_mob_by_index(trip.index)
    if (not spawned or not spawned.x) and trip.id then
        spawned = windower.ffxi.get_mob_by_id(trip.id)
    end
    if spawned and spawned.x and spawned.y and spawned.name and spawned.name ~= '' then
        x, y, z = spawned.x, spawned.y, spawned.z
        name = spawned.name
        if player and is_monster(spawned, player) then
            select_target(spawned)
            forced_id = spawned.id
        end
    end
    if not x then
        local pos = scan.position()
        if pos and pos.x and pos.y then x, y, z = pos.x, pos.y, pos.z end
    end
    if not x or not y then
        roles.line = 'Tracking ' .. (name or 'target')
        return true
    end
    local dist = math.sqrt((me.x - x) ^ 2 + (me.y - y) ^ 2)
    trip = nil
    if dist > 3 then queue_warp(x, y, z, me, name) end
    return false
end

local next_tick = 0
windower.register_event('prerender', function()
    local now = os.clock()
    if now < next_tick then return end
    next_tick = now + 0.2

    if warp and warp.nudge and now >= warp.nudge_until then
        warp.nudge = nil
        set_run(false)
    end

    if not settings or not enabled then
        local info = windower.ffxi.get_info()
        local player = windower.ffxi.get_player()
        local me = windower.ffxi.get_mob_by_target('me')
        if settings and info and info.logged_in and not info.menu_open and player and me
            and player.status ~= 2 and player.status ~= 3 then
            scan.update()
            walk_trip(me, player)
        end
        if not (warp and warp.nudge) then set_run(false) end
        update_hud()
        return
    end

    local info = windower.ffxi.get_info()
    local player = windower.ffxi.get_player()
    local me = windower.ffxi.get_mob_by_target('me')
    if not info or not info.logged_in or info.menu_open or not player or not me then
        set_run(false)
        update_hud()
        return
    end
    if player.status == 2 or player.status == 3 or (me.hpp and me.hpp <= 0) then
        set_run(false)
        update_hud()
        return
    end
    if player.status ~= 0 and player.status ~= 1 and player.status ~= 33 then
        set_run(false)
        update_hud()
        return
    end

    apply_box(player)
    local role = settings.role or 'dd'
    if role == 'healer' then
        local main_name = is_leader(player) and player.name or settings.main
        if healer.think(make_env(player, me, nil, nil, main_name)) then
            update_hud()
            return
        end
    end
    scan.update()
    if walk_trip(me, player) then
        update_hud()
        return
    end

    local leader = is_leader(player)
    local locked = nil
    if forced_id then
        local mob = windower.ffxi.get_mob_by_id(forced_id)
        if mob and is_monster(mob, player) then
            locked = mob
        else
            forced_id = nil
        end
    end
    local target = locked
    local anchor = nil
    local main_name = player.name
    if not leader then
        main_name = settings.main
        local main_mob = find_main_mob(player)
        anchor = main_mob
        if not locked then
            if not main_mob or not main_mob.distance then
                roles.line = 'Waiting for ' .. (settings.main or 'main')
                set_run(false)
                if role == 'healer' then healer.think(make_env(player, me, nil, nil, main_name)) end
                update_hud()
                return
            end
            local dist = math.sqrt(main_mob.distance)
            local gap = tonumber(settings.follow) or 4
            if role == 'healer' or role == 'mage' or role == 'support' then gap = math.max(gap, 6) end
            target = assist_of(main_mob, player)
            if dist > gap then
                local env = make_env(player, me, target, anchor, main_name)
                local busy = false
                if role == 'healer' then busy = healer.think(env)
                elseif role == 'support' then busy = roles.support(env)
                end
                if not busy then
                    roles.line = 'Following ' .. (main_mob.name or 'main')
                    if not steer(me, main_mob, dist) then set_run(false) end
                end
                update_hud()
                return
            end
        end
    elseif not locked then
        local heal = settings.heal or {}
        local want_enemy = role ~= 'healer'
        if role == 'healer' and (heal.enfeeble ~= false or heal.nuke) then want_enemy = true end
        target = want_enemy and choose_target(me, player) or nil
    end
    run_role(role, make_env(player, me, target, anchor, main_name), player, target)
    update_hud()
end)


windower.register_event('outgoing chunk', function(id, data)
    if id ~= 0x015 or not warp then return end
    if os.clock() > warp.until_t then
        clear_warp()
        return
    end
    local ok, parsed = pcall(packets.parse, 'outgoing', data)
    if not ok or type(parsed) ~= 'table' then return end
    parsed.X = warp.x
    parsed.Y = warp.y
    parsed.Z = warp.z
    local built_ok, built = pcall(packets.build, parsed)
    if not built_ok or type(built) ~= 'string' then return end
    warp.sent = true
    return built
end)

windower.register_event('incoming chunk', function(id)
    if id == 0x065 and warp and warp.sent then clear_warp() end
end)

windower.register_event('unload', function()
    set_run(false)
end)

windower.register_event('load', function()
    load_settings()
    gui.init({
        settings = function() return settings end,
        enabled = function() return enabled end,
        set_enabled = function(v)
            enabled = v and true or false
            if not enabled then set_run(false) end
        end,
        save = save_settings,
        summary = function()
            return healer.summary(windower.ffxi.get_player())
        end,
        notice = function()
            if settings.role == 'healer' or settings.role == 'mage' then
                if healer.line and healer.line ~= '' then return healer.line end
            end
            return roles.line or ''
        end,
        detail = function() return roles.detail() end,
        leader = function()
            return is_leader(windower.ffxi.get_player())
        end,
        party = party_names,
        jobs = function()
            local player = windower.ffxi.get_player()
            if not player then return {} end
            return {
                main = player.main_job,
                sub = player.sub_job,
                main_level = player.main_job_level,
                sub_level = player.sub_job_level,
            }
        end,
        weapon = function()
            local _, name = equipped_weapon()
            return name or 'empty hands'
        end,
        ws_list = ws_names,
        ws_on = ws_on,
        ws_toggle = ws_toggle,
        ja_list = ja_names,
        ja_tp = ja_tp,
        ja_cycle = ja_cycle,
        song_choices = song_choices,
        scan_view = function() return scan.view() end,
        scan_now = function() scan.request() end,
        scan_page = function() scan.next_page() end,
        scan_go = function(n)
            local entry = scan.get(n)
            if entry then begin_trip(entry) end
        end,
        trip = function()
            if trip and trip.name then return trip.name end
            if warp and warp.name then return warp.name end
            return ''
        end,
        trip_clear = function()
            trip = nil
            forced_id = nil
            clear_warp()
        end,
        engage = function()
            local job = current_job()
            if not job then return 5 end
            return job_profile(job).engage_range or 5
        end,
        cycle_engage = function()
            local job = current_job()
            if not job then return end
            local prof = job_profile(job)
            local opts = { 3, 4, 5, 6, 8, 12, 20 }
            local cur = prof.engage_range or 5
            local nxt = opts[1]
            for i = 1, #opts do
                if opts[i] == cur then nxt = opts[(i % #opts) + 1] break end
            end
            prof.engage_range = nxt
            save_settings()
        end,
    })
    hud = texts.new('', {
        pos = {x = 40, y = 240},
        text = {
            font = 'Consolas',
            size = 11,
            stroke = {width = 1, alpha = 180, red = 0, green = 0, blue = 0},
        },
        bg = {alpha = 140, red = 0, green = 0, blue = 0, visible = true},
        flags = {draggable = true},
        padding = 4,
    })
    update_hud()
    log('Autofight loaded and off. Click the overlay, or //af help')
end)
