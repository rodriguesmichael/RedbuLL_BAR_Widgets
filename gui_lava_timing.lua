local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Lava Timings",
		desc = "Displays the countdown for the next Lava Tide movement",
		author = "[Crd]RedbuLL - Creed of Champion",
		date = "2025-11-13",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
	}
end

local glColor = gl.Color
local glRect = gl.Rect
local glText = gl.Text
local floor = math.floor
local abs = math.abs

local spGetGameRulesParam = Spring.GetGameRulesParam

local vsx, vsy = Spring.GetViewGeometry()
local uiScale = 1

local basePanelWidth = 134
local basePanelHeight = 60
local baseMargin = 12

local panelWidth, panelHeight, margin

local FRAMES_PER_SECOND = 30
local tideRhythm = {}
local currentPhase = "Waiting"
local timeLeftSeconds = nil
local hasLava = false
local highLevel = nil
local lowLevel = nil
local realLevel = nil
local realLevelFrame = nil
local realGrow = nil

-- Simulation state mirroring gadget logic
local simFrame = 0
local simTideIndex = 1
local simTideContinueFrame = 0
local simLavaLevel = 0
local simLavaGrow = 0

local function classifyLevel(level)
	if not highLevel or not lowLevel then
		return "TIDE"
	end
	if abs(level - highLevel) < 0.1 then
		return "HIGH"
	elseif abs(level - lowLevel) < 0.1 then
		return "LOW"
	end
	return "LEVEL"
end

local function formatTime(seconds)
	if not seconds then
		return "--:--"
	end
	local s = math.max(0, floor(seconds + 0.5))
	local minutes = floor(s / 60)
	local secs = s % 60
	return string.format("%02d:%02d", minutes, secs)
end

local function determineColor(seconds)
	if not seconds then
		return 0.8, 0.8, 0.8, 1
	end
	if seconds > 30 then
		return 0.3, 1.0, 0.3, 1
	elseif seconds >= 20 then
		return 1.0, 0.85, 0.2, 1
	else
		local blink = math.abs(math.sin((Spring.GetGameSeconds() or (Spring.GetGameFrame() / FRAMES_PER_SECOND)) * 5))
		return 1.0, 0.3, 0.3, 0.5 + 0.5 * blink
	end
end

local function advanceSimulationFrame()
	if #tideRhythm == 0 then
		return
	end
	local entry = tideRhythm[simTideIndex]
	if entry then
		if (simLavaGrow < 0 and simLavaLevel < entry.targetLevel)
			or (simLavaGrow > 0 and simLavaLevel > entry.targetLevel) then
			local remain = entry.remainTime or 0
			simTideContinueFrame = simFrame + remain * FRAMES_PER_SECOND
			simLavaGrow = 0
		end
	end

	if simFrame == simTideContinueFrame then
		simTideIndex = simTideIndex + 1
		if simTideIndex > #tideRhythm then
			simTideIndex = 1
		end
		entry = tideRhythm[simTideIndex]
		if entry then
			if simLavaLevel < entry.targetLevel then
				simLavaGrow = entry.speed or 0
			else
				simLavaGrow = -(entry.speed or 0)
			end
		else
			simLavaGrow = 0
		end
	end

	simLavaLevel = simLavaLevel + simLavaGrow
end

local function simulateTo(frame)
	if frame <= simFrame then
		return
	end
	for f = simFrame + 1, frame do
		simFrame = f
		advanceSimulationFrame()
	end
end

local function setupLavaData()
	local lava = Spring.Lava
	if not (lava and lava.isLavaMap and lava.tideRhythm and #lava.tideRhythm > 0) then
		return false
	end

	tideRhythm = {}
	for _, rhythm in ipairs(lava.tideRhythm) do
		local target = rhythm.targetLevel or rhythm[1]
		local speed = rhythm.speed or rhythm[2]
		local dwell = rhythm.remainTime or rhythm[3] or 0
		if target and speed then
			table.insert(tideRhythm, {
				targetLevel = target,
				speed = math.abs(speed),
				remainTime = dwell,
			})
		end
	end

	if #tideRhythm == 0 then
		return false
	end

	highLevel, lowLevel = nil, nil
	for _, entry in ipairs(tideRhythm) do
		if not highLevel or entry.targetLevel > highLevel then
			highLevel = entry.targetLevel
		end
		if not lowLevel or entry.targetLevel < lowLevel then
			lowLevel = entry.targetLevel
		end
	end

	simLavaLevel = lava.level or 0
	simLavaGrow = lava.grow or 0
	simTideIndex = 1
	simTideContinueFrame = 0
	simFrame = 0
	currentPhase = "Waiting"
	timeLeftSeconds = nil
	hasLava = true
	realLevel = nil
	realGrow = nil
	realLevelFrame = nil
	simulateTo(Spring.GetGameFrame())
	return true
end

function widget:ViewResize()
	vsx, vsy = Spring.GetViewGeometry()
	uiScale = vsy / 1080
	panelWidth = basePanelWidth * uiScale
	panelHeight = basePanelHeight * uiScale
	margin = baseMargin * uiScale
end

function widget:Initialize()
	self:ViewResize()
	if setupLavaData() then
		simulateTo(Spring.GetGameFrame())
	end
end

function widget:GameFrame(frame)
	if not hasLava then
		if not setupLavaData() then
			return
		end
	end
	if #tideRhythm == 0 then
		timeLeftSeconds = nil
		currentPhase = "Waiting"
		return
	end

	local levelGRP = spGetGameRulesParam and spGetGameRulesParam("lavaLevel")
	if levelGRP and levelGRP ~= -99999 then
		if realLevel and realLevelFrame and frame > realLevelFrame then
			local delta = levelGRP - realLevel
			realGrow = delta / (frame - realLevelFrame)
		end
		realLevel = levelGRP
		realLevelFrame = frame
		simLavaLevel = levelGRP
	end
	local growGRP = SYNCED and SYNCED.lavaGrow
	if growGRP ~= nil then
		simLavaGrow = growGRP
		realGrow = growGRP
	end

	simulateTo(frame)

	local entry = tideRhythm[simTideIndex]
	if not entry then
		timeLeftSeconds = nil
		currentPhase = "Waiting"
		return
	end

	local epsilon = 1e-5
	if math.abs(simLavaGrow) > epsilon or (realGrow and math.abs(realGrow) > epsilon) then
		local targetLevel = entry.targetLevel or simLavaLevel
		local levelForDiff = realLevel or simLavaLevel
		local diff = math.max(0, math.abs(targetLevel - levelForDiff))
		local perFrame = math.max(math.abs(realGrow or simLavaGrow), epsilon)
		timeLeftSeconds = (diff / perFrame) / FRAMES_PER_SECOND
		local growForPhase = realGrow or simLavaGrow
		currentPhase = (growForPhase > 0 and "Rising to " or "Dropping to ") .. classifyLevel(targetLevel)
	else
		local framesLeft = math.max(0, simTideContinueFrame - simFrame)
		timeLeftSeconds = framesLeft / FRAMES_PER_SECOND
		local levelForPhase = realLevel or simLavaLevel
		currentPhase = classifyLevel(entry.targetLevel or levelForPhase) .. " (hold)"
	end
end

function widget:DrawScreen()
	if not hasLava or not timeLeftSeconds then
		return
	end

	local x1 = vsx - panelWidth - margin
	local y1 = vsy - panelHeight - margin
	local x2 = x1 + panelWidth
	local y2 = y1 + panelHeight

	glColor(0, 0, 0, 0.4)
	glRect(x1, y1, x2, y2)

	glColor(1, 1, 1, 1)
	glText("Lava Status", x1 + (10 * uiScale), y2 - (18 * uiScale), 14 * uiScale, "o")

	local r, g, b, a = determineColor(timeLeftSeconds)
	glColor(r, g, b, a)
	glText(currentPhase, x1 + (10 * uiScale), y2 - (31 * uiScale), 14 * uiScale, "o")
	glText(formatTime(timeLeftSeconds), x1 + (10 * uiScale), y1 + (8 * uiScale), 24 * uiScale, "o")

	glColor(1, 1, 1, 1)
end
