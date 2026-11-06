_addon.name = 'Focus'
_addon.author = 'Project Tako'
_addon.version = '1.0'

-- Resolve sibling modules from this addon folder before Windower libs.
local root = windower.addon_path or ''
local tail = root:sub(-1)
if tail ~= '/' and tail ~= '\\' then
    root = root .. '/'
end
package.path = root .. '?.lua;' .. package.path

local settings = require('settings')
local travel = require('travel')
local party = require('party')
local engage = require('engage')
local ui = require('ui')

local next_logic = 0

windower.register_event('prerender', function()
    local now = os.clock()
    if now >= next_logic then
        next_logic = now + 0.1
        local info = windower.ffxi.get_info()
        if type(info) ~= 'table' or not info.logged_in then
            travel.release()
        else
            engage.tick(now, settings.engage_on())
            party.assist(now)
        end
    end
    ui.draw(now)
end)

windower.register_event('zone change', function()
    travel.release()
    engage.clear()
end)

windower.register_event('unload', function()
    travel.force_release()
    ui.flush()
end)
