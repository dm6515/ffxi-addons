local config = require('config')

-- Flat keys so the config library can round-trip them through data/settings.xml.
local defaults = {
    pos_x = 200,
    pos_y = 200,
    main_name = '',
    radius = 15,
    engage = false,
}

local settings = config.load(defaults)
local dirty = false
local last_flush = 0

local M = {}

function M.get()
    return settings
end

function M.main_name()
    local name = settings.main_name
    if type(name) ~= 'string' then
        return ''
    end
    return name
end

function M.radius()
    local radius = math.floor(tonumber(settings.radius) or 0)
    if radius < 0 then
        return 0
    end
    if radius > 100 then
        return 100
    end
    return radius
end

-- Only an actual boolean true enables combat. A bad settings value must not auto-attack.
function M.engage_on()
    return settings.engage == true
end

function M.flush()
    if dirty then
        settings:save()
        dirty = false
    end
end

function M.maybe_flush(now)
    if dirty and now - last_flush >= 0.5 then
        M.flush()
        last_flush = now
    end
end

local function save_now()
    dirty = false
    settings:save()
    last_flush = os.clock()
end

function M.set_main(name)
    name = name or ''
    if settings.main_name ~= name then
        settings.main_name = name
        save_now()
    end
end

function M.set_engage(on)
    on = on == true
    if settings.engage ~= on then
        settings.engage = on
        save_now()
    end
end

function M.set_radius(radius)
    radius = math.floor(tonumber(radius) or 0)
    if radius < 0 then
        radius = 0
    elseif radius > 100 then
        radius = 100
    end
    if settings.radius ~= radius then
        settings.radius = radius
        dirty = true
    end
end

function M.note_pos(x, y)
    x = math.floor((tonumber(x) or 0) + 0.5)
    y = math.floor((tonumber(y) or 0) + 0.5)
    if settings.pos_x ~= x or settings.pos_y ~= y then
        settings.pos_x = x
        settings.pos_y = y
        dirty = true
    end
end

return M
