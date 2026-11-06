--[[
    Job ability levels for main job and sub job.
    Spells use the level table on the spell itself.
    A name that is not listed here is a custom ability and is left alone.
]]

local M = {}

local MAIN_ONLY = {
    benediction = true,
    manafont = true,
    ['mighty strikes'] = true,
    ['hundred fists'] = true,
    ['blood weapon'] = true,
    ['chainspell'] = true,
    ['perfect dodge'] = true,
    ['invincible'] = true,
    ['soul voice'] = true,
    ['eagle eye shot'] = true,
    ['meikyo shisui'] = true,
    ['mijin gakure'] = true,
    ['spirit surge'] = true,
    ['astral flow'] = true,
    ['azure lore'] = true,
    ['wild card'] = true,
    ['overdrive'] = true,
    trance = true,
    tabula = true,
    ['bolster'] = true,
    ['elemental sforzo'] = true,
}

-- Retail unlock level by job. Sub job is allowed when its level is high enough.
local LEVELS = {
    provoke = { WAR = 1 },
    berserk = { WAR = 15 },
    defender = { WAR = 25 },
    warcry = { WAR = 35 },
    aggressor = { WAR = 45 },
    boost = { MNK = 5 },
    dodge = { MNK = 15 },
    focus = { MNK = 25 },
    impetus = { MNK = 88 },
    ['divine seal'] = { WHM = 15 },
    ['afflatus solace'] = { WHM = 40 },
    devotion = { WHM = 40 },
    sacrosanctity = { WHM = 85 },
    asylum = { WHM = 96 },
    benediction = { WHM = 75 },
    manafont = { BLM = 75 },
    ['consume mana'] = { BLM = 55 },
    composure = { RDM = 25 },
    convert = { RDM = 40 },
    saboteur = { RDM = 75 },
    ['sneak attack'] = { THF = 15 },
    ['trick attack'] = { THF = 30 },
    ["assassin's charge"] = { THF = 75 },
    ['shield bash'] = { PLD = 15 },
    sentinel = { PLD = 30 },
    rampart = { PLD = 50 },
    majesty = { PLD = 70 },
    fealty = { PLD = 75 },
    palisade = { PLD = 85 },
    ['weapon bash'] = { DRK = 20 },
    ['last resort'] = { DRK = 15 },
    souleater = { DRK = 30 },
    ['killer instinct'] = { BST = 75 },
    marcato = { BRD = 25 },
    nightingale = { BRD = 75 },
    troubadour = { BRD = 75 },
    ['soul voice'] = { BRD = 75 },
    sharpshot = { RNG = 10 },
    barrage = { RNG = 30 },
    ['velocity shot'] = { RNG = 45 },
    ['double shot'] = { RNG = 75 },
    ['third eye'] = { SAM = 15 },
    hasso = { SAM = 25 },
    meditate = { SAM = 30 },
    seigan = { SAM = 35 },
    sekkanoki = { SAM = 40 },
    ['konzen-ittai'] = { SAM = 65 },
    sengikori = { SAM = 75 },
    yonin = { NIN = 40 },
    jump = { DRG = 10 },
    ['high jump'] = { DRG = 35 },
    ['super jump'] = { DRG = 50 },
    ['spirit surge'] = { DRG = 75 },
    ['spirit jump'] = { DRG = 75 },
    ['soul jump'] = { DRG = 85 },
    ['box step'] = { DNC = 10 },
    ['building flourish'] = { DNC = 40 },
    ['haste samba'] = { DNC = 45 },
    ['climactic flourish'] = { DNC = 80 },
    sublimation = { SCH = 35 },
    ["fighter's roll"] = { COR = 5 },
    ['chaos roll'] = { COR = 26 },
    ['samurai roll'] = { COR = 40 },
    ["evoker's roll"] = { COR = 49 },
    ['crooked cards'] = { COR = 95 },
    ['blaze of glory'] = { GEO = 60 },
    ignis = { RUN = 5 },
    gelus = { RUN = 5 },
    flabra = { RUN = 5 },
    tellus = { RUN = 5 },
    sulpor = { RUN = 5 },
    unda = { RUN = 5 },
    lux = { RUN = 5 },
    tenebrae = { RUN = 5 },
    vallation = { RUN = 10 },
    swordplay = { RUN = 25 },
    pflug = { RUN = 40 },
    valiance = { RUN = 50 },
    gambit = { RUN = 70 },
    battuta = { RUN = 70 },
    rayke = { RUN = 75 },
    ['one for all'] = { RUN = 95 },
}

function M.allows(player, name)
    if not player or type(name) ~= 'string' or name == '' then return false end
    local rule = LEVELS[name:lower()]
    if not rule then return true end
    local function meets(job, level)
        local need = job and rule[job]
        return need ~= nil and level ~= nil and level >= need
    end
    if MAIN_ONLY[name:lower()] then
        return meets(player.main_job, player.main_job_level)
    end
    if meets(player.main_job, player.main_job_level) then return true end
    if meets(player.sub_job, player.sub_job_level) then return true end
    return false
end

return M
