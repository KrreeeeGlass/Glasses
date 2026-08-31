-- Create Propulsion airship autopilot for CC:Tweaked (Minecraft 1.21.1).
local ROLE_MARKER="CENTER_CONTROLLER_MAIN"
-- Position and heading come from the Gadgets & Gizmos Advanced Navigation Table.
-- Fly:   airship goto X Y Z
-- Other: airship status | list | setup | zero | hold | abort

local VERSION="1.6.0"
local SETTINGS_FILE="/.ship_autopilot.settings"
local CONTROL_DT=0.10
local REMOTE_PROTOCOL="sable_airship_thrusters_v1"

local DEFAULTS={
  cruiseY=350,
  targetYaw=0,
  navYawOffset=0,
  maxHorizontalSpeed=12,
  maxClimbSpeed=6,
  maxDescentSpeed=3,
  horizontalTolerance=1.5,
  altitudeTolerance=1.0,
  positionKp=0.22,
  velocityKp=0.20,
  altitudeKp=0.18,
  verticalVelocityKp=0.16,
  yawKp=0.025,
  yawRateKd=0.018,
  hoverPower=0.50,
  maxPower=0.80,
  sensorFailureLimit=5,
  telemetryProtocol="sable_hud_v1",
}

local cfg,destination,phase,message
local nav
local thrusters={}
local relayCount=0
local wirelessStatus="MISSING"
local running=true
local velocity={x=0,y=0,z=0}
local yawRate=0
local lastPose=nil

local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
local function wrapAngle(a) return (a+180)%360-180 end
local function atan2(y,x)
  if math.atan2 then return math.atan2(y,x) end
  return math.atan(y,x)
end
local function distance2D(a,b)
  local dx,dz=b.x-a.x,b.z-a.z
  return math.sqrt(dx*dx+dz*dz)
end
local function copyDefaults(t)
  t=t or {}
  for k,v in pairs(DEFAULTS) do if t[k]==nil then t[k]=v end end
  return t
end
local function safeCall(obj,method,...)
  if not obj or type(obj[method])~="function" then return nil,"missing "..method end
  local out=table.pack(pcall(obj[method],...))
  if not out[1] then return nil,out[2] end
  return table.unpack(out,2,out.n)
end
local function isPosition(p)
  return type(p)=="table" and type(p.x)=="number" and
    type(p.y)=="number" and type(p.z)=="number"
end

local function save()
  settings.set("ship_autopilot.config",cfg)
  settings.set("ship_autopilot.destination",destination)
  settings.set("ship_autopilot.phase",phase)
  settings.save(SETTINGS_FILE)
end

local function loadSettings()
  settings.load(SETTINGS_FILE)
  cfg=copyDefaults(settings.get("ship_autopilot.config",{}))
  destination=settings.get("ship_autopilot.destination")
  phase=settings.get("ship_autopilot.phase","idle")
  if phase~="idle" then phase="aborted" end -- never resume thrust after reboot
end

local THRUSTER_TYPES={
  thruster=true,solid_fuel_thruster=true,ion_thruster=true,
  creative_thruster=true,vector_thruster=true,
  liquid_vector_thruster=true,creative_vector_thruster=true,
}

local function openWireless()
  local wireless=peripheral.find("modem",function(_,m)
    return m.isWireless and m.isWireless()
  end)
  if not wireless then
    wirelessStatus="MISSING (attach/activate a wireless or Ender modem)"
    return false
  end
  local name=peripheral.getName(wireless)
  if not rednet.isOpen(name) then rednet.open(name) end
  wirelessStatus=name..(rednet.isOpen(name) and " OPEN" or " CLOSED")
  return rednet.isOpen(name)
end

local function discover()
  nav=peripheral.find("navigation_table",function(_,p)
    return type(p.getTablePosition)=="function" and
      type(p.getTargetPosition)=="function" and
      type(p.getCurrentAngle)=="function"
  end)
  thrusters={}
  relayCount=0
  for _,name in ipairs(peripheral.getNames()) do
    for _,kind in ipairs({peripheral.getType(name)}) do
      if THRUSTER_TYPES[kind] then
        thrusters[name]={name=name,kind=kind,device=peripheral.wrap(name)}
        break
      end
    end
  end

  if not openWireless() then return end
  local seen={}
  local deadline=os.clock()+3.0
  local nextBroadcast=0
  while os.clock()<deadline do
    if os.clock()>=nextBroadcast then
      rednet.broadcast({type="discover",controllerId=os.getComputerID()},REMOTE_PROTOCOL)
      nextBroadcast=os.clock()+0.50
    end
    local sender,msg=rednet.receive(REMOTE_PROTOCOL,0.20)
    if sender and type(msg)=="table" and msg.type=="advertise" and
        type(msg.relayId)=="string" and type(msg.thrusters)=="table" then
      local relayId=msg.relayId
      seen[relayId]=true
      for _,remote in ipairs(msg.thrusters) do
        if type(remote.name)=="string" and type(remote.kind)=="string" then
          local networkName="corner_"..relayId.."_"..remote.name
          local remoteName=remote.name
          thrusters[networkName]={name=networkName,kind=remote.kind,relayId=relayId,
            device={setPowerNormalized=function(power)
              rednet.broadcast({type="set",controllerId=os.getComputerID(),
                targetRelay=relayId,name=remoteName,power=power},REMOTE_PROTOCOL)
            end}}
        end
      end
    end
  end
  for _ in pairs(seen) do relayCount=relayCount+1 end
end

local function allStop()
  for _,t in pairs(thrusters) do pcall(t.device.setPowerNormalized,0) end
end

-- The table reports its moving world position directly. The pointer angle is
-- measured in the ship/table frame. Comparing it with the world-space line to
-- the selected reference target gives ship yaw (0 = world +Z/south).
local function readNavigationPose(updateMotion)
  if not nav then return nil,nil,"Advanced Navigation Table missing" end
  local p,positionError=safeCall(nav,"getTablePosition")
  if not isPosition(p) then
    return nil,nil,"table position unavailable: "..tostring(positionError or "not projected")
  end
  local target,targetError=safeCall(nav,"getTargetPosition")
  if not isPosition(target) then
    return p,nil,"insert/select a valid reference target in the Advanced Navigation Table: "..
      tostring(targetError or "no target")
  end
  local angle,angleError=safeCall(nav,"getCurrentAngle")
  if type(angle)~="number" then
    return p,nil,"navigation angle unavailable: "..tostring(angleError)
  end
  local dx,dz=target.x-p.x,target.z-p.z
  if dx*dx+dz*dz<4 then
    return p,nil,"navigation reference is too close (keep it more than 2 blocks away)"
  end
  local worldBearing=math.deg(atan2(dx,dz)) -- 0 south, +90 east
  local yaw=wrapAngle(worldBearing+angle-90+(cfg.navYawOffset or 0))

  if updateMotion then
    local now=os.clock()
    if lastPose then
      local dt=now-lastPose.time
      if dt>=0.04 and dt<=1.0 then
        local vx=(p.x-lastPose.x)/dt
        local vy=(p.y-lastPose.y)/dt
        local vz=(p.z-lastPose.z)/dt
        local yr=wrapAngle(yaw-lastPose.yaw)/dt
        if math.abs(vx)<100 and math.abs(vy)<100 and math.abs(vz)<100 and math.abs(yr)<720 then
          velocity.x=velocity.x*0.60+vx*0.40
          velocity.y=velocity.y*0.60+vy*0.40
          velocity.z=velocity.z*0.60+vz*0.40
          yawRate=yawRate*0.60+yr*0.40
        end
      end
    end
    lastPose={x=p.x,y=p.y,z=p.z,yaw=yaw,time=now}
  end
  return {x=p.x,y=p.y,z=p.z},yaw,nil,target
end

local function navigationSummary()
  if not nav then
    print("Advanced nav:     MISSING")
    print("  It must touch the center computer or share a wired modem network.")
    return
  end
  local p,yaw,err,target=readNavigationPose(false)
  print("Advanced nav:     FOUND")
  if p then print(string.format("Table XYZ:        %.2f %.2f %.2f",p.x,p.y,p.z)) end
  if target then print(string.format("Reference XYZ:    %.2f %.2f %.2f",target.x,target.y,target.z)) end
  if yaw then print(string.format("Derived heading:  %.2f degrees",yaw))
  else print("Derived heading:  UNAVAILABLE - "..tostring(err)) end
end

local function listPeripherals()
  discover()
  navigationSummary()
  print("Wireless modem:  "..wirelessStatus)
  print("Corner relays:   "..relayCount.." / 4")
  local names={}
  for n in pairs(thrusters) do names[#names+1]=n end
  table.sort(names)
  print("Thrusters ("..tostring(#names).."):")
  for _,n in ipairs(names) do print("  "..n.." ["..thrusters[n].kind.."]") end
end

local function ask(prompt,default)
  write(prompt..(default~=nil and " ["..tostring(default).."]" or "")..": ")
  local value=read()
  if value=="" and default~=nil then return default end
  return value
end

local function setup()
  allStop()
  discover()
  local p,yaw,navError=readNavigationPose(false)
  if not p or not yaw then error("Navigation unavailable: "..tostring(navError),0) end
  local names={}
  for n in pairs(thrusters) do names[#names+1]=n end
  table.sort(names)
  if #names~=12 then error("Expected 12 remote thrusters; found "..#names,0) end

  print("\nFor each thruster, enter the FORCE it applies to the ship.")
  print("Use ship/body axes at heading zero: +x east, -x west, +z south,")
  print("-z north, and +y up. 'skip' ignores a thruster.")
  print("Corner x/z is -1 or +1; yaw moment is x*fz-z*fx.\n")
  cfg.thrusters={}
  local vectors={
    ["+x"]={1,0,0},["-x"]={-1,0,0},["+z"]={0,0,1},
    ["-z"]={0,0,-1},["+y"]={0,1,0},
  }
  for _,name in ipairs(names) do
    print(name)
    local axis=tostring(ask("  force (+x,-x,+z,-z,+y or skip)","skip")):lower()
    if axis~="skip" then
      local v=vectors[axis]
      if not v then error("Invalid direction: "..axis,0) end
      local rx,rz=0,0
      if axis~="+y" then
        rx=tonumber(ask("  corner x (-1 west, +1 east)"))
        rz=tonumber(ask("  corner z (-1 north, +1 south)"))
        if not rx or not rz then error("Corner values must be numbers",0) end
      end
      cfg.thrusters[#cfg.thrusters+1]={name=name,fx=v[1],fy=v[2],fz=v[3],rx=rx,rz=rz}
    end
  end
  cfg.cruiseY=tonumber(ask("Cruise altitude",cfg.cruiseY)) or cfg.cruiseY
  cfg.hoverPower=tonumber(ask("Estimated hover throttle 0..1",cfg.hoverPower)) or cfg.hoverPower
  cfg.maxPower=tonumber(ask("Maximum initial throttle 0..1",cfg.maxPower)) or cfg.maxPower
  phase="idle"
  destination=nil
  save()
  print("Saved "..#cfg.thrusters.." thrusters. Test 'airship hold' before goto.")
end

local function bindConfigured()
  if type(cfg.thrusters)~="table" or #cfg.thrusters==0 then
    error("Thrusters are not mapped. Run: airship setup",0)
  end
  for _,m in ipairs(cfg.thrusters) do
    if not thrusters[m.name] then error("Configured thruster missing: "..m.name,0) end
  end
end

local function setOutputs(bodyX,vertical,bodyZ,yawTorque)
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
    local device=thrusters[m.name] and thrusters[m.name].device
    if not device then allStop(); error("Thruster disappeared: "..m.name,0) end
    local ok,err=pcall(device.setPowerNormalized,clamp(raw[i]*scale,0,cfg.maxPower))
    if not ok then allStop(); error("Thruster failed "..m.name..": "..tostring(err),0) end
  end
end

local function worldToBody(x,z,yawDeg)
  local a=math.rad(yawDeg)
  local c,s=math.cos(a),math.sin(a)
  return x*c-z*s,x*s+z*c
end

local function horizontalCommand(p,target,yaw)
  local ex,ez=target.x-p.x,target.z-p.z
  local distance=math.sqrt(ex*ex+ez*ez)
  if distance<0.001 then return 0,0,distance end
  local speedLimit=math.min(cfg.maxHorizontalSpeed,math.max(0.35,distance*cfg.positionKp))
  local desiredX,desiredZ=ex/distance*speedLimit,ez/distance*speedLimit
  local cmdX=clamp((desiredX-velocity.x)*cfg.velocityKp,-1,1)
  local cmdZ=clamp((desiredZ-velocity.z)*cfg.velocityKp,-1,1)
  local bx,bz=worldToBody(cmdX,cmdZ,yaw)
  return bx,bz,distance
end

local function verticalCommand(p,targetY)
  local errorY=targetY-p.y
  local maxVelocity=errorY>=0 and cfg.maxClimbSpeed or cfg.maxDescentSpeed
  local desired=clamp(errorY*cfg.altitudeKp,-maxVelocity,maxVelocity)
  return clamp(cfg.hoverPower+(desired-velocity.y)*cfg.verticalVelocityKp,0,cfg.maxPower),errorY
end

local function sendTelemetry(p,yaw)
  local modem=peripheral.find("modem",function(_,m) return m.isWireless and m.isWireless() end)
  if not modem then return end
  local name=peripheral.getName(modem)
  if not rednet.isOpen(name) then rednet.open(name) end
  local distance=destination and distance2D(p,destination) or 0
  rednet.broadcast({title="AIRSHIP AUTOPILOT",lines={
    "Phase: "..phase,
    string.format("XYZ %.1f %.1f %.1f",p.x,p.y,p.z),
    destination and string.format("Target %.0f %.0f %.0f",destination.x,destination.y,destination.z) or "Target: none",
    string.format("Heading %.2f | error %.2f",yaw,wrapAngle(cfg.targetYaw-yaw)),
    string.format("Speed %.1f | distance %.1f",math.sqrt(velocity.x^2+velocity.y^2+velocity.z^2),distance),
    message or "",
  }},cfg.telemetryProtocol)
end

local function controlLoop()
  local failures=0
  while running do
    local p,yaw,navError=readNavigationPose(true)
    if not p or not yaw then
      failures=failures+1
      allStop()
      message="NAVIGATION LOST"
      if failures>=cfg.sensorFailureLimit then
        phase="aborted"; save()
        error("Navigation lost; all thrusters stopped: "..tostring(navError),0)
      end
      sleep(CONTROL_DT)
    else
      failures=0
      local yawError=wrapAngle(cfg.targetYaw-yaw)
      local yawCommand=clamp(yawError*cfg.yawKp-yawRate*cfg.yawRateKd,-0.5,0.5)
      local bx,bz,vertical=0,0,cfg.hoverPower

      if phase=="climb" then
        vertical=verticalCommand(p,cfg.cruiseY)
        bx,bz=horizontalCommand(p,{x=destination.startX,z=destination.startZ},yaw)
        if math.abs(p.y-cfg.cruiseY)<=cfg.altitudeTolerance and math.abs(velocity.y)<0.8 then
          phase="cruise"; save()
        end
      elseif phase=="cruise" then
        vertical=verticalCommand(p,cfg.cruiseY)
        bx,bz=horizontalCommand(p,destination,yaw)
        if distance2D(p,destination)<=cfg.horizontalTolerance and
            math.sqrt(velocity.x^2+velocity.z^2)<0.8 then
          phase="descend"; save()
        end
      elseif phase=="descend" then
        vertical=verticalCommand(p,destination.y)
        bx,bz=horizontalCommand(p,destination,yaw)
        if math.abs(p.y-destination.y)<=cfg.altitudeTolerance and
            distance2D(p,destination)<=cfg.horizontalTolerance and
            math.abs(velocity.y)<0.5 then
          phase="hold"; save()
        end
      elseif phase=="hold" then
        local target=destination or p
        vertical=verticalCommand(p,target.y)
        bx,bz=horizontalCommand(p,target,yaw)
      else
        allStop()
        break
      end
      setOutputs(bx,vertical,bz,yawCommand)
      message=nil
      sendTelemetry(p,yaw)
      sleep(CONTROL_DT)
    end
  end
end

local function commandLoop()
  while running do
    local _,key=os.pullEvent("key")
    if key==keys.backspace or key==keys.x then
      phase="aborted"
      running=false
      allStop()
      save()
      print("\nEMERGENCY STOP")
    end
  end
end

local function runController()
  discover()
  bindConfigured()
  if relayCount~=4 then error("Expected 4 corner relays; found "..relayCount,0) end
  if nav and type(nav.start)=="function" then safeCall(nav,"start") end
  local p,yaw,navError=readNavigationPose(true)
  if not p or not yaw then error("Navigation unavailable: "..tostring(navError),0) end
  print(string.format("Autopilot %s -> %.1f %.1f %.1f",VERSION,destination.x,destination.y,destination.z))
  print(string.format("Current %.1f %.1f %.1f | heading %.2f",p.x,p.y,p.z,yaw))
  print("Press X or Backspace for EMERGENCY STOP")
  local ok,err=xpcall(function() parallel.waitForAny(controlLoop,commandLoop) end,debug.traceback)
  allStop()
  if not ok then phase="aborted"; save(); error(err,0) end
end

local function flyTo(x,y,z)
  if not nav then error("Advanced Navigation Table not detected",0) end
  if type(nav.start)=="function" then safeCall(nav,"start") end
  local p,yaw,navError=readNavigationPose(false)
  if not p or not yaw then error("Navigation unavailable: "..tostring(navError),0) end
  destination={x=x,y=y,z=z,startX=p.x,startZ=p.z}
  phase=math.abs(p.y-cfg.cruiseY)>cfg.altitudeTolerance and "climb" or "cruise"
  save()
  runController()
end

local function calibrateZero()
  if not nav then error("Advanced Navigation Table not detected",0) end
  local oldOffset=cfg.navYawOffset or 0
  local _,measured,navError=readNavigationPose(false)
  if not measured then error("Navigation unavailable: "..tostring(navError),0) end
  cfg.navYawOffset=wrapAngle(oldOffset-measured)
  save()
  local _,corrected=readNavigationPose(false)
  print(string.format("Current ship direction saved as 0 degrees (now %.3f).",corrected or 0))
end

loadSettings()
discover()
allStop()
local args={...}
local cmd=(args[1] or ""):lower()
if cmd=="setup" then
  setup()
elseif cmd=="list" then
  listPeripherals()
elseif cmd=="goto" then
  local x,y,z=tonumber(args[2]),tonumber(args[3]),tonumber(args[4])
  if not x or not y or not z then error("Usage: airship goto X Y Z",0) end
  flyTo(x,y,z)
elseif cmd=="zero" then
  calibrateZero()
elseif cmd=="hold" then
  local p,yaw,navError=readNavigationPose(false)
  if not p or not yaw then error("Navigation unavailable: "..tostring(navError),0) end
  destination={x=p.x,y=p.y,z=p.z,startX=p.x,startZ=p.z}
  phase="hold"
  save()
  runController()
elseif cmd=="abort" then
  phase="aborted"; destination=nil; allStop(); save()
  print("All visible thrusters stopped.")
elseif cmd=="status" then
  print("Version: "..VERSION)
  print("Phase: "..phase)
  if destination then
    print(string.format("Target: %.1f %.1f %.1f",destination.x,destination.y,destination.z))
  end
  listPeripherals()
else
  print("Create Propulsion Airship Autopilot "..VERSION)
  print("  airship setup")
  print("  airship zero")
  print("  airship goto X Y Z")
  print("  airship hold | abort | status | list")
end
