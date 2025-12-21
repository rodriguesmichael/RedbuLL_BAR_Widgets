function widget:GetInfo()
  return {
    name    = "Construction Monitor",
    desc    = "Monitora construções ativas e consumo de recursos",
    author = "RedbuLL86 - Discord",
    date = "2025-11-24",
    license = "GNU GPL, v2 or later",
    layer   = 0,
    enabled = true
  }
end

local vsx, vsy = Spring.GetViewGeometry()
local uiScale = 1

-- Configuração Visual
local panelWidth = 220
local itemHeight = 20
local margin = 12
local fontSize = 14

-- Dados
local activeConstructions = {}
local myTeamID = Spring.GetMyTeamID()

function widget:ViewResize()
  vsx, vsy = Spring.GetViewGeometry()
  uiScale = vsy / 1080
  -- Recalcula tamanhos baseados na escala
  panelWidth = 250 * uiScale
  itemHeight = 25 * uiScale
  margin = 12 * uiScale
  fontSize = 14 * uiScale
end

function widget:Initialize()
  widget:ViewResize()
  Spring.Echo("Construction Monitor: Loaded!")
end

function widget:GameFrame(n)
  -- Atualiza a cada 15 frames (0.5s) para não ficar muito pesado
  if (n % 15 == 0) then
      activeConstructions = {}
      local units = Spring.GetTeamUnits(myTeamID)
      
      -- 1. Identificar quem está construindo o quê
      local targetBPs = {} -- targetID -> totalBP
      
      for _, unitID in ipairs(units) do
          -- Verifica se a unidade está construindo algo (nanos, coms, factories)
          local bQueue = Spring.GetUnitIsBuilding(unitID)
          if bQueue then
              local ud = UnitDefs[Spring.GetUnitDefID(unitID)]
              if ud then
                  local bp = ud.buildSpeed
                  targetBPs[bQueue] = (targetBPs[bQueue] or 0) + bp
              end
          end
      end
      
      -- 2. Calcular dados das construções
      for targetID, totalBP in pairs(targetBPs) do
          local targetDefID = Spring.GetUnitDefID(targetID)
          if targetDefID then
              local ud = UnitDefs[targetDefID]
              
              -- Formula: Drain = (Cost / BuildTime) * AppliedBP
              local metalDrain = (ud.metalCost / ud.buildTime) * totalBP
              local energyDrain = (ud.energyCost / ud.buildTime) * totalBP
              
              table.insert(activeConstructions, {
                  name = ud.humanName,
                  mDrain = metalDrain,
                  eDrain = energyDrain,
                  bp = totalBP
              })
          end
      end
  end
end

function widget:DrawScreen()
  if #activeConstructions == 0 then return end
  
  -- Posição: Canto Superior Direito
  local x = vsx - panelWidth - margin
  local y = vsy * 0.7 -- Começa em 70% da altura
  
  -- Fundo do Painel
  local totalHeight = (#activeConstructions * itemHeight) + (itemHeight) -- +1 para titulo
  
  gl.Color(0, 0, 0, 0.5)
  gl.Rect(x, y - totalHeight, x + panelWidth, y)
  
  -- Título
  gl.Color(1, 1, 1, 1)
  gl.Text("Active Constructions", x + 5, y - fontSize - 2, fontSize, "n")
  
  -- Lista
  local currentY = y - itemHeight - itemHeight -- Começa abaixo do titulo
  
  local _, _, _, mInc = Spring.GetTeamResources(myTeamID, "metal")
  local _, _, _, eInc = Spring.GetTeamResources(myTeamID, "energy")
  local _, _, mPull, _ = Spring.GetTeamResources(myTeamID, "metal")
  local _, _, ePull, _ = Spring.GetTeamResources(myTeamID, "energy")
  
  -- Verifica se estamos "stallando" globalmente
  local metalStalling = mPull > mInc
  local energyStalling = ePull > eInc
  
  for _, c in ipairs(activeConstructions) do
      gl.Color(1, 1, 1, 1)
      gl.Text(c.name, x + 5, currentY, fontSize, "n")
      
      -- Status
      local statusParts = {}
      local r, g, b = 0, 1, 0 -- Verde (OK)
      
      if metalStalling and c.mDrain > 0 then
          table.insert(statusParts, string.format("-%.0f M/s", c.mDrain))
          r, g, b = 1, 0, 0 -- Vermelho
      end
      
      if energyStalling and c.eDrain > 0 then
          table.insert(statusParts, string.format("-%.0f E/s", c.eDrain))
          -- Se já tem metal stalling, mantém vermelho, senão amarelo
          if not metalStalling or c.mDrain == 0 then
              r, g, b = 1, 1, 0 -- Amarelo
          end
      end
      
      local statusText = #statusParts > 0 and table.concat(statusParts, " ") or "OK"
      
      gl.Color(r, g, b, 1)
      gl.Text(statusText, x + panelWidth - 5, currentY, fontSize, "rn") -- Right aligned
      
      currentY = currentY - itemHeight
  end
  
  -- Reset Color
  gl.Color(1, 1, 1, 1)
end