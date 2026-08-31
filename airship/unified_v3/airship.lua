-- Universal airship launcher: identical file on center and all four corners.
local ROLE_MARKER="UNIFIED_AIRSHIP_V3_LAUNCHER"
local REPOSITORY="KrreeeeGlass/Glasses"
local RELEASE_VERSION="1.6.5"
local RELEASE_REF="airship-v1.6.5"
local THRUSTER_TYPES={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}

local function countThrusters()
  local count=0
  for _,name in ipairs(peripheral.getNames()) do
    for _,kind in ipairs({peripheral.getType(name)}) do
      if THRUSTER_TYPES[kind] then count=count+1; break end
    end
  end
  return count
end

local count=countThrusters()
local role,remote,cache,marker
if count==0 then
  role="CENTER CONTROLLER"
  remote="airship/runtime_v160/center.lua"
  cache="/airship_center_runtime_v160.lua"
  marker='ROLE_MARKER="CENTER_CONTROLLER_MAIN"'
elseif count==3 then
  role="CORNER RELAY"
  remote="airship/runtime_v160/corner.lua"
  cache="/airship_corner_runtime_v160.lua"
  marker='ROLE_MARKER="CORNER_RELAY_MAIN"'
else
  error("Universal airship: expected 0 thrusters for center or 3 for corner; found "..count,0)
end

print("[unified] detected "..role.." ("..count.." local thrusters)")
print("[unified] launcher release v"..RELEASE_VERSION)
local downloadedVersion=nil
local url="https://raw.githubusercontent.com/"..REPOSITORY.."/"..RELEASE_REF.."/"..remote..
  "?t="..tostring(os.epoch("utc"))
local response=http and http.get(url)
if response then
  local source=response.readAll(); response.close()
  if source:find(marker,1,true) and load(source,"@"..cache,"t",_ENV) then
    downloadedVersion=source:match('local VERSION="([^"]+)"')
    local temporary=cache..".download"
    if fs.exists(temporary) then fs.delete(temporary) end
    local file=fs.open(temporary,"w")
    if file then
      file.write(source); file.close()
      if fs.exists(cache) then fs.delete(cache) end
      fs.move(temporary,cache)
      print("[unified] "..role.." runtime updated"..
        (downloadedVersion and " -> v"..downloadedVersion or ""))
    end
  else
    print("[unified] rejected invalid or wrong-role download")
  end
elseif fs.exists(cache) then
  print("[unified] GitHub unavailable; using cached runtime")
end

if not fs.exists(cache) then error("Missing "..role.." runtime and download failed",0) end
local file=assert(fs.open(cache,"r")); local source=file.readAll(); file.close()
local installedVersion=source:match('local VERSION="([^"]+)"') or "unknown"
print("[unified] running "..role.." v"..installedVersion)
local program,err=load(source,"@"..cache,"t",_ENV)
if not program then error(err,0) end
return program(...)
