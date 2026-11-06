local travel = {}

-- Seconds of almost no movement before the unstuck sequence starts.
travel.STUCK_TIME = 2
-- Yalms. Below this, the character is treated as not actually moving.
travel.STUCK_MOVE = 0.25
travel.PHASE_TIME = 0.7
-- Pause after strafe / backup / new heading so the sequence cannot spin forever.
travel.COOLDOWN = 2.5

function travel.new_state()
    return {
        phase = 'approach',
        anchor_x = nil,
        anchor_y = nil,
        anchor_time = 0,
        phase_until = 0,
        cooldown_until = 0,
        side = 1,
        heading_offset = 0,
        running = false,
    }
end

local state = travel.new_state()

local function advance_timed(now)
    for _ = 1, 4 do
        if state.phase == 'strafe' and now >= state.phase_until then
            state.phase = 'backup'
            state.phase_until = now + travel.PHASE_TIME
        elseif state.phase == 'backup' and now >= state.phase_until then
            state.phase = 'heading'
            state.phase_until = now + travel.PHASE_TIME
            state.heading_offset = state.side * (math.pi / 3)
        elseif state.phase == 'heading' and now >= state.phase_until then
            state.phase = 'cooldown'
            state.cooldown_until = now + travel.COOLDOWN
            state.anchor_x = nil
            state.anchor_y = nil
        else
            return
        end
    end
end

-- Absolute heading in radians: 0 is east, increasing counterclockwise (atan2(dy, dx)).
function travel.heading_for(x, y, tx, ty, now)
    local toward = math.atan2(ty - y, tx - x)
    advance_timed(now)

    if state.phase == 'strafe' then
        return toward + state.side * (math.pi / 2)
    elseif state.phase == 'backup' then
        return toward + math.pi
    elseif state.phase == 'heading' then
        return toward + state.heading_offset
    end

    if state.phase == 'cooldown' and now >= state.cooldown_until then
        state.phase = 'approach'
        state.anchor_x = nil
        state.anchor_y = nil
    end

    if state.anchor_x == nil then
        state.anchor_x = x
        state.anchor_y = y
        state.anchor_time = now
    else
        local dx = x - state.anchor_x
        local dy = y - state.anchor_y
        local moved = math.sqrt(dx * dx + dy * dy)
        if moved >= travel.STUCK_MOVE then
            state.anchor_x = x
            state.anchor_y = y
            state.anchor_time = now
        elseif state.phase == 'approach' and now >= state.cooldown_until
            and now - state.anchor_time >= travel.STUCK_TIME then
            state.side = -state.side
            state.phase = 'strafe'
            state.phase_until = now + travel.PHASE_TIME
            return toward + state.side * (math.pi / 2)
        end
    end

    return toward
end

function travel.phase()
    return state.phase
end

function travel.toward(tx, ty, now)
    local me = windower.ffxi.get_mob_by_target('me')
    if not me or tx == nil or ty == nil then
        travel.release()
        return
    end
    -- run() latches until run(false). Radians use the same axis as entity x/y.
    local heading = travel.heading_for(me.x, me.y, tx, ty, now)
    windower.ffxi.run(heading)
    state.running = true
end

function travel.release()
    if state.running then
        windower.ffxi.run(false)
    end
    state = travel.new_state()
end

function travel.force_release()
    windower.ffxi.run(false)
    state = travel.new_state()
end

-- Test hook. Replaces the live state with a fresh one.
function travel._reset()
    state = travel.new_state()
end

return travel
