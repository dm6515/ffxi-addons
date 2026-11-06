local settings = require('settings')
local packets = require('packets')

local party = {}

-- Entity status byte on mob.status. Not a buff id.
local STATUS_NAME = {
    [0] = 'Idle',
    [1] = 'Engaged',
    [2] = 'Dead',
    [3] = 'Dead',
    [4] = 'Event',
    [5] = 'Chocobo',
    [33] = 'Resting',
}

local PARTY_KEYS = { 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }
local ALLIANCE_KEYS = {
    'a10', 'a11', 'a12', 'a13', 'a14', 'a15',
    'a20', 'a21', 'a22', 'a23', 'a24', 'a25',
}

local last_switch = 0
local assist_text = 'Select a main.'

function party.yalms(distance_sq)
    if type(distance_sq) ~= 'number' or distance_sq < 0 then
        return nil
    end
    -- The client stores distance squared, in yalms.
    return math.sqrt(distance_sq)
end

function party.format_distance(distance_sq)
    local yalms = party.yalms(distance_sq)
    if not yalms then
        return '-'
    end
    return string.format('%.1f', yalms)
end

function party.status_name(code)
    if code == nil then
        return '-'
    end
    return STATUS_NAME[code] or tostring(code)
end

function party.build_slots(party_table, resolve_index)
    local slots = {}
    for i = 0, 5 do
        local member = party_table and party_table['p' .. i]
        local slot = {
            index = i,
            name = nil,
            hpp = nil,
            distance = nil,
            status = nil,
        }
        if type(member) == 'table' and type(member.name) == 'string' and member.name ~= '' then
            slot.name = member.name
            slot.hpp = member.hpp
            local mob = member.mob and resolve_index and resolve_index(member.mob)
            if type(mob) == 'table' then
                slot.distance = mob.distance
                slot.status = mob.status
                if slot.hpp == nil then
                    slot.hpp = mob.hpp
                end
            end
        end
        slots[#slots + 1] = slot
    end
    return slots
end

-- Mob the main is currently locked onto, or nil when this client is the main.
function party.main_target(party_table, player_name, main_name, resolve_index)
    if type(main_name) ~= 'string' or main_name == '' then
        return nil
    end
    if player_name == main_name then
        return nil
    end
    if type(party_table) ~= 'table' or not resolve_index then
        return nil
    end

    local main_member
    for i = 1, #PARTY_KEYS do
        local member = party_table[PARTY_KEYS[i]]
        if type(member) == 'table' and member.name == main_name then
            main_member = member
            break
        end
    end
    if not main_member or not main_member.mob then
        return nil
    end

    local main_mob = resolve_index(main_member.mob)
    -- target_index 0 is the client's "no target" sentinel, not entity slot 0.
    if type(main_mob) ~= 'table' or type(main_mob.target_index) ~= 'number' or main_mob.target_index <= 0 then
        return nil
    end

    local target = resolve_index(main_mob.target_index)
    if type(target) ~= 'table' or type(target.id) ~= 'number' or target.id == 0 then
        return nil
    end
    return target
end

local function add_member(member, ids, skip_index, resolve_index)
    if type(member) ~= 'table' then
        return
    end
    if type(member.id) == 'number' and member.id ~= 0 then
        ids[member.id] = true
    end
    if not member.mob then
        return
    end
    skip_index[member.mob] = true
    local mob = resolve_index(member.mob)
    if type(mob) ~= 'table' then
        return
    end
    if type(mob.id) == 'number' and mob.id ~= 0 then
        ids[mob.id] = true
    end

    local function add_related(index)
        if type(index) ~= 'number' or index == 0 then
            return
        end
        skip_index[index] = true
        local related = resolve_index(index)
        if type(related) == 'table' and type(related.id) == 'number' and related.id ~= 0 then
            ids[related.id] = true
            if type(related.index) == 'number' then
                skip_index[related.index] = true
            end
        end
    end

    add_related(mob.pet_index)
    add_related(mob.fellow_index)
end

function party.context_from(party_table, self_id, resolve_index, pet_mob)
    local party_ids = {}
    local alliance_ids = {}
    local skip_index = {}
    resolve_index = resolve_index or function() end

    if type(party_table) == 'table' then
        for i = 1, #PARTY_KEYS do
            add_member(party_table[PARTY_KEYS[i]], party_ids, skip_index, resolve_index)
        end
        for i = 1, #ALLIANCE_KEYS do
            add_member(party_table[ALLIANCE_KEYS[i]], alliance_ids, skip_index, resolve_index)
        end
    end

    if type(self_id) == 'number' and self_id ~= 0 then
        party_ids[self_id] = true
    end
    if type(pet_mob) == 'table' then
        if type(pet_mob.id) == 'number' and pet_mob.id ~= 0 then
            party_ids[pet_mob.id] = true
        end
        if type(pet_mob.index) == 'number' then
            skip_index[pet_mob.index] = true
        end
    end

    return {
        party_ids = party_ids,
        alliance_ids = alliance_ids,
        skip_index = skip_index,
    }
end

local function logged_in()
    local info = windower.ffxi.get_info()
    return type(info) == 'table' and info.logged_in
end

local function resolve(index)
    if not index then
        return nil
    end
    return windower.ffxi.get_mob_by_index(index)
end

function party.slots()
    local party_table = nil
    if logged_in() then
        party_table = windower.ffxi.get_party()
    end
    return party.build_slots(party_table, resolve)
end

function party.battle_context()
    local party_table = nil
    local self_id = nil
    local pet = nil
    if logged_in() then
        party_table = windower.ffxi.get_party()
        local player = windower.ffxi.get_player()
        if type(player) == 'table' then
            self_id = player.id
        end
        pet = windower.ffxi.get_mob_by_target('pet')
    end
    return party.context_from(party_table, self_id, resolve, pet)
end

local function switch_target(mob)
    local packet = packets.new('outgoing', 0x01A, {
        ['Target'] = mob.id,
        ['Target Index'] = mob.index,
        ['Category'] = 0x0F, -- switch target, not engage
        ['Param'] = 0,
        ['X Offset'] = 0,
        ['Z Offset'] = 0,
        ['Y Offset'] = 0,
    })
    packets.inject(packet)
end

function party.assist_text()
    return assist_text
end

function party.assist(now)
    local player = windower.ffxi.get_player()
    local main = settings.main_name()
    if type(player) ~= 'table' then
        assist_text = 'Not logged in.'
        return
    end
    if main == '' then
        assist_text = 'Select a main. Other clients copy that character\'s target.'
        return
    end
    if player.name == main then
        assist_text = 'You are the main.'
        return
    end
    -- Engage owns targeting while the toggle is on. Assisting here would steal it back.
    if settings.engage_on() then
        assist_text = 'Engage is on, so this client is not assisting.'
        return
    end

    local target = party.main_target(windower.ffxi.get_party(), player.name, main, resolve)
    if not target then
        assist_text = 'Assisting ' .. main .. ' (no target).'
        return
    end
    if target.id == player.id then
        assist_text = 'Assisting ' .. main .. '.'
        return
    end

    assist_text = 'Assisting ' .. main .. ' -> ' .. (target.name or 'target') .. '.'
    local current = windower.ffxi.get_mob_by_target('t')
    if type(current) == 'table' and current.id == target.id then
        return
    end
    if now - last_switch < 0.75 then
        return
    end
    if type(target.index) ~= 'number' then
        return
    end
    switch_target(target)
    last_switch = now
end

return party
