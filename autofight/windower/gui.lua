--[[
    Clickable overlay. Drag anywhere on the panel to move it. A short click still toggles a row.
]]

local texts = require('texts')

local gui = {}
local api
local title
local body
local rows = {}
local armed = false
local dragging = false
local down_x, down_y = 0, 0
local drag_dx, drag_dy = 0, 0

local MODES = { 'priority', 'aggressive', 'manual' }
local DISTANCES = { 15, 20, 25, 30, 40, 50, 75, 100, 0 }
local FOLLOW = { 2, 4, 6, 8, 12 }
local ws_page = 1
local ja_page = 1
local song_page = 1
local panel = 'setup'
local SONG_PAGES = { 'base', 'dummy', 'pia' }
local SPACING = { 0, 6, 8, 10, 12, 15, 20, 25 }
local FACES = { 'toward', 'away', 'hold' }
local RANGES = { 15, 18, 20, 22, 25 }
local CURE_HP = { 50, 60, 70, 75, 85, 95 }
local RESERVES = { 20, 30, 40, 50, 60 }
local ELEMENTS = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' }
local NUKE_ELEMENTS = { 'Burst', 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' }
local ENEMY_ELEMENTS = { 'Auto', 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' }
local ROLES = { 'tank', 'dd', 'healer', 'support', 'mage' }
local SONGS = { 1, 2, 3, 4 }

local function cycle(list, current)
    for i = 1, #list do
        if list[i] == current then return list[(i % #list) + 1] end
    end
    return list[1]
end

local function on(flag)
    if flag then return '\\cs(120,210,140)ON\\cr' end
    return '\\cs(150,150,150)off\\cr'
end

local function row(label, fn)
    rows[#rows + 1] = { label = label, fn = fn }
end

local function paint()
    if not body then return end
    local lines = {}
    for i = 1, #rows do lines[i] = rows[i].label end
    body:text(table.concat(lines, '\n'))
    body:show()
end

local function party_rows()
    local ok, party = pcall(windower.ffxi.get_party)
    if not ok or not party or not party.p0 then return end
    local zone = party.p0.zone
    row('\\cs(180,190,210)Party\\cr', nil)
    local any = false
    for i = 0, 5 do
        local m = party['p' .. i]
        if type(m) == 'table' and m.name and m.name ~= '' and m.zone == zone then
            any = true
            local hpp = m.hpp or 0
            local color = '\\cs(140,210,140)'
            if hpp < 50 then color = '\\cs(220,90,90)'
            elseif hpp < 75 then color = '\\cs(220,190,80)' end
            row(string.format('  %s  %s%d%%%s', m.name, color, hpp, '\\cr'), nil)
        end
    end
    if not any then row('  (nobody in range)', nil) end
end


local function dist_label(n)
    n = tonumber(n) or 0
    if n <= 0 then return 'Loaded' end
    return tostring(n)
end

local function song_label(name)
    if not name or name == '' then return '(none)' end
    return name
end

local function ensure_book(s)
    if type(s.songs) ~= 'table' or not s.songs.base then
        s.songs = {
            count = 2,
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
    end
    return s.songs
end

local function add_role_options(s, heal)
    local jobs = (api.jobs and api.jobs()) or {}
    local role = s.role or 'dd'
    local leader = (not api.leader) or api.leader()
    local bard = jobs.main == 'BRD' or jobs.sub == 'BRD'
    s.combat = s.combat or { face = 'toward', lock = false, distance = 0 }

    row('Main             ' .. (s.main or 'me'), function()
        local names = (api.party and api.party()) or { 'me' }
        s.main = cycle(names, s.main or 'me')
        api.save()
    end)

    if leader then
        row('Target mode      ' .. (s.mode or 'priority'), function()
            s.mode = cycle(MODES, s.mode)
            api.save()
        end)
        row('Chase distance   ' .. dist_label(s.distance or 20), function()
            s.distance = cycle(DISTANCES, s.distance or 20)
            api.save()
        end)
    else
        row('Follow range     ' .. tostring(s.follow or 4), function()
            s.follow = cycle(FOLLOW, s.follow or 4)
            api.save()
        end)
    end

    row('Face             ' .. (s.combat.face or 'toward'), function()
        s.combat.face = cycle(FACES, s.combat.face or 'toward')
        api.save()
    end)
    row('Lock on          ' .. on(s.combat.lock), function()
        s.combat.lock = not s.combat.lock
        api.save()
    end)
    local gap = tonumber(s.combat.distance) or 0
    row('Spacing          ' .. (gap <= 0 and 'Melee' or (tostring(gap) .. 'y')), function()
        s.combat.distance = cycle(SPACING, gap)
        api.save()
    end)

    if role == 'tank' then
        row('Enemy element    ' .. (s.enemy_element or 'Auto'), function()
            s.enemy_element = cycle(ENEMY_ELEMENTS, s.enemy_element or 'Auto')
            api.save()
        end)
    end

    row('Melee range      ' .. tostring(api.engage()), api.cycle_engage)
    local weapon = (api.weapon and api.weapon()) or 'empty hands'
    local list = (api.ws_list and api.ws_list()) or {}
    local pages = math.max(1, math.ceil(#list / 6))
    if ws_page > pages then ws_page = 1 end
    row('Weapon           ' .. weapon, function()
        if pages > 1 then ws_page = (ws_page % pages) + 1 end
    end)
    if #list == 0 then
        row('  no weaponskills for this weapon', nil)
    else
        local from = (ws_page - 1) * 6 + 1
        for i = from, math.min(#list, from + 5) do
            local name = list[i]
            local mark = (api.ws_on and api.ws_on(name)) and '+' or '-'
            row('  ' .. mark .. ' ' .. name, function()
                if api.ws_toggle then api.ws_toggle(name) end
            end)
        end
        if pages > 1 then
            row('WS page          ' .. tostring(ws_page) .. '/' .. tostring(pages), function()
                ws_page = (ws_page % pages) + 1
            end)
        end
    end

    local jas = (api.ja_list and api.ja_list()) or {}
    local ja_pages = math.max(1, math.ceil(#jas / 6))
    if ja_page > ja_pages then ja_page = 1 end
    row('Job abilities    ' .. tostring(ja_page) .. '/' .. tostring(ja_pages), function()
        if ja_pages > 1 then ja_page = (ja_page % ja_pages) + 1 end
    end)
    if #jas == 0 then
        row('  none learned for this job', nil)
    else
        local from = (ja_page - 1) * 6 + 1
        for i = from, math.min(#jas, from + 5) do
            local name = jas[i]
            local tp = api.ja_tp and api.ja_tp(name)
            local label = tp == nil and ('  - ' .. name) or ('  + ' .. name .. '  TP ' .. tostring(tp))
            row(label, function()
                if api.ja_cycle then api.ja_cycle(name) end
            end)
        end
    end

    if role == 'support' then
        row('Focus            ' .. (s.goal or 'damage'), function()
            s.goal = (s.goal == 'grind') and 'damage' or 'grind'
            api.save()
        end)
        row('Cast range       ' .. tostring(heal.cast_range or 20), function()
            heal.cast_range = cycle(RANGES, heal.cast_range or 20)
            api.save()
        end)
    end

    if role == 'healer' or role == 'mage' then
        if role == 'healer' then
            row('Focus            ' .. (s.goal or 'damage'), function()
                s.goal = (s.goal == 'grind') and 'damage' or 'grind'
                api.save()
            end)
            row('Enemy element    ' .. (s.enemy_element or 'Auto'), function()
                s.enemy_element = cycle(ENEMY_ELEMENTS, s.enemy_element or 'Auto')
                api.save()
            end)
            row('Cure             ' .. on(heal.cure ~= false), function()
                heal.cure = not (heal.cure ~= false)
                api.save()
            end)
            row('Cure below       ' .. tostring(heal.cure_hpp or 75) .. '%', function()
                heal.cure_hpp = cycle(CURE_HP, heal.cure_hpp or 75)
                api.save()
            end)
            row('Enhancing        ' .. on(heal.enhance ~= false), function()
                heal.enhance = not (heal.enhance ~= false)
                api.save()
            end)
        end
        row('Enfeeble         ' .. on(heal.enfeeble ~= false), function()
            heal.enfeeble = not (heal.enfeeble ~= false)
            api.save()
        end)
        row('Nuke             ' .. on(heal.nuke and true or false), function()
            heal.nuke = not heal.nuke
            api.save()
        end)
        row('Nuke element     ' .. (heal.element or 'Lightning'), function()
            heal.element = cycle(NUKE_ELEMENTS, heal.element or 'Lightning')
            api.save()
        end)
        row('MP reserve       ' .. tostring(heal.mp_reserve or 40) .. '%', function()
            heal.mp_reserve = cycle(RESERVES, heal.mp_reserve or 40)
            api.save()
        end)
        row('Cast range       ' .. tostring(heal.cast_range or 20), function()
            heal.cast_range = cycle(RANGES, heal.cast_range or 20)
            api.save()
        end)
    end

    if bard then
        local book = ensure_book(s)
        local page = SONG_PAGES[song_page] or 'base'
        local choices = (api.song_choices and api.song_choices()) or { '' }
        row('Songs            ' .. page, function()
            song_page = (song_page % #SONG_PAGES) + 1
        end)
        if page == 'base' then
            row('Base songs       ' .. tostring(book.count or 2), function()
                book.count = cycle({ 1, 2, 3, 4 }, book.count or 2)
                api.save()
            end)
            for i = 1, 4 do
                local name = book.base[i] or ''
                row('  Base ' .. tostring(i) .. '        ' .. song_label(name), function()
                    book.base[i] = cycle(choices, name)
                    api.save()
                end)
            end
        elseif page == 'dummy' then
            row('Dummy first      ' .. on(book.dummy_first), function()
                book.dummy_first = not book.dummy_first
                api.save()
            end)
            for i = 1, 3 do
                local name = book.dummy[i] or ''
                row('  Dummy ' .. tostring(i) .. '       ' .. song_label(name), function()
                    book.dummy[i] = cycle(choices, name)
                    api.save()
                end)
            end
        else
            local party = (api.party and api.party()) or { 'me' }
            for i = 1, 4 do
                local row_song = book.pia[i] or { name = '', target = 'me' }
                book.pia[i] = row_song
                row('  Pia ' .. tostring(i) .. '         ' .. song_label(row_song.name), function()
                    row_song.name = cycle(choices, row_song.name or '')
                    api.save()
                end)
                row('    for           ' .. (row_song.target or 'me'), function()
                    row_song.target = cycle(party, row_song.target or 'me')
                    api.save()
                end)
            end
        end
    end
end

local function add_scan_rows()
    if not api.scan_view then return end
    local shown, page, pages, note, scanning = api.scan_view()
    row(scanning and 'Scan map        ...' or 'Scan map', function()
        if api.scan_now then api.scan_now() end
    end)
    local going = (api.trip and api.trip()) or ''
    if going ~= '' then
        row('Warp to          ' .. going, function()
            if api.trip_clear then api.trip_clear() end
        end)
    end
    if pages > 1 then
        row('Scan page        ' .. tostring(page) .. '/' .. tostring(pages), function()
            if api.scan_page then api.scan_page() end
        end)
    end
    if note and note ~= '' then row('  ' .. note, nil) end
    for i = 1, #shown do
        local entry = shown[i]
        row(entry.label, function()
            if api.scan_go then api.scan_go(entry.n) end
        end)
    end
end

local function rebuild()
    rows = {}
    if not api then return end
    local s = api.settings()
    local heal = s.heal or {}
    local enabled = api.enabled()
    row('Running          ' .. on(enabled), function()
        api.set_enabled(not enabled)
    end)
    row('Tab               ' .. (panel == 'scan' and 'Scan' or 'Setup'), function()
        panel = (panel == 'scan') and 'setup' or 'scan'
    end)
    if panel == 'scan' then
        add_scan_rows()
        paint()
        return
    end
    row('Role             ' .. (s.role or 'dd'), function()
        s.role = cycle(ROLES, s.role)
        if s.role == 'mage' then
            s.heal = s.heal or {}
            s.heal.nuke = true
            if not s.heal.element or s.heal.element == 'Lightning' then
                s.heal.element = 'Burst'
            end
        end
        api.save()
    end)
    add_role_options(s, heal)
    local info = (api.detail and api.detail()) or ''
    if info ~= '' then row('\\cs(160,190,220)' .. info .. '\\cr', nil) end
    local note = api.notice() or ''
    if note ~= '' then row('\\cs(190,190,140)' .. note .. '\\cr', nil) end
    local known = api.summary() or ''
    if known ~= '' then row('\\cs(160,180,200)' .. known .. '\\cr', nil) end
    party_rows()
    paint()
end

local function place(x, y)
    if not title or not body then return end
    title:pos(x, y)
    local _, h = title:extents()
    body:pos(x, y + (h or 18) + 2)
end

local function save_pos()
    if not api or not title then return end
    local px, py = title:pos()
    local s = api.settings()
    if not s then return end
    px, py = math.floor(px + 0.5), math.floor(py + 0.5)
    if s.gui_x ~= px or s.gui_y ~= py then
        s.gui_x, s.gui_y = px, py
        api.save()
    end
end

local function over_panel(x, y)
    if title and title:visible() and title:hover(x, y) then return true end
    if body and body:visible() and body:hover(x, y) then return true end
    return false
end

local function hit(x, y)
    if not body or not body:visible() or not body:hover(x, y) then return nil end
    local _, y0 = body:pos()
    local _, h = body:extents()
    local n = #rows
    if not h or h <= 0 or n == 0 then return nil end
    local index = math.floor((y - y0) / (h / n)) + 1
    if index < 1 or index > n then return nil end
    return rows[index]
end

local function on_mouse(kind, x, y, _delta, blocked)
    if not body or not title then return end
    if kind == 0 and armed then
        if math.abs(x - down_x) >= 6 or math.abs(y - down_y) >= 6 then
            dragging = true
        end
        if dragging then
            place(x - drag_dx, y - drag_dy)
            return true
        end
    end
    if blocked and not armed then return end
    if kind == 1 and over_panel(x, y) then
        armed = true
        dragging = false
        down_x, down_y = x, y
        local px, py = title:pos()
        drag_dx, drag_dy = x - px, y - py
        return true
    elseif kind == 2 then
        local was = armed
        local moved = dragging
        armed = false
        dragging = false
        if was and not moved and body:hover(x, y) then
            local picked = hit(x, y)
            if picked and picked.fn then
                picked.fn()
                rebuild()
            end
        end
        if was and moved then save_pos() end
        if was then return true end
    end
end

function gui.init(callbacks)
    api = callbacks
    local s = api.settings()
    local x = tonumber(s.gui_x) or 40
    local y = tonumber(s.gui_y) or 60
    local style = {
        text = {
            font = 'Consolas',
            size = 12,
            stroke = { width = 1, alpha = 200, red = 0, green = 0, blue = 0 },
        },
        bg = { alpha = 170, red = 12, green = 16, blue = 28, visible = true },
        flags = { draggable = false },
        padding = 0,
    }
    title = texts.new('\\cs(220,210,160)autofight\\cr', {
        pos = { x = x, y = y },
        text = style.text,
        bg = style.bg,
        flags = { draggable = false },
        padding = 4,
    })
    body = texts.new('', {
        pos = { x = x, y = y + 24 },
        text = style.text,
        bg = style.bg,
        flags = { draggable = false },
        padding = 4,
    })
    title:show()
    body:show()
    windower.register_event('mouse', on_mouse)
    rebuild()
end

function gui.refresh()
    if body then rebuild() end
end

return gui
