-- Wireless corner actuator for the Create Propulsion airship autopilot.
local VERSION="1.0.0"
local PROTOCOL="sable_airship_thrusters_v1"
local SETTINGS_FILE="/.airship_corner.settings"
local WATCHDOG_SECONDS=0.60
local THRUSTER_TYPES={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}

settings.load(SETTINGS_FILE)
local controllerId=tonumber(settings.get("airship_corner.controller_id"))
local thrusters={}

local function discover()
  thrusters={}
  for _,name in ipairs(peripheral.getNames()) do
    local types={peripheral.getType(name)}
    for _,kind in ipairs(types) do
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

local args={...}
if args[1]=="setup" then
  controllerId=tonumber(args[2])
  if not controllerId then write("Center computer ID: "); controllerId=tonumber(read()) end
  if not controllerId then error("Controller ID must be a number",0) end
  settings.set("airship_corner.controller_id",controllerId)
  settings.save(SETTINGS_FILE)
  print("Paired with center computer #"..controllerId)
end
if not controllerId then error("Run: corner setup CENTER_ID",0) end

discover(); stop(); openWireless()
local count=0 for _ in pairs(thrusters) do count=count+1 end
if count~=3 then error("Expected 3 touching thrusters; found "..count,0) end
print("Corner relay "..VERSION.." | center #"..controllerId.." | 3 thrusters")

local lastCommand=os.clock()
while true do
  local sender,msg=rednet.receive(PROTOCOL,0.10)
  if sender==controllerId and type(msg)=="table" then
    if msg.type=="discover" then
      local advertised={}
      for name,t in pairs(thrusters) do advertised[#advertised+1]={name=name,kind=t.kind} end
      rednet.send(sender,{type="advertise",thrusters=advertised,version=VERSION},PROTOCOL)
    elseif msg.type=="set" and msg.controllerId==controllerId and type(msg.name)=="string" then
      local t=thrusters[msg.name]
      if t then
        local power=math.max(0,math.min(1,tonumber(msg.power) or 0))
        local ok=pcall(t.device.setPowerNormalized,power)
        if ok then lastCommand=os.clock() else stop() end
      end
    elseif msg.type=="stop" then stop(); lastCommand=os.clock() end
  end
  if os.clock()-lastCommand>WATCHDOG_SECONDS then stop() end
end
