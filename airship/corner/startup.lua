-- Corner relay automatic updater and launcher.
local ROLE_MARKER="CORNER_RELAY_STARTUP"
local REPOSITORY="KrreeeeGlass/Glasses"
local REMOTE="airship/corner/main.lua"
local LOCAL="/corner.lua"
local function update()
  if not http then return false end
  local ok,api=pcall(http.get,{url="https://api.github.com/repos/"..REPOSITORY.."/commits/main?t="..os.epoch("utc"),
    headers={Accept="application/vnd.github+json",["User-Agent"]="CC-Airship-Corner-Updater",["Cache-Control"]="no-cache"}})
  if not ok or not api then return false end
  local data=textutils.unserialiseJSON(api.readAll()); api.close()
  if not data or not data.sha then return false end
  local response=http.get("https://raw.githubusercontent.com/"..REPOSITORY.."/"..data.sha.."/"..REMOTE)
  if not response then return false end
  local source=response.readAll(); response.close()
  if not source:find('ROLE_MARKER="CORNER_RELAY_MAIN"',1,true) then
    print("[corner] rejected wrong-role update"); return false
  end
  if not load(source,"@"..LOCAL,"t",_ENV) then return false end
  local temp=LOCAL..".download"; if fs.exists(temp) then fs.delete(temp) end
  local file=fs.open(temp,"w"); if not file then return false end
  file.write(source); file.close()
  if fs.exists(LOCAL) then fs.delete(LOCAL) end
  fs.move(temp,LOCAL); return true
end
print("[corner] CORNER RELAY startup")
print(update() and "[corner] updated" or "[corner] using installed copy")
if fs.exists(LOCAL) then shell.run(LOCAL) else print("[corner] missing /corner.lua") end
