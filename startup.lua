-- Smart Glasses tracker boot updater
-- Save this file as /startup.lua on the Smart Glasses computer.

local UPDATE_URL = "https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/player_tracker.lua"
local TRACKER_PATH = "/player_tracker.lua"
local TEMP_PATH = "/player_tracker.lua.download"
local BACKUP_PATH = "/player_tracker.lua.backup"

local function status(message, color)
  if term.isColor() and color then term.setTextColor(color) end
  print("[tracker] " .. message)
  if term.isColor() then term.setTextColor(colors.white) end
end

local function downloadUpdate()
  if UPDATE_URL == "" then
    status("UPDATE_URL is empty; starting the installed copy", colors.yellow)
    return false
  end
  if not http then
    status("HTTP is disabled; starting the installed copy", colors.yellow)
    return false
  end

  local response, reason = http.get(UPDATE_URL)
  if not response then
    status("update failed: " .. tostring(reason), colors.yellow)
    return false
  end
  local source = response.readAll()
  response.close()
  if not source or source == "" then
    status("update returned an empty file", colors.yellow)
    return false
  end

  local compiled, syntaxError = load(source, "@" .. TRACKER_PATH, "t", _ENV)
  if not compiled then
    status("download rejected: " .. tostring(syntaxError), colors.red)
    return false
  end

  if fs.exists(TEMP_PATH) then fs.delete(TEMP_PATH) end
  local file = fs.open(TEMP_PATH, "w")
  if not file then
    status("cannot write temporary update", colors.red)
    return false
  end
  file.write(source)
  file.close()

  if fs.exists(BACKUP_PATH) then fs.delete(BACKUP_PATH) end
  if fs.exists(TRACKER_PATH) then fs.move(TRACKER_PATH, BACKUP_PATH) end
  local moved, moveError = pcall(fs.move, TEMP_PATH, TRACKER_PATH)
  if not moved then
    if fs.exists(BACKUP_PATH) and not fs.exists(TRACKER_PATH) then
      fs.move(BACKUP_PATH, TRACKER_PATH)
    end
    status("could not install update: " .. tostring(moveError), colors.red)
    return false
  end
  if fs.exists(BACKUP_PATH) then fs.delete(BACKUP_PATH) end
  status("updated from GitHub", colors.lime)
  return true
end

downloadUpdate()

if not fs.exists(TRACKER_PATH) then
  status("missing " .. TRACKER_PATH, colors.red)
  status("install player_tracker.lua or configure UPDATE_URL", colors.yellow)
  return
end

status("starting player tracker", colors.cyan)
local ok = shell.run(TRACKER_PATH)
if not ok then status("tracker stopped with an error", colors.red) end
