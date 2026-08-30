-- One-command installer for the Create Propulsion airship autopilot.
local INSTALLER_ROLE="CENTER_CONTROLLER_INSTALLER"
local REPOSITORY="KrreeeeGlass/Glasses"
local REMOTE_DIR="airship/center/"
local FILES={
  {remote="main.lua",localPath="/airship.lua",marker='ROLE_MARKER="CENTER_CONTROLLER_MAIN"'},
  {remote="startup.lua",localPath="/startup.lua",marker='ROLE_MARKER="CENTER_CONTROLLER_STARTUP"'},
}

local thrusterTypes={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}
local touching=0
for _,name in ipairs(peripheral.getNames()) do
  for _,kind in ipairs({peripheral.getType(name)}) do
    if thrusterTypes[kind] then touching=touching+1; break end
  end
end
if touching==3 then
  error("CENTER installer refused: this computer touches 3 thrusters and looks like a CORNER",0)
end

if not http then error("HTTP is disabled in the CC:Tweaked server config",0) end
local base="https://raw.githubusercontent.com/"..REPOSITORY.."/main/"..REMOTE_DIR

for _,entry in ipairs(FILES) do
  write("Downloading "..entry.remote.."... ")
  local response,reason=http.get(base..entry.remote.."?t="..tostring(os.epoch("utc")))
  if not response then error("\nDownload failed: "..tostring(reason),0) end
  local source=response.readAll()
  response.close()
  if not source:find(entry.marker,1,true) then error("\nWrong-role file rejected: "..entry.remote,0) end
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
