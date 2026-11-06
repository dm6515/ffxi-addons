local packets = require('packets')
local settings = require('settings')
local party = require('party')
local travel = require('travel')

local engage = {}

local hold_id = nil
local last_switch = 0
local last_attack = 0
local status_line = 'Off'

local function model_size(mob)
    if type(mob) ~= 'table' then
        return 0
    end
    local size = mob.model_size or mob._model_size
    if type(size) ~= 'number' or size < 0 then
        return 0
    end
    return size
end

-- spawn_type bit 0x10 is a monster. Players are 0x01, NPCs are 0x02.
local function is_monster(spawn_type)
    return type(spawn_type) == 'number' and math.floor(spawn_type / 16) % 2 == 1
end

function engage.is_enemy(mob, ctx)
    if type(mob) ~= 'table' or type(mob.id) ~= 'number' or mob.id == 0 then
        return false
    end
    if mob.valid_target == false or mob.is_valid == false then
        return false
    end
    if mob.is_npc == false then
        return false
    end
    if not is_monster(mob.spawn_type) then
        return false
    end
    if mob.in_party or mob.in_alliance or mob.charmed then
        return false
    end
    if type(mob.name) ~= 'string' or mob.name == '' then
        return false
    end
    if mob.hpp ~= nil and mob.hpp <= 0 then
        return false
    end
    if mob.status == 2 or mob.status == 3 then
        return false
    end
    if ctx.party_ids[mob.id] or ctx.alliance_ids[mob.id] then
        return false
    end
    if type(mob.index) == 'number' and ctx.skip_index[mob.index] then
        return false
    end
    return true
end

-- Center-to-center melee reach in yalms. mob.distance is the square of that distance.
function engage.melee_reach(me, target)
    return model_size(me) + model_size(target) + 2
end

function engage.in_melee(me, target)
    if type(target) ~= 'table' or type(target.distance) ~= 'number' then
        return false
    end
    local reach = engage.melee_reach(me, target)
    return target.distance <= reach * reach
end

function engage.pick(mobs, radius, ctx)
    if type(mobs) ~= 'table' or type(radius) ~= 'number' or radius < 0 then
        return nil
    end
    local radius_sq = radius * radius
    local best_pref, best_pref_d
    local best_other, best_other_d

    for _, mob in pairs(mobs) do
        if engage.is_enemy(mob, ctx) and type(mob.distance) == 'number' and mob.distance <= radius_sq then
            local claim = mob.claim_id or 0
            local preferred = claim == 0 or ctx.party_ids[claim] == true
            if preferred then
                if not best_pref_d or mob.distance < best_pref_d then
                    best_pref = mob
                    best_pref_d = mob.distance
                end
            elseif not best_other_d or mob.distance < best_other_d then
                best_other = mob
                best_other_d = mob.distance
            end
        end
    end

    return best_pref or best_other
end

function engage.status()
    return status_line
end

function engage.clear()
    hold_id = nil
end

local function send_action(mob, category)
    if type(mob.index) ~= 'number' then
        return
    end
    local packet = packets.new('outgoing', 0x01A, {
        ['Target'] = mob.id,
        ['Target Index'] = mob.index,
        ['Category'] = category,
        ['Param'] = 0,
        ['X Offset'] = 0,
        ['Z Offset'] = 0,
        ['Y Offset'] = 0,
    })
    packets.inject(packet)
end

function engage.tick(now, enabled)
    if not enabled then
        hold_id = nil
        travel.release()
        status_line = 'Off'
        return
    end

    local player = windower.ffxi.get_player()
    if type(player) ~= 'table' or player.status == 2 or player.status == 3 then
        travel.release()
        hold_id = nil
        status_line = 'Waiting'
        return
    end

    local radius = settings.radius()
    local mob = engage.pick(windower.ffxi.get_mob_array() or {}, radius, party.battle_context())
    if not mob then
        hold_id = nil
        travel.release()
        status_line = string.format('No enemy within %d yalms', radius)
        return
    end

    local me = windower.ffxi.get_mob_by_target('me')
    if type(me) ~= 'table' then
        travel.release()
        return
    end

    -- Keep running a short way inside the edge so the stop/start line does not twitch.
    local dist = math.sqrt(mob.distance)
    local reach = engage.melee_reach(me, mob)
    local in_range = dist <= reach or (hold_id == mob.id and dist <= reach + 0.6)
    local current = windower.ffxi.get_mob_by_target('t')
    local targeted = type(current) == 'table' and current.id == mob.id

    if not targeted and now - last_switch >= 0.75 then
        send_action(mob, 0x0F)
        last_switch = now
    end

    if in_range then
        hold_id = mob.id
        travel.release()
        local swinging = targeted and player.status == 1
        if not swinging and now - last_attack >= 1.5 then
            send_action(mob, 0x02) -- engage monster
            last_attack = now
        end
        status_line = string.format('Engaging %s (%.1f yalms)', mob.name, dist)
    else
        if hold_id == mob.id then
            hold_id = nil
        end
        travel.toward(mob.x, mob.y, now)
        local phase = travel.phase()
        if phase == 'strafe' or phase == 'backup' or phase == 'heading' then
            status_line = string.format('Unstuck (%s) toward %s', phase, mob.name)
        else
            status_line = string.format('Running to %s (%.1f yalms)', mob.name, dist)
        end
    end
end

return engage
