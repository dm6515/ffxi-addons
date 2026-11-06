local imgui = require('imgui')
local settings = require('settings')
local party = require('party')
local engage = require('engage')

local ui = {}

local placed = false
local frames = 0
local seen_real = false
-- The imgui binding writes widget values back through a one-element table.
local engage_widget = { false }
local radius_widget = { 15 }

function ui.clamp_pos(x, y, w, h, screen_w, screen_h)
    local max_x = screen_w - w
    local max_y = screen_h - h
    if max_x < 0 then
        max_x = 0
    end
    if max_y < 0 then
        max_y = 0
    end
    local cx = x
    local cy = y
    if cx < 0 then
        cx = 0
    elseif cx > max_x then
        cx = max_x
    end
    if cy < 0 then
        cy = 0
    elseif cy > max_y then
        cy = max_y
    end
    return cx, cy
end

local function read_vec(a, b)
    if type(a) == 'table' then
        return a.x or a[1] or 0, a.y or a[2] or 0
    end
    return a or 0, b or 0
end

local function screen_size()
    local ws = windower.get_windower_settings()
    -- ImGui uses the UI coordinate space, which can differ from the 3D resolution.
    local w = ws and (ws.ui_x_res or ws.x_res) or 800
    local h = ws and (ws.ui_y_res or ws.y_res) or 600
    if type(w) ~= 'number' or w <= 0 then
        w = 800
    end
    if type(h) ~= 'number' or h <= 0 then
        h = 600
    end
    return w, h
end

local function hpp_text(hpp)
    if type(hpp) ~= 'number' then
        return '-'
    end
    return string.format('%d%%', hpp)
end

local function draw_party()
    local main = settings.main_name()
    if main == '' then
        imgui.Text('Main: (none)')
    else
        imgui.Text('Main: ' .. main)
    end
    imgui.Text(party.assist_text())

    local slots = party.slots()
    for i = 1, #slots do
        local slot = slots[i]
        if slot.name then
            local label = string.format('p%d  %s    HP %s    %s yalms    %s',
                slot.index,
                slot.name,
                hpp_text(slot.hpp),
                party.format_distance(slot.distance),
                party.status_name(slot.status))
            if imgui.RadioButton(label .. '##' .. slot.index, slot.name == main) then
                settings.set_main(slot.name)
            end
        else
            imgui.Text(string.format('p%d  (empty)', slot.index))
        end
    end
end

local function draw_engage()
    engage_widget[1] = settings.engage_on()
    radius_widget[1] = settings.radius()

    if imgui.Checkbox('Engage nearest enemy', engage_widget) then
        settings.set_engage(engage_widget[1] == true)
    end
    imgui.Text('Approach radius (yalms)')
    if imgui.SliderInt('##approach_radius', radius_widget, 0, 100) then
        settings.set_radius(radius_widget[1])
    end
    imgui.Text(engage.status())
end

function ui.draw(now)
    local saved = settings.get()
    if not placed then
        -- ImGuiCond_Always once, so a saved position wins over imgui.ini, then dragging works.
        imgui.SetNextWindowPos(saved.pos_x or 200, saved.pos_y or 200, 1)
        imgui.SetNextWindowSize(380, 280, 2)
        placed = true
    end

    local shown = imgui.Begin('Focus')
    if shown ~= false then
        if imgui.BeginTabBar('FocusTabs') then
            if imgui.BeginTabItem('Party') then
                draw_party()
                imgui.EndTabItem()
            end
            if imgui.BeginTabItem('Engage') then
                draw_engage()
                imgui.EndTabItem()
            end
            imgui.EndTabBar()
        end
    end

    local x, y = read_vec(imgui.GetWindowPos())
    local w, h = read_vec(imgui.GetWindowSize())
    local sw, sh = screen_size()
    local cx, cy = ui.clamp_pos(x, y, w, h, sw, sh)
    if math.abs(cx - x) > 0.5 or math.abs(cy - y) > 0.5 then
        imgui.SetWindowPos(cx, cy)
        x, y = cx, cy
    end
    frames = frames + 1
    if not seen_real then
        local dx = math.abs(x - (saved.pos_x or 200))
        local dy = math.abs(y - (saved.pos_y or 200))
        -- Ignore a stale 0,0 report before the first SetNextWindowPos has applied.
        if (dx < 2 and dy < 2) or frames > 30 then
            seen_real = true
        end
    end
    if seen_real then
        settings.note_pos(x, y)
    end
    imgui.End()
    settings.maybe_flush(now or 0)
end

function ui.flush()
    settings.flush()
end

return ui
