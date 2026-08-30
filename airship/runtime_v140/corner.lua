-- Wireless corner actuator for the Create Propulsion airship autopilot.
local ROLE_MARKER="CORNER_RELAY_MAIN"
local VERSION="1.4.0"
local PROTOCOL="sable_airship_thrusters_v1"
local WATCHDOG_SECONDS=0.60
local RELEASE_SECONDS=3.0
local THRUSTER_TYPES={thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,liquid_vector_thruster=true,
  creative_vector_thruster=true}

local controllerId=nil
local thrusters={}

-- The three touching side names form a stable physical identity. With all
-- computers facing the same way, each corner has a unique side combination.
local relayId=nil

local function advertisement()
  local advertised={}
  for name,t in pairs(thrusters) do advertised[#advertised+1]={name=name,kind=t.kind} end
  return {type="advertise",relayId=relayId,thrusters=advertised,version=VERSION}
end

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

discover(); stop(); openWireless()
local count,names=0,{}
for name in pairs(thrusters) do count=count+1; names[#names+1]=name end
if count~=3 then error("Expected 3 touching thrusters; found "..count,0) end
table.sort(names)
relayId=table.concat(names,"_")
print("Corner relay "..VERSION.." | AUTO PAIR | 3 thrusters")
print("Relay ID: "..relayId)
print("Waiting for center controller...")

local lastCommand=os.clock()
local nextAdvertisement=0
while true do
  if os.clock()>=nextAdvertisement then
    rednet.broadcast(advertisement(),PROTOCOL)
    nextAdvertisement=os.clock()+0.50
  end
  local sender,msg=rednet.receive(PROTOCOL,0.10)
  if sender and type(msg)=="table" then
    if msg.type=="discover" and (not controllerId or controllerId==sender or os.clock()-lastCommand>RELEASE_SECONDS) then
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
end
