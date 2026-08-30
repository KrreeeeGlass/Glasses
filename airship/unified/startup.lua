-- Role-neutral startup; this exact file belongs on all five computers.
local ROLE_MARKER="UNIFIED_AIRSHIP_STARTUP"
local REPOSITORY="KrreeeeGlass/Glasses"
local LOCAL="/airship.lua"
local REMOTE="airship/unified/airship.lua"

local function updateLauncher()
  if not http then return false end
  local response=http.get("https://raw.githubusercontent.com/"..REPOSITORY.."/main/"..REMOTE..
    "?t="..tostring(os.epoch("utc")))
  if not response then return false end
  local source=response.readAll(); response.close()
  if not source:find('ROLE_MARKER="UNIFIED_AIRSHIP_LAUNCHER"',1,true) or
      not load(source,"@"..LOCAL,"t",_ENV) then return false end
  local temp=LOCAL..".download"
  if fs.exists(temp) then fs.delete(temp) end
  local file=fs.open(temp,"w"); if not file then return false end
  file.write(source); file.close()
  if fs.exists(LOCAL) then fs.delete(LOCAL) end
  fs.move(temp,LOCAL)
  return true
end

print("[unified] UNIVERSAL AIRSHIP startup")
print(updateLauncher() and "[unified] launcher updated" or "[unified] using installed launcher")
if not fs.exists(LOCAL) then error("Missing /airship.lua",0) end

-- The launcher performs the hardware role detection. Center returns to the
-- prompt after status; a corner enters its permanent relay loop.
local thrusterTypes={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}
local count=0
for _,name in ipairs(peripheral.getNames()) do
  for _,kind in ipairs({peripheral.getType(name)}) do
    if thrusterTypes[kind] then count=count+1; break end
  end
end
if count==0 then shell.run(LOCAL,"status") else shell.run(LOCAL) end
