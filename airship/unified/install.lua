-- One universal installer for center and corner airship computers.
local INSTALLER_ROLE="UNIFIED_AIRSHIP_INSTALLER"
local REPOSITORY="KrreeeeGlass/Glasses"
local FILES={
  {remote="airship.lua",path="/airship.lua",marker='ROLE_MARKER="UNIFIED_AIRSHIP_LAUNCHER"'},
  {remote="startup.lua",path="/startup.lua",marker='ROLE_MARKER="UNIFIED_AIRSHIP_STARTUP"'},
}
if not http then error("HTTP is disabled in the CC:Tweaked server config",0) end
local base="https://raw.githubusercontent.com/"..REPOSITORY.."/main/airship/unified/"
for _,entry in ipairs(FILES) do
  write("Downloading universal "..entry.remote.."... ")
  local response,reason=http.get(base..entry.remote.."?t="..tostring(os.epoch("utc")))
  if not response then error("\nDownload failed: "..tostring(reason),0) end
  local source=response.readAll(); response.close()
  if not source:find(entry.marker,1,true) then error("\nWrong file rejected: "..entry.remote,0) end
  local compiled,syntaxError=load(source,"@"..entry.remote,"t",_ENV)
  if not compiled then error("\nInvalid Lua: "..tostring(syntaxError),0) end
  local temp=entry.path..".download"
  if fs.exists(temp) then fs.delete(temp) end
  local file=assert(fs.open(temp,"w")); file.write(source); file.close()
  if fs.exists(entry.path) then fs.delete(entry.path) end
  fs.move(temp,entry.path); print("done")
end
print("UNIVERSAL AIRSHIP installed. Hardware role will be detected after reboot.")
sleep(1)
os.reboot()
