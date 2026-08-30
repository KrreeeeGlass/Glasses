-- Create Propulsion airship autopilot for CC:Tweaked (Minecraft 1.21.1)
-- Requires: a CC GPS constellation, a navigation_table peripheral (Create: Avionics),
-- and Create Propulsion thrusters connected directly or through wired modems.
-- First run: ship_autopilot setup
-- Fly:       ship_autopilot goto X Y Z
-- Other:     ship_autopilot status | hold | abort | setup | list

local VERSION = "1.1.0"
local SETTINGS_FILE = "/.ship_autopilot.settings"
local CONTROL_DT = 0.10
local REMOTE_PROTOCOL = "sable_airship_thrusters_v1"

local DEFAULTS = {
  cruiseY = 350,
  targetYaw = 0,
  maxHorizontalSpeed = 12,
  maxClimbSpeed = 6,
  maxDescentSpeed = 3,
  slowRadius = 35,
  horizontalTolerance = 1.5,
  altitudeTolerance = 1.0,
  yawTolerance = 0.5,
  gpsTimeout = 0.5,
  gpsFailureLimit = 5,
  -- Starting gains. Tune at low altitude: lower a value if oscillation is violent.
  positionKp = 0.22,
  velocityKp = 0.20,
  altitudeKp = 0.18,
  verticalVelocityKp = 0.16,
  yawKp = 0.025,
  yawRateKd = 0.018,
  hoverPower = 0.50,
  maxPower = 0.80,
  telemetryProtocol = "sable_hud_v1",
}

local cfg, destination, phase, message
local nav, gimbal
local thrusters = {}
local relayCount = 0
local running = true
local lastPosition, lastPositionTime
local velocity = {x=0,y=0,z=0}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function sign(v) return v < 0 and -1 or 1 end
local function round(v, n)
  local p = 10^(n or 0)
  return math.floor(v*p + (v >= 0 and 0.5 or -0.5))/p
end
local function wrapAngle(a) return (a + 180) % 360 - 180 end
local function distance2D(a,b)
  local dx,dz=b.x-a.x,b.z-a.z
  return math.sqrt(dx*dx+dz*dz)
end
local function copyDefaults(t)
  t=t or {}
  for k,v in pairs(DEFAULTS) do if t[k]==nil then t[k]=v end end
  return t
end
local function safeCall(obj, method, ...)
  if not obj or type(obj[method])~="function" then return nil,"missing "..method end
  local out=table.pack(pcall(obj[method],...))
  if not out[1] then return nil,out[2] end
  return table.unpack(out,2,out.n)
end

local function save()
  settings.set("ship_autopilot.config",cfg)
  settings.set("ship_autopilot.destination",destination)
  settings.set("ship_autopilot.phase",phase)
  settings.save(SETTINGS_FILE)
end

local function load()
  settings.load(SETTINGS_FILE)
  cfg=copyDefaults(settings.get("ship_autopilot.config",{}))
  destination=settings.get("ship_autopilot.destination")
  phase=settings.get("ship_autopilot.phase","idle")
  if phase~="idle" then phase="aborted" end -- never resume thrust after a reboot
end

local THRUSTER_TYPES={
  thruster=true, solid_fuel_thruster=true, ion_thruster=true,
  creative_thruster=true, vector_thruster=true,
  liquid_vector_thruster=true, creative_vector_thruster=true,
}

local function discover()
  nav=peripheral.find("navigation_table")
  gimbal=peripheral.find("gimbal_sensor")
  thrusters={}
  relayCount=0
  for _,name in ipairs(peripheral.getNames()) do
    local types={peripheral.getType(name)}
    for _,kind in ipairs(types) do
      if THRUSTER_TYPES[kind] then
        thrusters[name]={name=name,kind=kind,device=peripheral.wrap(name)}
        break
      end
    end
  end

  -- Corner relay computers advertise their locally attached thrusters over Rednet.
  local wireless=peripheral.find("modem",function(_,m) return m.isWireless and m.isWireless() end)
  if wireless then
    local modemName=peripheral.getName(wireless)
    if not rednet.isOpen(modemName) then rednet.open(modemName) end
    local seenRelays={}
    local deadline=os.clock()+3.0
    local nextBroadcast=0
    while os.clock()<deadline do
      if os.clock()>=nextBroadcast then
        rednet.broadcast({type="discover",controllerId=os.getComputerID()},REMOTE_PROTOCOL)
        nextBroadcast=os.clock()+0.50
      end
      local sender,msg=rednet.receive(REMOTE_PROTOCOL,0.20)
      if sender and type(msg)=="table" and msg.type=="advertise" and type(msg.thrusters)=="table" then
        seenRelays[sender]=true
        for _,remote in ipairs(msg.thrusters) do
          -- The relay only advertises locally verified Create Propulsion thrusters.
          if type(remote.name)=="string" and type(remote.kind)=="string" then
            local networkName="corner_"..sender.."_"..remote.name
            local remoteName=remote.name
            thrusters[networkName]={name=networkName,kind=remote.kind,remoteId=sender,
              device={setPowerNormalized=function(power)
                rednet.send(sender,{type="set",controllerId=os.getComputerID(),
                  name=remoteName,power=power},REMOTE_PROTOCOL)
              end}}
          end
        end
      end
    end
    for _ in pairs(seenRelays) do relayCount=relayCount+1 end
  end
end

local function allStop()
  for _,t in pairs(thrusters) do pcall(t.device.setPowerNormalized,0) end
end

local function listPeripherals()
  discover()
  print("Navigation table: "..(nav and "FOUND" or "MISSING"))
  print("Gimbal sensor:   "..(gimbal and "FOUND" or "optional / missing"))
  print("Corner relays:   "..relayCount.." / 4")
  local names={} for n in pairs(thrusters) do names[#names+1]=n end table.sort(names)
  print("Thrusters ("..tostring(#names).."): ")
  for _,n in ipairs(names) do print("  "..n.." ["..thrusters[n].kind.."]") end
end

local function ask(prompt, default)
  write(prompt..(default~=nil and " ["..tostring(default).."]" or "")..": ")
  local s=read()
  if s=="" and default~=nil then return default end
  return s
end

local function setup()
  allStop(); discover(); listPeripherals()
  local names={} for n in pairs(thrusters) do names[#names+1]=n end table.sort(names)
  if #names==0 then error("No thrusters found. Make sure all four wireless corner relays are running.",0) end
  print("\nFor every thruster enter the FORCE it applies to the ship.")
  print("Directions use the ship/body frame at yaw 0: +x east, -x west, +z south, -z north, +y up.")
  print("Corner x/z is -1 or +1. Enter 0/0 for a vertical thruster; yaw moment is x*fz-z*fx.")
  print("Type skip for anything that is not part of this autopilot.\n")
  cfg.thrusters={}
  for _,name in ipairs(names) do
    print(name)
    local axis=tostring(ask("  force (+x,-x,+z,-z,+y or skip)","skip")):lower()
    if axis~="skip" then
      local vectors={
        ["+x"]={1,0,0},["-x"]={-1,0,0},
        ["+z"]={0,0,1},["-z"]={0,0,-1},["+y"]={0,1,0},
      }
      local v=vectors[axis]
      if not v then error("Invalid direction: "..axis,0) end
      local rx,rz=0,0
      if axis~="+y" then
        rx=tonumber(ask("  corner x (-1 left/west, +1 right/east)"))
        rz=tonumber(ask("  corner z (-1 front/north, +1 rear/south)"))
        if not rx or not rz then error("Corner values must be numbers",0) end
      end
      cfg.thrusters[#cfg.thrusters+1]={name=name,fx=v[1],fy=v[2],fz=v[3],rx=rx,rz=rz}
    end
  end
  cfg.cruiseY=tonumber(ask("Cruise altitude",cfg.cruiseY)) or cfg.cruiseY
  cfg.hoverPower=tonumber(ask("Estimated hover throttle 0..1",cfg.hoverPower)) or cfg.hoverPower
  cfg.maxPower=tonumber(ask("Maximum test throttle 0..1",cfg.maxPower)) or cfg.maxPower
  phase="idle"; destination=nil; save()
  print("Saved "..#cfg.thrusters.." thrusters. Run: ship_autopilot list")
  print("IMPORTANT: test hold at low altitude before a long flight.")
end

local function bindConfigured()
  if type(cfg.thrusters)~="table" or #cfg.thrusters==0 then
    error("Not configured. Run: ship_autopilot setup",0)
  end
  for _,m in ipairs(cfg.thrusters) do
    local found=thrusters[m.name]
    if not found then error("Configured thruster missing: "..m.name,0) end
  end
end

local function getPosition()
  local x,y,z=gps.locate(cfg.gpsTimeout,false)
  if not x then return nil end
  return {x=x,y=y,z=z}
end

local function samplePosition()
  local p=getPosition()
  if not p then return nil end
  local now=os.clock()
  if lastPosition and lastPositionTime then
    local dt=math.max(now-lastPositionTime,0.001)
    local raw={x=(p.x-lastPosition.x)/dt,y=(p.y-lastPosition.y)/dt,z=(p.z-lastPosition.z)/dt}
    if math.abs(raw.x)<100 and math.abs(raw.y)<100 and math.abs(raw.z)<100 then
      velocity.x=velocity.x*0.55+raw.x*0.45
      velocity.y=velocity.y*0.55+raw.y*0.45
      velocity.z=velocity.z*0.55+raw.z*0.45
    end
  end
  lastPosition,lastPositionTime=p,now
  return p
end

local function getYawAndRate()
  local yaw,err=safeCall(nav,"getHeading")
  if type(yaw)~="number" then return nil,0,err end
  local rate=0
  if gimbal then
    local rates=safeCall(gimbal,"getAngularRates")
    if type(rates)=="table" then rate=tonumber(rates[2]) or tonumber(rates.y) or 0 end
  end
  return yaw,rate
end

local function setOutputs(bodyX, vertical, bodyZ, yawTorque)
  local requested={x=bodyX,y=vertical,z=bodyZ,yaw=yawTorque}
  local raw,maxRaw={},0
  for i,m in ipairs(cfg.thrusters) do
    local moment=(m.rx or 0)*(m.fz or 0)-(m.rz or 0)*(m.fx or 0)
    local demand=(m.fx or 0)*requested.x+(m.fy or 0)*requested.y+
      (m.fz or 0)*requested.z+moment*requested.yaw
    raw[i]=math.max(0,demand)
    maxRaw=math.max(maxRaw,raw[i])
  end
  local scale=maxRaw>cfg.maxPower and cfg.maxPower/maxRaw or 1
  for i,m in ipairs(cfg.thrusters) do
    local power=clamp(raw[i]*scale,0,cfg.maxPower)
    local device=thrusters[m.name] and thrusters[m.name].device
    local ok,err=false,"peripheral disappeared"
    if device then ok,err=pcall(device.setPowerNormalized,power) end
    if not ok then allStop(); error("Thruster failed "..m.name..": "..tostring(err),0) end
  end
end

local function worldToBody(x,z,yawDeg)
  local a=math.rad(yawDeg); local c,s=math.cos(a),math.sin(a)
  return x*c-z*s, x*s+z*c
end

local function horizontalCommand(p,target,yaw)
  local ex,ez=target.x-p.x,target.z-p.z
  local d=math.sqrt(ex*ex+ez*ez)
  if d<0.001 then return 0,0,d end
  local speedLimit=math.min(cfg.maxHorizontalSpeed,math.max(0.5,d*cfg.positionKp))
  local desiredX,desiredZ=ex/d*speedLimit,ez/d*speedLimit
  local cmdX=clamp((desiredX-velocity.x)*cfg.velocityKp,-1,1)
  local cmdZ=clamp((desiredZ-velocity.z)*cfg.velocityKp,-1,1)
  local bx,bz=worldToBody(cmdX,cmdZ,yaw)
  return bx,bz,d
end

local function verticalCommand(p,targetY)
  local ey=targetY-p.y
  local maxV=ey>=0 and cfg.maxClimbSpeed or cfg.maxDescentSpeed
  local desired=clamp(ey*cfg.altitudeKp,-maxV,maxV)
  -- hoverPower supplies gravity compensation; correction changes climb/descent.
  return clamp(cfg.hoverPower+(desired-velocity.y)*cfg.verticalVelocityKp,0,cfg.maxPower),ey
end

local function sendTelemetry(p,yaw)
  local modem=peripheral.find("modem",function(_,m) return m.isWireless and m.isWireless() end)
  if not modem then return end
  if not rednet.isOpen(peripheral.getName(modem)) then rednet.open(peripheral.getName(modem)) end
  local d=destination and distance2D(p,destination) or 0
  rednet.broadcast({title="AIRSHIP AUTOPILOT",lines={
    "Phase: "..phase,
    string.format("XYZ %.1f %.1f %.1f",p.x,p.y,p.z),
    destination and string.format("Target %.0f %.0f %.0f",destination.x,destination.y,destination.z) or "Target: none",
    string.format("Yaw %.2f | error %.2f",yaw,wrapAngle(cfg.targetYaw-yaw)),
    string.format("Speed %.1f | distance %.1f",math.sqrt(velocity.x^2+velocity.y^2+velocity.z^2),d),
    message or "",
  }},cfg.telemetryProtocol)
end

local function controlLoop()
  local gpsFailures=0
  while running do
    local p=samplePosition()
    if not p then
      gpsFailures=gpsFailures+1; allStop(); message="GPS LOST"
      if gpsFailures>=cfg.gpsFailureLimit then phase="aborted"; save(); error("GPS lost; all thrusters stopped",0) end
      sleep(CONTROL_DT)
    else
      gpsFailures=0
      local yaw,yawRate,err=getYawAndRate()
      if not yaw then allStop(); error("Navigation table failed: "..tostring(err),0) end
      local yawError=wrapAngle(cfg.targetYaw-yaw)
      local yawCmd=clamp(yawError*cfg.yawKp-yawRate*cfg.yawRateKd,-0.5,0.5)
      local bx,bz,vertical=0,0,cfg.hoverPower

      if phase=="climb" then
        vertical=verticalCommand(p,cfg.cruiseY)
        bx,bz=horizontalCommand(p,{x=destination.startX,z=destination.startZ},yaw)
        if math.abs(p.y-cfg.cruiseY)<=cfg.altitudeTolerance and math.abs(velocity.y)<0.8 then phase="cruise"; save() end
      elseif phase=="cruise" then
        vertical=verticalCommand(p,cfg.cruiseY)
        bx,bz=horizontalCommand(p,destination,yaw)
        if distance2D(p,destination)<=cfg.horizontalTolerance and math.sqrt(velocity.x^2+velocity.z^2)<0.8 then phase="descend"; save() end
      elseif phase=="descend" then
        vertical=verticalCommand(p,destination.y)
        bx,bz=horizontalCommand(p,destination,yaw)
        if math.abs(p.y-destination.y)<=cfg.altitudeTolerance and distance2D(p,destination)<=cfg.horizontalTolerance and math.abs(velocity.y)<0.5 then phase="hold"; save() end
      elseif phase=="hold" then
        local target=destination or p
        vertical=verticalCommand(p,target.y)
        bx,bz=horizontalCommand(p,target,yaw)
      else
        allStop(); break
      end
      setOutputs(bx,vertical,bz,yawCmd)
      message=nil; sendTelemetry(p,yaw)
      sleep(CONTROL_DT)
    end
  end
end

local function commandLoop()
  while running do
    local _,key=os.pullEvent("key")
    if key==keys.backspace or key==keys.x then
      phase="aborted"; running=false; allStop(); save()
      print("\nEMERGENCY STOP")
    end
  end
end

local function runController()
  discover(); bindConfigured()
  if not nav then error("navigation_table missing. Install Create: Avionics and connect a Navigation Table.",0) end
  print(string.format("Autopilot %s -> %.1f %.1f %.1f",VERSION,destination.x,destination.y,destination.z))
  print("Press X or Backspace for EMERGENCY STOP")
  local ok,err=xpcall(function() parallel.waitForAny(controlLoop,commandLoop) end,debug.traceback)
  allStop()
  if not ok then phase="aborted"; save(); error(err,0) end
end

local function flyTo(x,y,z)
  local p=getPosition()
  if not p then error("GPS unavailable. Build/enable a four-host GPS constellation.",0) end
  destination={x=x,y=y,z=z,startX=p.x,startZ=p.z}
  phase=p.y<cfg.cruiseY-cfg.altitudeTolerance and "climb" or "cruise"
  save(); runController()
end

load(); discover(); allStop()
local args={...}; local cmd=(args[1] or ""):lower()
if cmd=="setup" then setup()
elseif cmd=="list" then listPeripherals()
elseif cmd=="goto" then
  local x,y,z=tonumber(args[2]),tonumber(args[3]),tonumber(args[4])
  if not x or not y or not z then error("Usage: ship_autopilot goto X Y Z",0) end
  flyTo(x,y,z)
elseif cmd=="hold" then
  discover(); bindConfigured(); local p=getPosition(); if not p then error("GPS unavailable",0) end
  destination={x=p.x,y=p.y,z=p.z,startX=p.x,startZ=p.z}; phase="hold"; save(); runController()
elseif cmd=="abort" then phase="aborted"; destination=nil; allStop(); save(); print("All visible thrusters stopped.")
elseif cmd=="status" then
  print("Version: "..VERSION); print("Phase: "..phase)
  if destination then print(string.format("Target: %.1f %.1f %.1f",destination.x,destination.y,destination.z)) end
  listPeripherals()
else
  print("Create Propulsion Airship Autopilot "..VERSION)
  print("  ship_autopilot setup")
  print("  ship_autopilot goto X Y Z")
  print("  ship_autopilot hold | abort | status | list")
end
