--[[
    Zone list from the client's widescan, plus anything already loaded nearby.
    A unique enemy name is treated as a notorious monster and listed first.
]]

local packets = require('packets')

local M = { page = 1, line = '' }
local PAGE = 40
local list = {}
local scanning = false
local scan_at = 0
local next_scan = 0
local track_index = nil
local track_pos = nil

local function clean(name)
    if type(name) ~= 'string' then return '' end
    return (name:gsub('%z', ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function named(name)
    return name ~= '' and not name:find('?', 1, true)
end

local function kind_name(value)
    if value == 2 or value == 'Enemy' then return 'enemy' end
    if value == 1 or value == 'Friendly' then return 'npc' end
    if type(value) == 'string' then
        local lower = value:lower()
        if lower:find('enemy', 1, true) then return 'enemy' end
        if lower:find('friendly', 1, true) then return 'npc' end
    end
    return 'other'
end

local function mark_kind(value)
    if value == 1 or value == 'Start' then return 'start' end
    if value == 2 or value == 'End' then return 'end' end
    if type(value) == 'string' then
        local lower = value:lower()
        if lower:find('start', 1, true) then return 'start' end
        if lower:find('end', 1, true) then return 'end' end
    end
    return ''
end

local function add_entry(entry)
    if entry.name == '' then return end
    list[#list + 1] = entry
end

local function finish()
    local kept = {}
    local seen = {}
    for i = 1, #list do
        local entry = list[i]
        if entry.kind == 'enemy' and named(entry.name) then
            local key = entry.index
            if key and seen[key] then
                local prev = seen[key]
                if (entry.level or 0) > (prev.level or 0) then prev.level = entry.level end
            else
                kept[#kept + 1] = entry
                if key then seen[key] = entry end
            end
        end
    end
    list = kept
    local counts = {}
    for i = 1, #list do
        local key = list[i].name:lower()
        counts[key] = (counts[key] or 0) + 1
    end
    local nm_count = 0
    for i = 1, #list do
        local entry = list[i]
        entry.nm = counts[entry.name:lower()] == 1
        if entry.nm then nm_count = nm_count + 1 end
        local level = ''
        if entry.level and entry.level > 0 then level = '  Lv' .. tostring(entry.level) end
        entry.label = (entry.nm and 'NM  ' or '') .. entry.name .. level
        entry.order = entry.nm and 1 or 2
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        return a.name:lower() < b.name:lower()
    end)
    for i = 1, #list do list[i].n = i end
    scanning = false
    M.page = 1
    M.line = tostring(nm_count) .. ' NM, ' .. tostring(#list) .. ' enemies'
end

local function nearby()
    list = {}
    local mobs = windower.ffxi.get_mob_array()
    if not mobs then finish() return end
    local rows = {}
    for _, mob in pairs(mobs) do
        if type(mob) == 'table' and mob.name and mob.name ~= '' and mob.index and mob.index > 0 then
            local spawn = mob.spawn_type
            local kind = nil
            if spawn == 16 and named(mob.name) then kind = 'enemy' end
            if kind then
                rows[#rows + 1] = {
                    name = mob.name,
                    index = mob.index,
                    id = mob.id,
                    level = 0,
                    kind = kind,
                }
            end
        end
    end
    for i = 1, #rows do add_entry(rows[i]) end
    finish()
    M.line = M.line .. ' nearby'
end

function M.request()
    local now = os.clock()
    if now < next_scan then
        M.line = 'Scan cooling down'
        return false
    end
    next_scan = now + 8
    scan_at = now
    scanning = true
    list = {}
    M.line = 'Scanning'
    local ok = pcall(function()
        packets.inject(packets.new('outgoing', 0x0F4, { ['Flags'] = 1 }))
    end)
    if not ok then
        scanning = false
        nearby()
    end
    return true
end

function M.update()
    if not scanning then return end
    if os.clock() - scan_at <= 3 then return end
    if #list == 0 then nearby() else finish() end
end

function M.view()
    M.update()
    local pages = math.max(1, math.ceil(#list / PAGE))
    if M.page > pages then M.page = pages end
    if M.page < 1 then M.page = 1 end
    local from = (M.page - 1) * PAGE + 1
    local rows = {}
    for i = from, math.min(#list, from + PAGE - 1) do
        rows[#rows + 1] = list[i]
    end
    return rows, M.page, pages, M.line, scanning
end

function M.next_page()
    local pages = math.max(1, math.ceil(#list / PAGE))
    M.page = (M.page % pages) + 1
end

function M.get(n)
    return list[n]
end

function M.track(index)
    track_index = index
    track_pos = nil
    pcall(function()
        packets.inject(packets.new('outgoing', 0x0F5, { ['Index'] = index }))
    end)
end

function M.position()
    return track_pos
end

windower.register_event('incoming chunk', function(id, data)
    if id == 0x0F6 then
        local ok, parsed = pcall(packets.parse, 'incoming', data)
        if not ok or type(parsed) ~= 'table' then return end
        local mark = mark_kind(parsed.Type)
        if mark == 'start' then
            list = {}
            scanning = true
        elseif mark == 'end' then
            finish()
        end
    elseif id == 0x0F4 and scanning then
        local ok, parsed = pcall(packets.parse, 'incoming', data)
        if not ok or type(parsed) ~= 'table' then return end
        local name = clean(parsed.Name)
        local index = parsed.Index
        local kind = kind_name(parsed.Type)
        if index and not named(name) then
            local mob = windower.ffxi.get_mob_by_index(index)
            if mob and mob.name and mob.name ~= '' then
                name = clean(mob.name)
                if mob.spawn_type == 16 then kind = 'enemy' end
            end
        end
        if kind == 'enemy' then
            add_entry({
                name = name,
                index = index,
                level = tonumber(parsed.Level) or 0,
                kind = 'enemy',
            })
        end
    elseif id == 0x0F5 then
        local ok, parsed = pcall(packets.parse, 'incoming', data)
        if not ok or type(parsed) ~= 'table' then return end
        if track_index and parsed.Index == track_index then
            track_pos = { x = parsed.X, y = parsed.Y, z = parsed.Z }
        end
    end
end)

return M
