-- Create Propulsion airship safe boot + automatic updater.
local ROLE_MARKER="CENTER_CONTROLLER_STARTUP"
local REPOSITORY="KrreeeeGlass/Glasses"
local REMOTE_PATH="airship/center/main.lua"
local PROGRAM_PATH="/airship.lua"
local TEMP_PATH="/airship.lua.download"
local BACKUP_PATH="/airship.lua.backup"

local function status(message,color)
  if term.isColor() and color then term.setTextColor(color) end
  print("[airship] "..message)
  if term.isColor() then term.setTextColor(colors.white) end
end

status("CENTER CONTROLLER startup",colors.cyan)

local function update()
  if not http then status("HTTP disabled; using installed copy",colors.yellow); return false end
  local apiUrl="https://api.github.com/repos/"..REPOSITORY.."/commits/main?t="..
    tostring(os.epoch("utc"))
  local ok,response=pcall(http.get,{url=apiUrl,headers={
    Accept="application/vnd.github+json",["User-Agent"]="CC-Airship-Updater",
    ["Cache-Control"]="no-cache"}})
  local sha
  if ok and response then
    local data=textutils.unserialiseJSON(response.readAll())
    response.close()
    if type(data)=="table" then sha=data.sha end
  end
  local url=sha and ("https://raw.githubusercontent.com/"..REPOSITORY.."/"..sha.."/"..REMOTE_PATH)
    or ("https://raw.githubusercontent.com/"..REPOSITORY.."/main/"..REMOTE_PATH.."?t="..tostring(os.epoch("utc")))
  local download,reason=http.get(url)
  if not download then status("update failed: "..tostring(reason),colors.yellow); return false end
  local source=download.readAll(); download.close()
  if not source:find('ROLE_MARKER="CENTER_CONTROLLER_MAIN"',1,true) then
    status("wrong-role update rejected",colors.red); return false
  end
  local compiled,syntaxError=load(source,"@"..PROGRAM_PATH,"t",_ENV)
  if not compiled then status("update rejected: "..tostring(syntaxError),colors.red); return false end
  if fs.exists(TEMP_PATH) then fs.delete(TEMP_PATH) end
  local file=fs.open(TEMP_PATH,"w")
  if not file then status("cannot write update",colors.red); return false end
  file.write(source); file.close()
  if fs.exists(BACKUP_PATH) then fs.delete(BACKUP_PATH) end
  if fs.exists(PROGRAM_PATH) then fs.move(PROGRAM_PATH,BACKUP_PATH) end
  local moved,moveError=pcall(fs.move,TEMP_PATH,PROGRAM_PATH)
  if not moved then
    if fs.exists(BACKUP_PATH) and not fs.exists(PROGRAM_PATH) then fs.move(BACKUP_PATH,PROGRAM_PATH) end
    status("install failed: "..tostring(moveError),colors.red); return false
  end
  if fs.exists(BACKUP_PATH) then fs.delete(BACKUP_PATH) end
  status("updated from GitHub",colors.lime)
  return true
end

update()
if not fs.exists(PROGRAM_PATH) then status("missing /airship.lua",colors.red); return end
-- Running status on boot also forces every visible Create Propulsion thruster to zero.
shell.run(PROGRAM_PATH,"status")
status("ready: run 'airship goto X Y Z'",colors.cyan)
