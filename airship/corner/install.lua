-- Installer for a corner thruster relay computer.
local INSTALLER_ROLE="CORNER_RELAY_INSTALLER"
local REPOSITORY="KrreeeeGlass/Glasses"
local FILES={
  {remote="main.lua",path="/corner.lua",marker='ROLE_MARKER="CORNER_RELAY_MAIN"'},
  {remote="startup.lua",path="/startup.lua",marker='ROLE_MARKER="CORNER_RELAY_STARTUP"'},
}
local validTypes={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}
local localThrusters=0
for _,name in ipairs(peripheral.getNames()) do
  for _,kind in ipairs({peripheral.getType(name)}) do
    if validTypes[kind] then localThrusters=localThrusters+1; break end
  end
end
if localThrusters~=3 then
  error("CORNER installer requires exactly 3 touching thrusters; found "..localThrusters,0)
end
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
  if not source:find(entry.marker,1,true) then error("Wrong-role file rejected: "..entry.remote,0) end
  assert(load(source,"@"..entry.remote,"t",_ENV))
  local temp=entry.path..".download"; if fs.exists(temp) then fs.delete(temp) end
  local file=assert(fs.open(temp,"w")); file.write(source); file.close()
  if fs.exists(entry.path) then fs.delete(entry.path) end
  fs.move(temp,entry.path); print("done")
end
print("CORNER RELAY installed. Rebooting...")
sleep(1)
os.reboot()
