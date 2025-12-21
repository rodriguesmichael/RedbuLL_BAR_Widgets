function widget:GetInfo()
    return {
        name    = "PauseOnAllyDamage",
        desc    = "Pauses if allied units are reclaimed, dgunned, or mass self-destructed",
        author  = "refactor by Color",
        date    = "2025-09-29",
        license = "secret tech",
        layer   = 0,
        enabled = true
        -- Original concept/code by kroIya
        -- Portions adapted from game_selfd_resign
        -- Options system adapted from CMDR*Zod's "Player Logos" widget
    }
end

-- =========================
-- ⚙️  Options & Settings
-- =========================

local config = {
    widgetenabled  = true,
    messageOnPing  = false,
    enableReclaim  = true,
    enableDGun     = true,
    enableSelfD    = true,
    cooldown       = 0,
    enablePlayerSelect = true,
}
local OPTION_SPECS = {
    {
        configVariable = "widgetenabled",
        name = "temp disable",
        description = "Will reenable next game: RIGHT = Enabled",
        type = "bool",
    },
    {
        configVariable = "messageOnPing",
        name = "Message On Ping",
        description = "Put reason text on ping instead of chat.",
        type = "bool",
        persist = true,
    },
    {
        configVariable = "enableReclaim",
        name = "Enable Reclaim",
        description = "Monitor reclaim events.",
        type = "bool",
    },
    {
        configVariable = "enableDGun",
        name = "Enable DGun",
        description = "Monitor DGUN events.",
        type = "bool",
    },
    {
        configVariable = "enableSelfD",
        name = "Enable SelfD",
        description = "Monitor SelfD events.",
        type = "bool",
    },
    {
        configVariable = "cooldown",
        name = "Event Cooldown",
        description = "Minimum time in seconds between repeated alerts of the same type.",
        type = "slider",
        min = 0,
        max = 10,
        step = 1,
        persist = true,
    },
    {
        configVariable = "enablePlayerSelect",
        name = "Ping to Select Player for watch",
        description = "Ping again to return to multi-watch mode.",
        type = "bool",
        persist = true,
    },
}

function widget:GetConfigData()
    local result = {}
    for _, option in ipairs(OPTION_SPECS) do
        if option.persist then
            result[option.configVariable] = config[option.configVariable]
        end
    end
    return result
end

function widget:SetConfigData(data)
    for _, option in ipairs(OPTION_SPECS) do
        if option.persist and data[option.configVariable] ~= nil then
            config[option.configVariable] = data[option.configVariable]
        end
    end
end

local function getOptionId(optionSpec)
    return "PauseOnAllyDamage__" .. optionSpec.configVariable
end

local function getOptionValue(optionSpec)
    return config[optionSpec.configVariable]
end

local function setOptionValue(optionSpec, value)
    config[optionSpec.configVariable] = value
end

local function createOnChange(optionSpec)
    return function(_, value)
        setOptionValue(optionSpec, value)
    end
end

local function createOptionFromSpec(optionSpec)
    local option = table.copy(optionSpec)
    option.id = getOptionId(optionSpec)
    option.widgetname = widget:GetInfo().name
    option.value = getOptionValue(optionSpec)
    option.onchange = createOnChange(optionSpec)
    return option
end

-- =========================
-- 🌐 Widget State
-- =========================
local pingCooldown = false
local thresholdPercentage = 0.5
local selfdCheckTeams = {}
local DGUN_RANGE = 280 --280
local DGUN_WIDTH = 60  -- 60 approximate beam "thickness" for ally collision
local THIRTY_MINUTES = 30 * 60 * 30  -- 54,000 frames at 30fps
local lastEventTime = {}
local selectedPlayerID = nil  -- nil means "watch all players"
local myPlayerID = Spring.GetMyPlayerID()
local myMarkers = {}

-- =========================
-- 🔎 Identity & Relationship
-- =========================
local function GetAllyTeamID(teamID)
    local _, _, _, _, _, allyTeamID = Spring.GetTeamInfo(teamID)
    return allyTeamID
end

local function AreAllied(teamA, teamB)
    return GetAllyTeamID(teamA) == GetAllyTeamID(teamB)
end

local function GetPlayerName(teamID)
    if not teamID then return "?" end
    local leader = select(2, Spring.GetTeamInfo(teamID)) -- 2nd return is leader playerID
    if leader then
        local name = Spring.GetPlayerInfo(leader)
        return name or ("Team" .. teamID)
    end
    return "Team" .. teamID
end

local function findClosestPlayer(px, pz, radius)
    local bestDist, bestPlayer = math.huge, nil
    local gaiaTeamID = Spring.GetGaiaTeamID()
    radius = radius or 300

    -- only units in a 300 radius cylinder around the ping
    for _, unitID in ipairs(Spring.GetUnitsInCylinder(px, pz, radius)) do
        local teamID = Spring.GetUnitTeam(unitID)
        if teamID ~= gaiaTeamID then
            local ux, uy, uz = Spring.GetUnitPosition(unitID)
            local dx, dz = ux - px, uz - pz
            local distSq = dx*dx + dz*dz
            if distSq < bestDist then
                bestDist = distSq
                local players = Spring.GetPlayerList(teamID, true)
                if #players > 0 then
                    bestPlayer = players[1]
                end
            end
        end
    end

    if bestPlayer then
        return bestPlayer, math.sqrt(bestDist)
    end
end

local function shouldWatch(playerID)
    return (selectedPlayerID == nil) or (playerID == selectedPlayerID)
end

-- =========================
-- ⚙️ Event Context
-- =========================

local function canTrigger(eventKey)
    local now = Spring.GetGameSeconds()
    if not lastEventTime[eventKey] or (now - lastEventTime[eventKey]) >= config.cooldown then
        lastEventTime[eventKey] = now
        return true
    end
    return false
end

local function IsReclaimingAlly(actorTeamID, cmdParams)
    local targetID = cmdParams[1]
    if not targetID or targetID <= 0 then return false end

    local targetTeamID = Spring.GetUnitTeam(targetID)
    if not targetTeamID then return false end

    -- true if reclaiming an ally’s unit (but not your own)
    return AreAllied(actorTeamID, targetTeamID) and actorTeamID ~= targetTeamID, targetID
end

local explosiveUnits = {
    armafus = true, corafus = true, legafus = true,
    armfus  = true, corfus  = true, legfus  = true,
    armuwfus= true, coruwfus= true, armckfus= true,
    armsilo = true, corsilo = true, legsilo = true,
}

local ignoreUnits = {
    armflea = true, armfav = true, corfav = true, legscout = true, leggob = true,
    cordrag = true, armdrag = true, legdrag = true,   -- dragon’s teeth
    corfort = true, armfort = true, legforti = true,  -- fortification walls
    -- add any other “don’t care” units here
}

local function CheckNearbyAllies(commID, radius)
    local ux, uy, uz = Spring.GetUnitPosition(commID)
    local teamID = Spring.GetUnitTeam(commID)
    local allyTeam = GetAllyTeamID(teamID)

    local nearby = Spring.GetUnitsInSphere(ux, uy, uz, radius)
    local count, explosive, commander = 0, false, false
    local closestDistSq, markerX, markerY, markerZ = math.huge, nil, nil, nil

    for _, uID in ipairs(nearby) do
        local tID = Spring.GetUnitTeam(uID)
        if AreAllied(teamID, tID) and uID ~= commID and teamID ~= tID then
            local defID = Spring.GetUnitDefID(uID)
            if defID then
                local def = UnitDefs[defID]
                -- skip ignored units
                if def and not ignoreUnits[def.name] then
                    count = count + 1

                    -- distance squared to commander
                    local x, y, z = Spring.GetUnitPosition(uID)
                    if x then
                        local dx, dz = x - ux, z - uz
                        local distSq = dx*dx + dz*dz
                        if distSq < closestDistSq then
                            closestDistSq = distSq
                            markerX, markerY, markerZ = x, y, z
                        end
                    end

                    if def.customParams and def.customParams.iscommander then
                        commander = true
                    end
                    if explosiveUnits[def.name] then
                        explosive = true
                    end
                end
            end
        end
    end

    -- If no allies found, fall back to commander’s own position
    return explosive, commander, count, markerX or ux, markerY or uy, markerZ or uz
end

local function GetSelfDMarkerPos(teamID)
    local units = Spring.GetTeamUnits(teamID)
    local buckets = {}
    local bucketSize = 500  -- grid size in elmos, tweak to taste

    for i=1,#units do
        local uID = units[i]
        if Spring.GetUnitSelfDTime(uID) > 0 then
            local uDefID = Spring.GetUnitDefID(uID)
            if uDefID and explosiveUnits[UnitDefs[uDefID].name] then
                -- immediately mark explosive unit
                return Spring.GetUnitPosition(uID)
            end
            local x,y,z = Spring.GetUnitPosition(uID)
            if x then
                local bx = math.floor(x/bucketSize)
                local bz = math.floor(z/bucketSize)
                local key = bx..":"..bz
                local b = buckets[key] or {sumx=0,sumy=0,sumz=0,count=0}
                b.sumx, b.sumy, b.sumz, b.count = b.sumx+x, b.sumy+y, b.sumz+z, b.count+1
                buckets[key] = b
            end
        end
    end

    -- pick the largest bucket
    local best
    for _,b in pairs(buckets) do
        if not best or b.count > best.count then best = b end
    end
    if best then
        return best.sumx/best.count, best.sumy/best.count, best.sumz/best.count
    end
    return nil
end

local function AnalyzeSelfD(teamID, threshold, radius, allyThreshold)
    local units = Spring.GetTeamUnits(teamID)
    local unitCount = #units
    if unitCount == 0 then return false end

    local triggerCount = math.ceil(unitCount * threshold)
    local selfdCount = 0
    local criticalDetected = false

    local commanderID
    for i=1, unitCount do
        local uID = units[i]
        if Spring.GetUnitSelfDTime(uID) > 0 then
            selfdCount = selfdCount + 1
            local uDefID = Spring.GetUnitDefID(uID)
            if uDefID then
                local uDef = UnitDefs[uDefID]
                if explosiveUnits[uDef.name] then
                    criticalDetected = true
                end
                if not commanderID and uDef.customParams and uDef.customParams.iscommander then
                    commanderID = uID
                end
            end
        end
    end

    -- mass self-D check
    if criticalDetected or (selfdCount >= triggerCount) then
        return "mass", GetSelfDMarkerPos(teamID)
    end

    -- commander heuristic check (only if not mass)
    if commanderID then
        local explosive, commander, count, x,y,z = CheckNearbyAllies(commanderID, radius)
        if explosive or commander or count >= allyThreshold then
            return "commander", x,y,z
        end
    end

    return false
end




-- =========================
-- 🛠 Utility
-- =========================
local function MarkAndPause(x, y, z, reason)
    myMarkers[x..":"..z] = true
    if config.messageOnPing then
        Spring.SendCommands("pause")
        if x and y and z then
            Spring.MarkerAddPoint(x, y, z, reason or "")
        elseif reason then
            Spring.SendCommands("say " .. reason)
        end
    else
        Spring.SendCommands("pause")
        if x and y and z then
            Spring.MarkerAddPoint(x, y, z, "")
        end
        if reason then
            Spring.SendCommands("say " .. reason)
        end
    end
end

-- helper: distance from point to line segment
local function DistPointToSegment(px, py, pz, ax, ay, az, bx, by, bz)
    local vx, vy, vz = bx - ax, by - ay, bz - az
    local wx, wy, wz = px - ax, py - ay, pz - az
    local c1 = vx*wx + vy*wy + vz*wz
    if c1 <= 0 then
        return math.sqrt(wx*wx + wy*wy + wz*wz)
    end
    local c2 = vx*vx + vy*vy + vz*vz
    if c2 <= c1 then
        local dx, dy, dz = px - bx, py - by, pz - bz
        return math.sqrt(dx*dx + dy*dy + dz*dz)
    end
    local b = c1 / c2
    local bx2, by2, bz2 = ax + b*vx, ay + b*vy, az + b*vz
    local dx, dy, dz = px - bx2, py - by2, pz - bz2
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- =========================
-- 🚦 Event Handlers
-- =========================
function widget:Initialize()
    if not Spring.IsReplay() then
        widgetHandler:RemoveWidget()
        return
    end
    if WG['options'] then
        WG['options'].addOptions(table.map(OPTION_SPECS, createOptionFromSpec))
    end
end

function widget:Shutdown()
    if WG['options'] then
        WG['options'].removeOptions(table.map(OPTION_SPECS, getOptionId))
    end
end

function widget:MapDrawCmd(playerID, cmdType, px, py, pz, label)
    local key = px..":"..pz
    if myMarkers[key] then
        myMarkers[key] = nil
        return -- ignore my own marker
    end
    if not config.widgetenabled then return end    -- skip if widget is disabled
    if not config.enablePlayerSelect then return end -- skip if feature is off
    if playerID ~= myPlayerID then return end
    if label and label ~= "" then return end  -- only blank pings

    -- Find nearest player to ping (within 300)
    local pid = findClosestPlayer(px, pz, 300)
    if not pid then
        Spring.Echo("No player units near ping")
        return
    end

    if selectedPlayerID == pid then
        -- toggle back to default
        selectedPlayerID = nil
        Spring.Echo("Now watching ALL players")
    else
        -- set new selection
        selectedPlayerID = pid
        local name = Spring.GetPlayerInfo(pid)
        Spring.Echo("Now watching ONLY:", name)
    end
end

function widget:UnitCommand(unitID, unitDefID, teamID, cmdID, cmdParams, cmdOptions)
    if not config.widgetenabled then return end
    -- skip if we're in "single-player watch" mode and this isn't them
    if selectedPlayerID and teamID ~= selectedPlayerID then return end
    local _, _, _, isAI = Spring.GetTeamInfo(teamID)
    if isAI then return end

    if cmdID == CMD.SELFD and config.enableSelfD then
        selfdCheckTeams[teamID] = true
    end
    if cmdID == CMD.RECLAIM and config.enableReclaim then
        local relation, x, y, z, unitName, targetTeamID

        if #cmdParams == 1 then
            -- single target: unit (>0) or feature (<0)
            local targetID = cmdParams[1]
            if targetID > 0 and Spring.ValidUnitID(targetID) then
                targetTeamID = Spring.GetUnitTeam(targetID)
                if targetTeamID then
                    if teamID == targetTeamID then
                        relation = "self"
                    elseif AreAllied(teamID, targetTeamID) then
                        relation = "ally"
                    else
                        relation = "enemy"
                    end
                end
                x, y, z = Spring.GetUnitPosition(targetID)
                local uDefID = Spring.GetUnitDefID(targetID)
                if uDefID then
                    local uDef = UnitDefs[uDefID]
                    unitName = uDef.translatedHumanName
                end
            elseif targetID < 0 then
                -- feature reclaim, skip or log separately
                relation = "feature"
                local fDefID = Spring.GetFeatureDefID(-targetID)
                if fDefID then
                    unitName = FeatureDefs[fDefID].description
                end
            end

        elseif #cmdParams == 4 then
            -- area reclaim, not a specific unit
            relation = "area"
            x, y, z = cmdParams[1], cmdParams[2], cmdParams[3]
            unitName = "area radius " .. tostring(cmdParams[4])
        end

        -- 🔧 Switch which relations you want to test
        if not pingCooldown and (relation == "ally") then
            local actorName  = GetPlayerName(teamID)
            local targetName = targetTeamID and GetPlayerName(targetTeamID) or "?"

            -- build a unique key per actor + event type
            local eventKey = "reclaim_" .. tostring(teamID)

            if canTrigger(eventKey) then
                local msg = string.format(
                    "Reclaim cmd: %s | %s reclaiming %s’s %s",
                    relation, actorName, targetName, unitName or "?"
                )
                MarkAndPause(x, y, z, msg)
            end
            pingCooldown = true
        end
    end
    if cmdID == CMD.DGUN and config.enableDGun then
        local uDef = UnitDefs[unitDefID]
        if uDef and uDef.customParams and uDef.customParams.iscommander then
            local ux, uy, uz = Spring.GetUnitPosition(unitID)
            if not (ux and cmdParams[1]) then return end

            -- target point: either click coords or target unit position
            local tx, ty, tz
            if #cmdParams >= 3 then
                tx, ty, tz = cmdParams[1], cmdParams[2], cmdParams[3]
            elseif #cmdParams == 1 and cmdParams[1] > 0 then
                tx, ty, tz = Spring.GetUnitPosition(cmdParams[1])
            end
            if not tx then return end

            -- always extend to full DGUN range
            local dx, dy, dz = tx - ux, ty - uy, tz - uz
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dist == 0 then dist = 1 end
            local scale = DGUN_RANGE / dist
            local ex, ey, ez = ux + dx*scale, uy + dy*scale, uz + dz*scale

            -- bounding box around beam segment
            local minx = math.min(ux, ex) - DGUN_WIDTH
            local maxx = math.max(ux, ex) + DGUN_WIDTH
            local miny = math.min(uy, ey) - DGUN_WIDTH
            local maxy = math.max(uy, ey) + DGUN_WIDTH
            local minz = math.min(uz, ez) - DGUN_WIDTH
            local maxz = math.max(uz, ez) + DGUN_WIDTH

            local candidates = Spring.GetUnitsInBox(minx, miny, minz, maxx, maxy, maxz)
            local myAllyTeam = GetAllyTeamID(teamID)
            --Spring.Echo("DGUN candidates:", #candidates)
            for _, aID in ipairs(candidates) do
                local aTeam = Spring.GetUnitTeam(aID)
                if aTeam and GetAllyTeamID(aTeam) == myAllyTeam and aTeam ~= teamID then
                    local uDefID = Spring.GetUnitDefID(aID)
                    local def = uDefID and UnitDefs[uDefID]
                    if def and not ignoreUnits[def.name] then
                        local ax, ay, az = Spring.GetUnitPosition(aID)
                        local d = DistPointToSegment(ax, ay, az, ux, uy, uz, ex, ey, ez)
                        if d < DGUN_WIDTH then
                            local actorName  = GetPlayerName(teamID)
                            local targetName = GetPlayerName(aTeam)
                            local unitName = def.translatedHumanName or def.name
                            local msg = string.format(
                                "DGUN path intersects ally: %s firing near %s’s %s",
                                actorName, targetName, unitName
                            )
                            MarkAndPause(ax, ay, az, msg)
                            break
                        end
                    end
                end
            end
        end
    end
end


function widget:GameFrame(frameNum)
    pingCooldown = false

    if frameNum % 15 == 1 then
        for teamID in pairs(selfdCheckTeams) do
            local kind, x,y,z = AnalyzeSelfD(teamID, thresholdPercentage, 400, 4)
            if kind == "mass" then
                local msg = GetPlayerName(teamID) .. " is mass self-destructing"
                MarkAndPause(x,y,z,msg)
                pingCooldown = true
            elseif kind == "commander" then
                local msg = GetPlayerName(teamID) .. " Com self-D near allies!"
                MarkAndPause(x,y,z,msg)
                pingCooldown = true
            -- 🔔 Global safeguard after 30 minutes
            elseif frameNum > THIRTY_MINUTES then
                local msg = "⚠️ Self-D detected after 30 minutes: " .. GetPlayerName(teamID)
                Spring.SendCommands("pause")
                Spring.SendCommands("say " .. msg)
            end
        end
        selfdCheckTeams = {}
    end
end
