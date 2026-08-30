-- Installer for a corner thruster relay computer.
local REPOSITORY="KrreeeeGlass/Glasses"
local FILES={{remote="main.lua",path="/corner.lua"},{remote="startup.lua",path="/startup.lua"}}
if not http then error("HTTP is disabled in the CC:Tweaked server config",0) end
local api=assert(http.get({url="https://api.github.com/repos/"..REPOSITORY.."/commits/main?t="..os.epoch("utc"),
  headers={Accept="application/vnd.github+json",["User-Agent"]="CC-Airship-Corner-Installer",["Cache-Control"]="no-cache"}}))
local data=textutils.unserialiseJSON(api.readAll()); api.close()
local sha=assert(data and data.sha,"GitHub returned no commit SHA")
local base="https://raw.githubusercontent.com/"..REPOSITORY.."/"..sha.."/airship/corner/"
for _,entry in ipairs(FILES) do
  write("Downloading "..entry.remote.."... ")
  local response=assert(http.get(base..entry.remote))
  local source=response.readAll(); response.close()
  assert(load(source,"@"..entry.remote,"t",_ENV))
  local temp=entry.path..".download"; if fs.exists(temp) then fs.delete(temp) end
  local file=assert(fs.open(temp,"w")); file.write(source); file.close()
  if fs.exists(entry.path) then fs.delete(entry.path) end
  fs.move(temp,entry.path); print("done")
end
print("CORNER RELAY installed. Rebooting...")
sleep(1)
os.reboot()
