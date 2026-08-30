-- One-command installer for KrreeeeGlass/Glasses.
local BASE="https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/"
local FILES={"player_tracker.lua","startup.lua"}

if not http then error("HTTP is disabled in the CC:Tweaked server config",0) end

for _,name in ipairs(FILES) do
  write("Downloading "..name.."... ")
  local response,reason=http.get(BASE..name.."?t="..tostring(os.epoch("utc")))
  if not response then error("\nDownload failed: "..tostring(reason),0) end
  local body=response.readAll()
  response.close()
  local compiled,syntaxError=load(body,"@"..name,"t",_ENV)
  if not compiled then error("\nInvalid Lua from GitHub: "..tostring(syntaxError),0) end
  local temporary="/"..name..".download"
  if fs.exists(temporary) then fs.delete(temporary) end
  local file=assert(fs.open(temporary,"w"))
  file.write(body)
  file.close()
  local destination="/"..name
  if fs.exists(destination) then fs.delete(destination) end
  fs.move(temporary,destination)
  print("done")
end

print("Installed. Rebooting...")
sleep(1)
os.reboot()
