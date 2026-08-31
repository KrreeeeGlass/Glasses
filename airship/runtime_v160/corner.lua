-- Wireless corner actuator for the Create Propulsion airship autopilot.
local ROLE_MARKER="CORNER_RELAY_MAIN"
local VERSION="1.6.4"
local PROTOCOL="sable_airship_thrusters_v1"
local WATCHDOG_SECONDS=0.60
local RELEASE_SECONDS=3.0
local UPDATE_INTERVAL=120
local REPOSITORY="KrreeeeGlass/Glasses"
local RELEASE_REF="airship-v1.6.4"
local LAUNCHER_PATH="/airship.lua"
local RUNTIME_PATH="/airship_corner_runtime_v160.lua"
local THRUSTER_TYPES={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}

local controllerId=nil
local thrusters={}
local relayId=nil

local function sourceVersion(source)
  return source and (source:match('local RELEASE_VERSION="([^"]+)"') or
    source:match('local VERSION="([^"]+)"'))
end

local function versionNumber(version)
  local major,minor,patch=tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then return nil end
  return tonumber(major)*1000000+tonumber(minor)*1000+tonumber(patch)
end

local function advertisement()
  local advertised={}
  for name,t in pairs(thrusters) do advertised[#advertised+1]={name=name,kind=t.kind} end
  return {type="advertise",relayId=relayId,thrusters=advertised,version=VERSION}
end

local function discover()
  thrusters={}
  for _,name in ipairs(peripheral.getNames()) do
    for _,kind in ipairs({peripheral.getType(name)}) do
      if THRUSTER_TYPES[kind] then
        thrusters[name]={name=name,kind=kind,device=peripheral.wrap(name)}
        break
      end
    end
  end
end

local function stop()
  for _,t in pairs(thrusters) do pcall(t.device.setPowerNormalized,0) end
end

local function openWireless()
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name,"modem") then
      local modem=peripheral.wrap(name)
      if modem.isWireless() then rednet.open(name); return name end
    end
  end
  error("Attach a wireless or Ender modem",0)
end

local function updateFile(remote,path,marker,ref)
  if not http then return false end
  local url="https://raw.githubusercontent.com/"..REPOSITORY.."/"..(ref or "main").."/"..remote..
    "?t="..tostring(os.epoch("utc"))
  local response=http.get(url)
  if not response then return false end
  local source=response.readAll()
  response.close()
  if not source:find(marker,1,true) or not load(source,"@"..path,"t",_ENV) then
    return false
  end
  local installed=nil
  if fs.exists(path) then
    local current=fs.open(path,"r")
    if current then installed=current.readAll(); current.close() end
  end
  local incomingNumber=versionNumber(sourceVersion(source))
  local installedNumber=versionNumber(sourceVersion(installed))
  if incomingNumber and installedNumber and incomingNumber<installedNumber then
    print("Rejected stale update v"..tostring(sourceVersion(source))..
      "; keeping v"..tostring(sourceVersion(installed)))
    return false,nil
  end
  if installed==source then return false,nil end
  local temporary=path..".download"
  if fs.exists(temporary) then fs.delete(temporary) end
  local file=fs.open(temporary,"w")
  if not file then return false end
  file.write(source)
  file.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(temporary,path)
  return true,sourceVersion(source)
end

local function installAvailableUpdates()
  local runtimeChanged,runtimeVersion=updateFile("airship/runtime_v160/corner.lua",RUNTIME_PATH,
    'ROLE_MARKER="CORNER_RELAY_MAIN"',RELEASE_REF)
  local launcherChanged=updateFile("airship/unified_v3/airship.lua",LAUNCHER_PATH,
    'ROLE_MARKER="UNIFIED_AIRSHIP_V3_LAUNCHER"')
  return runtimeChanged or launcherChanged,runtimeVersion
end

discover()
stop()
openWireless()
local count,names=0,{}
for name in pairs(thrusters) do count=count+1; names[#names+1]=name end
if count~=3 then error("Expected 3 touching thrusters; found "..count,0) end
table.sort(names)
relayId=table.concat(names,"_")
print("Corner relay "..VERSION.." | AUTO PAIR | 3 thrusters")
print("Auto update enabled while idle")
print("Relay ID: "..relayId)
print("Waiting for center controller...")

local lastCommand=os.clock()
local nextAdvertisement=0
local nextUpdateCheck=os.clock()+UPDATE_INTERVAL
while true do
  if os.clock()>=nextAdvertisement then
    rednet.broadcast(advertisement(),PROTOCOL)
    nextAdvertisement=os.clock()+0.50
  end
  local sender,msg=rednet.receive(PROTOCOL,0.10)
  if sender and type(msg)=="table" then
    if msg.type=="discover" and
        (not controllerId or controllerId==sender or os.clock()-lastCommand>RELEASE_SECONDS) then
      if controllerId~=sender then print("Bound to center #"..sender) end
      controllerId=sender
      lastCommand=os.clock()
      rednet.broadcast(advertisement(),PROTOCOL)
    elseif sender==controllerId and msg.type=="set" and msg.controllerId==controllerId and
        msg.targetRelay==relayId and type(msg.name)=="string" then
      local t=thrusters[msg.name]
      if t then
        local power=math.max(0,math.min(1,tonumber(msg.power) or 0))
        local ok=pcall(t.device.setPowerNormalized,power)
        if ok then lastCommand=os.clock() else stop() end
      end
    elseif sender==controllerId and msg.type=="stop" and msg.targetRelay==relayId then
      stop(); lastCommand=os.clock()
    end
  end
  if os.clock()-lastCommand>WATCHDOG_SECONDS then stop() end
  if controllerId and os.clock()-lastCommand>RELEASE_SECONDS then
    print("Center #"..controllerId.." timed out; waiting for center...")
    controllerId=nil
  end
  -- Never update or reboot while the center is actively flying the ship.
  if not controllerId and os.clock()>=nextUpdateCheck then
    nextUpdateCheck=os.clock()+UPDATE_INTERVAL
    local updated,newVersion=installAvailableUpdates()
    if updated then
      stop()
      print("Update installed"..(newVersion and " -> v"..newVersion or "").."; rebooting safely...")
      sleep(0.5)
      os.reboot()
    end
  end
end
