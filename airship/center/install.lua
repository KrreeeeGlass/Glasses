-- One-command installer for the Create Propulsion airship autopilot.
local REPOSITORY="KrreeeeGlass/Glasses"
local REMOTE_DIR="airship/center/"
local FILES={
  {remote="main.lua",localPath="/airship.lua"},
  {remote="startup.lua",localPath="/startup.lua"},
}

if not http then error("HTTP is disabled in the CC:Tweaked server config",0) end

local apiUrl="https://api.github.com/repos/"..REPOSITORY.."/commits/main?t="..
  tostring(os.epoch("utc"))
local api,apiReason=http.get({url=apiUrl,headers={
  Accept="application/vnd.github+json",["User-Agent"]="CC-Airship-Installer",
  ["Cache-Control"]="no-cache"}})
if not api then error("GitHub version check failed: "..tostring(apiReason),0) end
local metadata=textutils.unserialiseJSON(api.readAll())
api.close()
local sha=type(metadata)=="table" and metadata.sha
if type(sha)~="string" or #sha<7 then error("GitHub returned no commit SHA",0) end
local base="https://raw.githubusercontent.com/"..REPOSITORY.."/"..sha.."/"..REMOTE_DIR

for _,entry in ipairs(FILES) do
  write("Downloading "..entry.remote.."... ")
  local response,reason=http.get(base..entry.remote)
  if not response then error("\nDownload failed: "..tostring(reason),0) end
  local source=response.readAll()
  response.close()
  local compiled,syntaxError=load(source,"@"..entry.remote,"t",_ENV)
  if not compiled then error("\nInvalid Lua: "..tostring(syntaxError),0) end
  local temporary=entry.localPath..".download"
  if fs.exists(temporary) then fs.delete(temporary) end
  local file=assert(fs.open(temporary,"w"))
  file.write(source)
  file.close()
  if fs.exists(entry.localPath) then fs.delete(entry.localPath) end
  fs.move(temporary,entry.localPath)
  print("done")
end

print("CENTER CONTROLLER installed. Rebooting...")
sleep(1)
os.reboot()
