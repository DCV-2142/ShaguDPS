-- load public variables into local
local parser = ShaguDPS.parser

local data = ShaguDPS.data
local config = ShaguDPS.config
local round = ShaguDPS.round

local segment = ShaguDPS.segment


-- populate all valid player units
local validUnits = { ["player"] = true }
for i=1,4 do validUnits["party" .. i] = true end
for i=1,40 do validUnits["raid" .. i] = true end

-- populate all valid player pets
local validPets = { ["pet"] = true }
for i=1,4 do validPets["partypet" .. i] = true end
for i=1,40 do validPets["raidpet" .. i] = true end

-- find unitstr by name
local unit_cache = {}
local function UnitByName(name)
  -- skip all scans if cache is still valid
  if unit_cache[name] and UnitName(unit_cache[name]) == name then
    return unit_cache[name]
  end

  -- scan players for current name
  for unit in pairs(validUnits) do
    if UnitName(unit) == name then
      unit_cache[name] = unit
      return unit
    end
  end

  -- scan pets for current name
  for unit in pairs(validPets) do
    if UnitName(unit) == name then
      unit_cache[name] = unit
      return unit
    end
  end
end

-- trim leading and trailing spaces
local function trim(str)
  return gsub(str, "^%s*(.-)%s*$", "%1")
end

parser.combat = CreateFrame("Frame")
parser.combat:RegisterEvent("PLAYER_REGEN_DISABLED")
parser.combat:RegisterEvent("PLAYER_REGEN_ENABLED")

parser.combat:SetScript("OnEvent", function()
  if event == "PLAYER_REGEN_DISABLED" then
    -- fight start
    segment.active = true
    segment.start_time = GetTime()
    segment.end_time = 0
    segment.duration = 0

    -- reset current segment data
    ShaguDPS.data.damage[1] = {}
    ShaguDPS.data.heal[1] = {}

  elseif event == "PLAYER_REGEN_ENABLED" then
    -- fight end
    if segment.active then
      segment.end_time = GetTime()
      segment.duration = segment.end_time - segment.start_time
      segment.active = nil
    end
  end
end)

parser.ScanName = function(self, name)
  -- ignore invalid messages
  if not name then return end

  -- check if name matches a real player
  for unit, _ in pairs(validUnits) do
    if UnitExists(unit) and UnitName(unit) == name then
      if UnitIsPlayer(unit) then
        local _, class = UnitClass(unit)
        data["classes"][name] = class
        return "PLAYER"
      end
    end
  end

  -- detect SuperWoW pet owner
  local match, _, owner = string.find(name, "%((.*)%)", 1)
  if match and owner then
    if parser:ScanName(owner) == "PLAYER" then
      data["classes"][name] = owner
      return "PET"
    end
  end

  -- check if name matches a player pet
  for unit, _ in pairs(validPets) do
    if UnitExists(unit) and UnitName(unit) == name then
      -- parse and set pet owners
      if strsub(unit,0,3) == "pet" then
        data["classes"][name] = UnitName("player")
      elseif strsub(unit,0,8) == "partypet" then
        data["classes"][name] = UnitName("party" .. strsub(unit,9))
      elseif strsub(unit,0,7) == "raidpet" then
        data["classes"][name] = UnitName("raid" .. strsub(unit,8))
      end

      return "PET"
    end
  end

  -- assign class other if tracking of all units is set
  if config.track_all_units == 1 then
    data["classes"][name] = data["classes"][name] or "__other__"
    return "OTHER"
  else
    return nil
  end
end

parser.AddData = function(self, source, action, target, value, school, datatype)
  -- abort on invalid input
  if type(source) ~= "string" then return end
  if not tonumber(value) then return end

  -- trim leading and trailing spaces
  source = trim(source)

  -- prevent self-damage from being tracked
  if datatype == "damage" and source == target then
    return
  end

  -- calculate effective value (heal)
  local effective = 0
  if datatype == "heal" then
    local unitstr = UnitByName(target)

    if unitstr then
      -- calculate the effective healing of the current data
      effective = math.min(UnitHealthMax(unitstr) - UnitHealth(unitstr), value)
    end
  end

  -- write both (overall and current segment)
  for segment = 0, 1 do
    local entry = data[datatype][segment]

    -- detect source and write initial table
    if not entry[source] then
      local type = parser:ScanName(source)
      if type == "PET" then
        -- create owner table if not yet existing
        local owner = data["classes"][source]
        if not entry[owner] and parser:ScanName(owner) then
          entry[owner] = { ["_sum"] = 0 }
        end
      elseif not type then
        -- invalid or disabled unit type
        break
      end

      -- create base damage table
      entry[source] = { ["_sum"] = 0 }
    end

    -- write pet damage into owners data if enabled
    local action, source = action, source
    if config.merge_pets == 1 and                 -- merge pets?
      data["classes"][source] ~= "__other__" and  -- valid unit?
      entry[data["classes"][source]]              -- has owner?
    then
      -- remove pet data
      entry[source] = nil

      action = "Pet: " .. source
      source = data["classes"][source]

      -- write data into owner
      if not entry[source] then
        entry[source] = { ["_sum"] = 0 }
      end
    end

    if entry[source] then
      -- write overall value and per spell
      entry[source][action] = (entry[source][action] or 0) + tonumber(value)
      entry[source]["_sum"] = (entry[source]["_sum"] or 0) + tonumber(value)

      if datatype == "heal" then
        -- write effective healing sumary
        entry[source]["_esum"] = (entry[source]["_esum"] or 0) + tonumber(effective)

        -- write effective healing per spell
        entry[source]["_effective"] = entry[source]["_effective"] or {}
        entry[source]["_effective"][action] = (entry[source]["_effective"][action] or 0) + tonumber(effective)
      end
    end
  end

  for id, callback in pairs(parser.callbacks.refresh) do
    callback()
  end
end

parser.callbacks = {
  ["refresh"] = {}
}
