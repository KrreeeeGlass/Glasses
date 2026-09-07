-- Create Propulsion airship autopilot for CC:Tweaked (Minecraft 1.21.1).
local ROLE_MARKER="CENTER_CONTROLLER_MAIN"
-- Position, orientation and motion come directly from an Advanced Contraption
-- Controller graph linked to the ship's Contraption Diagram.
-- Fly:   airship goto X Y Z
-- Other: airship status | list | controller | setup | calibrate | zero | hold | abort

local VERSION="1.14.0"
local SETTINGS_FILE="/.ship_autopilot.settings"
local CONTROL_DT=0.10
local ACTUATOR_DT=0.05
local REMOTE_PROTOCOL="sable_airship_thrusters_v1"

local DEFAULTS={
  cruiseY=350,
  targetYaw=0,
  controllerYawOffset=0,
  controlMatrix={1,0,0,1},
  maxHorizontalSpeed=12,
  maxClimbSpeed=6,
  maxDescentSpeed=3,
  horizontalTolerance=1.5,
  altitudeTolerance=1.0,
  positionKp=0.22,
  horizontalAccelKp=1.0,
  maxHorizontalAccel=2.0,
  altitudeKp=0.18,
  verticalAccelKp=1.0,
  maxVerticalAccel=3.0,
  gravity=11.0,
  yawActuatorPolarity=-1,
  yawRatePolarity=1,
  yawAccelPerPower=200,
  yawPowerLimit=0.06,
  minYawCommand=1/120,
  maxYawRate=10.0,
  maxYawAccel=8.0,
  yawApproachRateKp=0.55,
  yawRateKp=2.0,
  yawDeadband=2.0,
  yawRateDeadband=0.35,
  yawPauseAngle=7.5,
  yawAlignedAngle=2.0,
  yawAlignedRate=0.50,
  yawStableSeconds=0.60,
  movingYawScale=0.45,
  safeHorizontalSpeed=4.0,
  safeHorizontalAccel=0.80,
  safePositionKp=0.14,
  maxPower=0.80,
  sensorFailureLimit=5,
  telemetryProtocol="sable_hud_v1",
}

local cfg,destination,phase,message
local controller
local controllerName
local thrusters={}
local relaySenders={}
local relayCount=0
local wirelessStatus="MISSING"
local running=true
local velocity={x=0,y=0,z=0}
local yawRate=0
local currentMass=1
local thrusterTelemetry={}
local liftLevelCarry=0
local liftRotation=0
local powerLevelCarry={}
local controlDemand=nil

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
local function isFinite(value)
  return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end

local function hasPeripheralType(name,expected)
  for _,kind in ipairs({peripheral.getType(name)}) do
    if kind==expected then return true end
  end
  return false
end

local function save()
  settings.set("ship_autopilot.config",cfg)
  if destination==nil then
    settings.unset("ship_autopilot.destination")
  else
    settings.set("ship_autopilot.destination",destination)
  end
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
  controller=nil
  controllerName=nil
  for _,name in ipairs(peripheral.getNames()) do
    if hasPeripheralType(name,"advanced_contraption_controller") then
      local candidate=peripheral.wrap(name)
      if type(candidate.getGraphVariable)=="function" then
        controller=candidate
        controllerName=name
        break
      end
    end
  end
  thrusters={}
  relaySenders={}
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
      relaySenders[relayId]=sender
      for _,remote in ipairs(msg.thrusters) do
        if type(remote.name)=="string" and type(remote.kind)=="string" then
          local networkName="corner_"..relayId.."_"..remote.name
          local remoteName=remote.name
          thrusters[networkName]={name=networkName,kind=remote.kind,relayId=relayId,
            remoteName=remoteName,
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
  local hasRemote=false
  for _,t in pairs(thrusters) do
    if t.relayId then hasRemote=true
    else pcall(t.device.setPowerNormalized,0) end
  end
  if hasRemote and rednet then
    pcall(rednet.broadcast,{type="stop_all",controllerId=os.getComputerID()},REMOTE_PROTOCOL)
  end
end

local function relayHeartbeat()
  if rednet then
    rednet.broadcast({type="heartbeat",controllerId=os.getComputerID()},REMOTE_PROTOCOL)
  end
end

local GRAPH_VARIABLES={
  "available","mass",
  "position_x","position_y","position_z",
  "orientation_x","orientation_y","orientation_z","orientation_w",
  "linear_velocity_x","linear_velocity_y","linear_velocity_z",
  "angular_velocity_x","angular_velocity_y","angular_velocity_z",
}

local function readGraphVariable(name)
  if not controller then return nil,"Advanced Contraption Controller missing" end
  local ok,value=pcall(controller.getGraphVariable,name)
  if not ok then return nil,name..": "..tostring(value) end
  return value
end

-- The graph provides world position/velocity and a normalized quaternion. Yaw
-- is the world bearing of the ship's local +Z axis: 0 = world +Z, +90 = +X.
local function readControllerPose()
  if not controller then return nil,nil,"Advanced Contraption Controller missing" end
  local values={}
  for _,name in ipairs(GRAPH_VARIABLES) do
    local value,err=readGraphVariable(name)
    if value==nil then return nil,nil,"graph variable unavailable: "..tostring(err) end
    values[name]=value
  end
  if values.available~=true then
    return nil,nil,"controller graph reports available=false"
  end
  for name,value in pairs(values) do
    if name~="available" and not isFinite(value) then
      return nil,nil,"graph variable "..name.." is not a finite number"
    end
  end
  if values.mass<=0 then return nil,nil,"controller graph reports invalid mass" end

  local qx,qy,qz,qw=values.orientation_x,values.orientation_y,
    values.orientation_z,values.orientation_w
  local norm=math.sqrt(qx*qx+qy*qy+qz*qz+qw*qw)
  if norm<0.000001 then return nil,nil,"orientation quaternion has zero length" end
  qx,qy,qz,qw=qx/norm,qy/norm,qz/norm,qw/norm
  local forwardX=2*(qx*qz+qw*qy)
  local forwardZ=1-2*(qx*qx+qy*qy)
  local rawYaw=math.deg(atan2(forwardX,forwardZ))
  local yaw=wrapAngle(rawYaw+(cfg.controllerYawOffset or 0))

  velocity.x=values.linear_velocity_x
  velocity.y=values.linear_velocity_y
  velocity.z=values.linear_velocity_z
  yawRate=math.deg(values.angular_velocity_y)
  currentMass=values.mass
  return {x=values.position_x,y=values.position_y,z=values.position_z},yaw,nil,{
    mass=values.mass,rawYaw=rawYaw,values=values,
  }
end

local function controllerSummary()
  if not controller then
    print("Adv controller:   MISSING")
    print("  It must touch the center computer or share a wired modem network.")
    return
  end
  local p,yaw,err,physics=readControllerPose()
  print("Adv controller:   FOUND ("..tostring(controllerName)..")")
  if not p then
    print("Graph physics:    UNAVAILABLE - "..tostring(err))
    print("  Check the shared graph and all required variable names.")
    return
  end
  print("Graph physics:    READY")
  print(string.format("Ship XYZ:         %.2f %.2f %.2f",p.x,p.y,p.z))
  print(string.format("Mass:             %.2f",physics.mass))
  print(string.format("Heading:          %.2f degrees (raw %.2f)",yaw,physics.rawYaw))
  print(string.format("Velocity:         %.2f %.2f %.2f",velocity.x,velocity.y,velocity.z))
end

local function listPeripherals()
  discover()
  controllerSummary()
  print("Wireless modem:  "..wirelessStatus)
  print("Corner relays:   "..relayCount.." / 4")
  local names={}
  for n in pairs(thrusters) do names[#names+1]=n end
  table.sort(names)
  print("Thrusters ("..tostring(#names).."):")
  for _,n in ipairs(names) do print("  "..n.." ["..thrusters[n].kind.."]") end
end

-- Read-only inventory of everything CC:Tweaked can currently see through the
-- Advanced Contraption Controller. The report is also saved because the
-- terminal is usually too small to display every method and graph variable.
local function probeContraptionController()
  local controllerName=nil
  for _,name in ipairs(peripheral.getNames()) do
    if hasPeripheralType(name,"advanced_contraption_controller") then
      controllerName=name
      break
    end
  end
  if not controllerName then
    error("Advanced Contraption Controller not detected. It must directly touch the center computer or share its wired-modem network.",0)
  end

  local controller=peripheral.wrap(controllerName)
  local lines={}
  local function emit(value)
    local line=tostring(value)
    print(line)
    lines[#lines+1]=line
  end
  local function encoded(value,seen,depth)
    local kind=type(value)
    if kind=="nil" then return "nil" end
    if kind=="string" then return string.format("%q",value) end
    if kind~="table" then return tostring(value) end
    seen=seen or {}
    depth=depth or 0
    if seen[value] then return "<repeated table>" end
    if depth>=8 then return "{<depth limit>}" end
    seen[value]=true
    local entries={}
    local count=0
    for key,item in pairs(value) do
      count=count+1
      if count>200 then
        entries[#entries+1]="<entry limit>"
        break
      end
      entries[#entries+1]="["..encoded(key,seen,depth+1).."]="..
        encoded(item,seen,depth+1)
    end
    seen[value]=nil
    table.sort(entries)
    return "{"..table.concat(entries,", ").."}"
  end
  local function safelyEncoded(value)
    local ok,result=pcall(encoded,value)
    return ok and result or "<unprintable: "..tostring(result)..">"
  end
  local function readMethod(method,...)
    if type(controller[method])~="function" then
      emit(method..": MISSING")
      return nil
    end
    local result=table.pack(pcall(controller[method],...))
    if not result[1] then
      emit(method..": ERROR - "..tostring(result[2]))
      return nil
    end
    if result.n==1 then
      emit(method..": OK")
      return nil
    end
    local values={}
    for i=2,result.n do values[#values+1]=safelyEncoded(result[i]) end
    emit(method..": "..table.concat(values," | "))
    return result[2]
  end

  emit("AIRSHIP CONTROLLER PROBE v"..VERSION)
  emit("Peripheral: "..controllerName)
  local types={peripheral.getType(controllerName)}
  emit("Types: "..table.concat(types,", "))
  local methods=peripheral.getMethods(controllerName) or {}
  table.sort(methods)
  emit("Methods ("..#methods.."):")
  for _,method in ipairs(methods) do emit("  "..method) end

  emit("--- SAFE READS ---")
  for _,method in ipairs({"getName","listInputs","listInputIds","listChannels",
      "listAxes","getAllSignals","getGraphStatus","getGraphDiagnostics"}) do
    readMethod(method)
  end
  local variables=readMethod("listGraphVariables")
  if type(variables)=="table" then
    table.sort(variables)
    emit("--- GRAPH VARIABLE VALUES ---")
    if #variables==0 then emit("(none configured)") end
    for _,variable in ipairs(variables) do
      if type(controller.getGraphVariable)~="function" then
        emit(variable..": getGraphVariable MISSING")
      else
        local ok,value=pcall(controller.getGraphVariable,variable)
        emit(variable..": "..(ok and safelyEncoded(value) or "ERROR - "..tostring(value)))
      end
    end
  end

  local reportPath="/airship_controller_probe.txt"
  local file=assert(fs.open(reportPath,"w"))
  file.write(table.concat(lines,"\n"))
  file.close()
  emit("Saved full report: "..reportPath)
  emit("View again with: edit "..reportPath)
end

local function ask(prompt,default)
  write(prompt..(default~=nil and " ["..tostring(default).."]" or "")..": ")
  local value=read()
  if value=="" and default~=nil then return default end
  return value
end

-- The four computers sit at the corners and share the same orientation. Each
-- relay ID therefore contains its corner (front/back + left/right), while the
-- final name component is the outer edge occupied by that thruster. Nozzles
-- point outward, so the force on the ship points inward.
local function automaticThrusterMap(names)
  local mapped={}
  local forces={
    bottom={0,1,0},
    left={1,0,0},right={-1,0,0},
    front={0,0,1},back={0,0,-1},
  }
  for _,name in ipairs(names) do
    local relay,side=name:match("^corner_(.+)_([^_]+)$")
    local force=side and forces[side] or nil
    if not relay or not force then return nil,"unrecognized thruster name: "..name end
    local rx=relay:find("left",1,true) and -1 or
      (relay:find("right",1,true) and 1 or nil)
    local rz=relay:find("front",1,true) and -1 or
      (relay:find("back",1,true) and 1 or nil)
    if not rx or not rz then return nil,"unrecognized corner identity: "..relay end
    mapped[#mapped+1]={name=name,fx=force[1],fy=force[2],fz=force[3],
      rx=side=="bottom" and 0 or rx,rz=side=="bottom" and 0 or rz}
  end
  if #mapped~=12 then return nil,"expected 12 thrusters; mapped "..#mapped end
  return mapped
end

local function setup()
  allStop()
  discover()
  local p,yaw,controllerError,physics=readControllerPose()
  if not p or not yaw then error("Controller physics unavailable: "..tostring(controllerError),0) end
  local names={}
  for n in pairs(thrusters) do names[#names+1]=n end
  table.sort(names)
  if #names~=12 then error("Expected 12 remote thrusters; found "..#names,0) end

  local mapped,mapError=automaticThrusterMap(names)
  if not mapped then error("Automatic square-corner mapping failed: "..tostring(mapError),0) end
  cfg.thrusters=mapped
  print("\nAutomatic square-corner mapping complete:")
  print("  4 bottom thrusters -> lift")
  print("  2 left + 2 right edge thrusters -> X translation")
  print("  2 front + 2 back edge thrusters -> Z translation")
  print("  Differential edge thrust -> heading correction")
  print(string.format("  Controller graph ready: mass %.2f at %.2f %.2f %.2f",
    physics.mass,p.x,p.y,p.z))
  cfg.cruiseY=tonumber(ask("Cruise altitude",cfg.cruiseY)) or cfg.cruiseY
  cfg.maxPower=clamp(tonumber(ask("Maximum allowed throttle 0..1",cfg.maxPower)) or
    cfg.maxPower,0.05,1)
  phase="idle"
  destination=nil
  save()
  print("Saved all "..#cfg.thrusters.." thrusters automatically.")
  print("Test 'airship hold' at low altitude before goto.")
end

local function bindConfigured()
  if type(cfg.thrusters)~="table" or #cfg.thrusters==0 then
    error("Thrusters are not mapped. Run: airship setup",0)
  end
  for _,m in ipairs(cfg.thrusters) do
    if not thrusters[m.name] then error("Configured thruster missing: "..m.name,0) end
  end
end

-- Full-power force in Propulsion Newtons. Ion is the exact configured value in
-- this modpack; live relay telemetry continuously corrects it for real output.
local FALLBACK_FULL_THRUST={ion_thruster=1000}

local function thrusterCapacity(name)
  local device=thrusters[name]
  local observed=thrusterTelemetry[name]
  return observed and observed.fullThrust or
    (device and FALLBACK_FULL_THRUST[device.kind]) or 1000
end

local function totalLiftCapacity()
  local total,count=0,0
  for _,m in ipairs(cfg.thrusters or {}) do
    if (m.fy or 0)>0 then
      total=total+thrusterCapacity(m.name)
      count=count+1
    end
  end
  return total,count
end


local function normalizedAxisForce(acceleration,field)
  if math.abs(acceleration)<0.000001 then return 0 end
  local direction=acceleration>0 and 1 or -1
  local capacity=0
  for _,m in ipairs(cfg.thrusters or {}) do
    if ((m[field] or 0)*direction)>0 then
      capacity=capacity+thrusterCapacity(m.name)
    end
  end
  if capacity<=0 then return 0 end
  return clamp(currentMass*acceleration/capacity,-cfg.maxPower,cfg.maxPower)
end

local function solveSmallSystem(matrix,vector,size)
  local augmented={}
  for row=1,size do
    augmented[row]={}
    for column=1,size do augmented[row][column]=matrix[row][column] end
    augmented[row][size+1]=vector[row]
  end
  for column=1,size do
    local pivot=column
    for row=column+1,size do
      if math.abs(augmented[row][column])>math.abs(augmented[pivot][column]) then
        pivot=row
      end
    end
    if math.abs(augmented[pivot][column])<0.000000001 then return nil end
    augmented[column],augmented[pivot]=augmented[pivot],augmented[column]
    local divisor=augmented[column][column]
    for entry=column,size+1 do augmented[column][entry]=augmented[column][entry]/divisor end
    for row=1,size do
      if row~=column then
        local factor=augmented[row][column]
        for entry=column,size+1 do
          augmented[row][entry]=augmented[row][entry]-factor*augmented[column][entry]
        end
      end
    end
  end
  local answer={}
  for row=1,size do answer[row]=augmented[row][size+1] end
  return answer
end

-- Find the exact nonnegative solution using the least total thrust. With three
-- controlled axes, an unsaturated minimum has at most three active thrusters.
-- This prevents the old common-offset solution from firing unrelated opposing
-- thrusters during a pure translation or yaw command.
local function minimumThrustAllocation(horizontal,targetX,targetZ,targetYaw)
  local target={targetX,targetZ,targetYaw}
  local targetSize=targetX*targetX+targetZ*targetZ+targetYaw*targetYaw
  if targetSize<0.000000000001 then return {} end
  local best,bestCost

  local function consider(indices)
    local size=#indices
    local gram,rhs={},{}
    for row=1,size do
      gram[row]={}
      local a=horizontal[indices[row]]
      local av={a.fx,a.fz,a.moment}
      rhs[row]=av[1]*target[1]+av[2]*target[2]+av[3]*target[3]
      for column=1,size do
        local b=horizontal[indices[column]]
        gram[row][column]=av[1]*b.fx+av[2]*b.fz+av[3]*b.moment
      end
    end
    local powers=solveSmallSystem(gram,rhs,size)
    if not powers then return end
    local actualX,actualZ,actualYaw,cost=0,0,0,0
    for entry=1,size do
      local power=powers[entry]
      if power<-0.0000001 or power>cfg.maxPower+0.0000001 then return end
      power=clamp(power,0,cfg.maxPower)
      local actuator=horizontal[indices[entry]]
      actualX=actualX+actuator.fx*power
      actualZ=actualZ+actuator.fz*power
      actualYaw=actualYaw+actuator.moment*power
      cost=cost+power
      powers[entry]=power
    end
    local residual=(actualX-targetX)^2+(actualZ-targetZ)^2+(actualYaw-targetYaw)^2
    if residual>0.00000001*(1+targetSize) then return end
    if not bestCost or cost<bestCost-0.0000001 then
      bestCost=cost
      best={}
      for entry=1,size do best[horizontal[indices[entry]].index]=powers[entry] end
    end
  end

  local count=#horizontal
  for first=1,count do
    consider({first})
    for second=first+1,count do
      consider({first,second})
      for third=second+1,count do consider({first,second,third}) end
    end
  end
  return best
end

local function balancedYawAllocation(horizontal,targetYaw)
  if math.abs(targetYaw)<0.0000001 then return nil end
  local allocation={}
  local selected={}
  local totalX,totalZ,totalMoment=0,0,0
  for _,actuator in ipairs(horizontal) do
    if actuator.moment*targetYaw>0 then
      selected[#selected+1]=actuator
      totalX=totalX+actuator.fx
      totalZ=totalZ+actuator.fz
      totalMoment=totalMoment+actuator.moment
    end
  end
  -- The square layout has four same-sign yaw actuators whose translation
  -- forces cancel. Refuse the shortcut if a different layout is detected.
  if #selected~=4 or math.abs(totalX)>0.000001 or math.abs(totalZ)>0.000001 or
      math.abs(totalMoment)<0.000001 then return nil end
  local power=targetYaw/totalMoment
  if power<0 or power>cfg.maxPower then return nil end
  for _,actuator in ipairs(selected) do allocation[actuator.index]=power end
  local pairs={}
  local used={}
  for first=1,#selected do
    if not used[first] then
      for second=first+1,#selected do
        if not used[second] and
            math.abs(selected[first].fx+selected[second].fx)<0.000001 and
            math.abs(selected[first].fz+selected[second].fz)<0.000001 then
          pairs[#pairs+1]={selected[first].index,selected[second].index}
          used[first],used[second]=true,true
          break
        end
      end
    end
  end
  if #pairs~=2 then return nil end
  return allocation,pairs
end

local function setOutputs(bodyX,vertical,bodyZ,yawTorque)
  local raw={}
  local horizontal={}
  for i,m in ipairs(cfg.thrusters) do
    raw[i]=0
    if (m.fy or 0)<=0 then
      -- Y component of r x F. The previous release used the negative of this.
      local moment=(m.rz or 0)*(m.fx or 0)-(m.rx or 0)*(m.fz or 0)
      horizontal[#horizontal+1]={index=i,fx=m.fx or 0,fz=m.fz or 0,
        moment=moment,p=0}
    end
  end

  -- Two thrusters provide each translation direction and four provide either
  -- yaw direction, so these are the exact aggregate targets for this layout.
  local targetX=bodyX*2
  local targetZ=bodyZ*2
  local targetYaw=yawTorque*4
  local pureYaw=math.abs(targetX)<0.0000001 and math.abs(targetZ)<0.0000001 and
    math.abs(targetYaw)>=0.0000001
  local allocation,yawPairs
  if pureYaw then allocation,yawPairs=balancedYawAllocation(horizontal,targetYaw) end
  allocation=allocation or minimumThrustAllocation(horizontal,targetX,targetZ,targetYaw)
  if not allocation then
    -- Preserve direction when a combined request exceeds an actuator limit.
    local low,high=0,1
    for _=1,14 do
      local middle=(low+high)/2
      local candidate=minimumThrustAllocation(horizontal,targetX*middle,
        targetZ*middle,targetYaw*middle)
      if candidate then low,allocation=middle,candidate else high=middle end
    end
  end
  for index,power in pairs(allocation or {}) do
    raw[index]=power
  end


  -- Quantize pure yaw in two opposite, force-balanced pairs. Small corrections
  -- alternate pairs for half-sized, twice-as-frequent impulses; larger commands
  -- can activate both pairs while all four corners share the work over time.
  local pureYawLevels
  if pureYaw and allocation and yawPairs then
    local groupPower
    for _,power in pairs(allocation) do groupPower=power break end
    local carry=(powerLevelCarry.__balancedYaw or 0)+(groupPower or 0)*30
    local totalPairLevels=math.floor(carry+0.0000001)
    powerLevelCarry.__balancedYaw=carry-totalPairLevels
    local maxLevel=math.floor(clamp(cfg.maxPower,0,1)*15+0.0000001)
    totalPairLevels=clamp(totalPairLevels,0,maxLevel*2)
    local baseLevel=math.floor(totalPairLevels/2)
    local extras=totalPairLevels%2
    local rotation=((powerLevelCarry.__balancedYawRotation or 0)%2)+1
    powerLevelCarry.__balancedYawRotation=rotation
    pureYawLevels={}
    for pairIndex,pair in ipairs(yawPairs) do
      local relative=(pairIndex-rotation)%2
      local level=baseLevel+(relative<extras and 1 or 0)
      pureYawLevels[pair[1]],pureYawLevels[pair[2]]=level,level
    end
  end

  -- Create Propulsion quantizes normalized power to 15 redstone steps. Convert
  -- the requested total lift into aggregate steps, dither the fractional step
  -- over time, and rotate extra steps between corners to avoid violent jumps.
  local _,liftCount=totalLiftCapacity()
  if liftCount>0 then
    local requestedLevels=clamp(vertical,0,cfg.maxPower)*15*liftCount
    liftLevelCarry=liftLevelCarry+requestedLevels
    local totalLevels=math.floor(liftLevelCarry+0.0000001)
    liftLevelCarry=liftLevelCarry-totalLevels
    local maxLevel=math.floor(clamp(cfg.maxPower,0,1)*15+0.0000001)
    totalLevels=clamp(totalLevels,0,maxLevel*liftCount)
    local baseLevel=math.floor(totalLevels/liftCount)
    local extras=totalLevels%liftCount
    liftRotation=(liftRotation%liftCount)+1
    local liftIndex=0
    for i,m in ipairs(cfg.thrusters) do
      if (m.fy or 0)>0 then
        liftIndex=liftIndex+1
        local relative=(liftIndex-liftRotation)%liftCount
        raw[i]=(baseLevel+(relative<extras and 1 or 0))/15
      end
    end
  end

  local remoteOutputs={}
  for i,m in ipairs(cfg.thrusters) do
    local thruster=thrusters[m.name]
    if not thruster then allStop(); error("Thruster disappeared: "..m.name,0) end
    local power=clamp(raw[i],0,cfg.maxPower)
    if (m.fy or 0)<=0 then
      -- Dither sub-step horizontal/yaw commands instead of rounding them to
      -- either zero or one permanently violent redstone step.
      if pureYawLevels and pureYawLevels[i]~=nil then
        power=pureYawLevels[i]/15
        powerLevelCarry[m.name]=0
      elseif power<=0 then
        powerLevelCarry[m.name]=0
      else
        local carry=(powerLevelCarry[m.name] or ((i-1)/#cfg.thrusters))+power*15
        local level=math.floor(carry+0.0000001)
        powerLevelCarry[m.name]=carry-level
        local maxLevel=math.floor(clamp(cfg.maxPower,0,1)*15+0.0000001)
        power=clamp(level,0,maxLevel)/15
      end
    end
    if thruster.relayId then
      remoteOutputs[thruster.relayId]=remoteOutputs[thruster.relayId] or {}
      remoteOutputs[thruster.relayId][thruster.remoteName]=power
    else
      local ok,err=pcall(thruster.device.setPowerNormalized,power)
      if not ok then allStop(); error("Thruster failed "..m.name..": "..tostring(err),0) end
    end
  end
  if next(remoteOutputs) then
    local ok,err=pcall(rednet.broadcast,{type="frame",controllerId=os.getComputerID(),
      outputs=remoteOutputs},REMOTE_PROTOCOL)
    if not ok then allStop(); error("Failed to transmit thruster frame: "..tostring(err),0) end
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
  local accelLimit=math.min(cfg.maxHorizontalAccel,cfg.safeHorizontalAccel)
  local speedLimit=math.min(cfg.maxHorizontalSpeed,cfg.safeHorizontalSpeed,
    distance*math.min(cfg.positionKp,cfg.safePositionKp),
    math.sqrt(math.max(0,2*accelLimit*distance))*0.70)
  local desiredX,desiredZ=ex/distance*speedLimit,ez/distance*speedLimit
  local accelX=clamp((desiredX-velocity.x)*cfg.horizontalAccelKp,
    -accelLimit,accelLimit)
  local accelZ=clamp((desiredZ-velocity.z)*cfg.horizontalAccelKp,
    -accelLimit,accelLimit)
  local bodyAccelX,bodyAccelZ=worldToBody(accelX,accelZ,yaw)
  local desiredX=normalizedAxisForce(bodyAccelX,"fx")
  local desiredZ=normalizedAxisForce(bodyAccelZ,"fz")
  local matrix=type(cfg.controlMatrix)=="table" and cfg.controlMatrix or DEFAULTS.controlMatrix
  local commandX=(tonumber(matrix[1]) or 1)*desiredX+(tonumber(matrix[2]) or 0)*desiredZ
  local commandZ=(tonumber(matrix[3]) or 0)*desiredX+(tonumber(matrix[4]) or 1)*desiredZ
  return clamp(commandX,-cfg.maxPower,cfg.maxPower),
    clamp(commandZ,-cfg.maxPower,cfg.maxPower),distance
end

local function verticalCommand(p,targetY)
  local errorY=targetY-p.y
  local maxVelocity=errorY>=0 and cfg.maxClimbSpeed or cfg.maxDescentSpeed
  local desired=clamp(errorY*cfg.altitudeKp,-maxVelocity,maxVelocity)
  local acceleration=clamp((desired-velocity.y)*cfg.verticalAccelKp,
    -cfg.maxVerticalAccel,cfg.maxVerticalAccel)
  local capacity=totalLiftCapacity()
  if capacity<=0 then return 0,errorY end
  local requiredForce=currentMass*math.max(0,cfg.gravity+acceleration)
  return clamp(requiredForce/capacity,0,cfg.maxPower),errorY
end

local function yawCommandFor(yawError,headingYawRate,aligned)
  local absoluteError=math.abs(yawError)
  local usableError=math.max(0,absoluteError-cfg.yawDeadband)
  local brakingRate=math.sqrt(2*cfg.maxYawAccel*usableError)*0.75
  local desiredRate=math.min(cfg.maxYawRate,
    usableError*cfg.yawApproachRateKp,brakingRate)
  if yawError<0 then desiredRate=-desiredRate end
  if aligned then desiredRate=desiredRate*cfg.movingYawScale end

  -- Track the planned angular velocity. When the measured yaw rate is too high
  -- for the remaining angle, this becomes braking thrust before overshoot.
  local desiredAccel=clamp((desiredRate-headingYawRate)*cfg.yawRateKp,
    -cfg.maxYawAccel,cfg.maxYawAccel)
  if usableError<=0 and math.abs(headingYawRate)<=cfg.yawRateDeadband then
    return 0,desiredRate
  end
  local gain=math.max(20,tonumber(cfg.yawAccelPerPower) or 200)
  local command=clamp(desiredAccel/gain,-cfg.yawPowerLimit,cfg.yawPowerLimit)
  local minimum=clamp(tonumber(cfg.minYawCommand) or 1/120,0,cfg.yawPowerLimit)
  if math.abs(command)>0.0000001 and math.abs(command)<minimum then
    command=command>0 and minimum or -minimum
  end
  return command*cfg.yawActuatorPolarity,desiredRate
end

local function calibrationPulse(commandX,commandZ,commandYaw,targetY,seconds)
  local startPosition,startYaw,startError=readControllerPose()
  if not startPosition then error("Calibration sensor failure: "..tostring(startError),0) end
  local startVelocity={x=velocity.x,z=velocity.z}
  local startYawRate=yawRate
  local frames=math.max(1,math.floor(seconds/CONTROL_DT+0.5))
  for _=1,frames do
    relayHeartbeat()
    local current,_,sensorError=readControllerPose()
    if not current then error("Calibration sensor failure: "..tostring(sensorError),0) end
    local vertical=verticalCommand(current,targetY)
    setOutputs(commandX,vertical,commandZ,commandYaw)
    sleep(CONTROL_DT)
  end
  local endPosition,endYaw,endError=readControllerPose()
  if not endPosition then error("Calibration sensor failure: "..tostring(endError),0) end
  local vertical=verticalCommand(endPosition,targetY)
  setOutputs(0,vertical,0,0)
  return {x=velocity.x-startVelocity.x,z=velocity.z-startVelocity.z},
    wrapAngle(endYaw-startYaw),yawRate-startYawRate,startYaw,startYawRate
end

local function reachCalibrationAltitude(targetY,label,tolerance,speedTolerance,timeout,minimumY)
  print(label..string.format(" %.2f",targetY))
  tolerance=tolerance or 0.35
  speedTolerance=speedTolerance or 0.35
  local deadline=os.clock()+(timeout or 20)
  local stableFrames=0
  local lastY,lastVelocity
  while os.clock()<deadline do
    relayHeartbeat()
    local p,_,sensorError=readControllerPose()
    if not p then error("Calibration sensor failure: "..tostring(sensorError),0) end
    lastY,lastVelocity=p.y,velocity.y
    local vertical,errorY=verticalCommand(p,targetY)
    setOutputs(0,vertical,0,0)
    local atTarget=math.abs(errorY)<=tolerance and math.abs(velocity.y)<=speedTolerance
    local safelyClear=minimumY and p.y>=minimumY and
      math.abs(velocity.y)<=math.max(speedTolerance,0.75)
    if atTarget or safelyClear then
      stableFrames=stableFrames+1
      if stableFrames>=5 then return p end
    else
      stableFrames=0
    end
    sleep(CONTROL_DT)
  end
  error(string.format(
    "Could not reach calibration altitude %.2f (Y %.2f, velocity %.2f). Check lift energy, exhaust, mass and thrust.",
    targetY,lastY or -999,lastVelocity or -999),0)
end

local function calibrateActuators()
  allStop()
  discover()
  bindConfigured()
  if relayCount~=4 then error("Expected 4 corner relays; found "..relayCount,0) end
  local p,_,controllerError=readControllerPose()
  if not p then error("Controller physics unavailable: "..tostring(controllerError),0) end
  print("ACTUATOR CALIBRATION v"..VERSION)
  print("The ship will rise clear of the ground, then run X, Z and yaw pulses.")
  print("Use a clear area with overhead room; gyro must be active.")
  if tostring(ask("Type CALIBRATE to begin","")):upper()~="CALIBRATE" then
    error("Calibration cancelled",0)
  end

  local liftCapacity=totalLiftCapacity()
  if liftCapacity<=0 then error("No lift capacity available",0) end
  local startY=p.y
  local calibrationY=startY+2.5
  -- Exact redstone-step powers keep each required pair synchronized and make
  -- calibration measurements immune to sub-step temporal dithering.
  local pulsePower=1/15
  local pulseSeconds=0.40
  local ok,result=xpcall(function()
    local airborne=reachCalibrationAltitude(calibrationY,"Taking off toward",
      0.35,0.35,20,startY+1.50)
    calibrationY=airborne.y
    print(string.format("Ground clear; holding actual Y %.2f",calibrationY))

    print("Testing logical +X...")
    local deltaX,_,_,headingX=calibrationPulse(pulsePower,0,0,calibrationY,pulseSeconds)
    calibrationPulse(-pulsePower,0,0,calibrationY,pulseSeconds)
    sleep(0.25)

    print("Testing logical +Z...")
    local deltaZ,_,_,headingZ=calibrationPulse(0,pulsePower,0,calibrationY,pulseSeconds)
    calibrationPulse(0,-pulsePower,0,calibrationY,pulseSeconds)
    sleep(0.25)

    local bodyXX,bodyXZ=worldToBody(deltaX.x,deltaX.z,headingX)
    local bodyZX,bodyZZ=worldToBody(deltaZ.x,deltaZ.z,headingZ)
    local lengthX=math.sqrt(bodyXX*bodyXX+bodyXZ*bodyXZ)
    local lengthZ=math.sqrt(bodyZX*bodyZX+bodyZZ*bodyZZ)
    if lengthX<0.02 or lengthZ<0.02 then
      error("Translation response too small. Check energy/exhaust and try again.",0)
    end
    local m11,m21=bodyXX/lengthX,bodyXZ/lengthX
    local m12,m22=bodyZX/lengthZ,bodyZZ/lengthZ
    local determinant=m11*m22-m12*m21
    if math.abs(determinant)<0.35 then
      error("Translation axes are not independent enough to calibrate safely.",0)
    end
    cfg.controlMatrix={
      clamp(m22/determinant,-1.5,1.5),clamp(-m12/determinant,-1.5,1.5),
      clamp(-m21/determinant,-1.5,1.5),clamp(m11/determinant,-1.5,1.5),
    }

    print("Testing logical +yaw...")
    local yawPulse=1/30
    local yawSeconds=0.60
    local _,yawDelta,yawRateDelta,_,yawStartRate=
      calibrationPulse(0,0,yawPulse,calibrationY,yawSeconds)
    calibrationPulse(0,0,-yawPulse,calibrationY,yawSeconds)
    local yawResponse=math.abs(yawDelta)>=0.03 and yawDelta or yawRateDelta
    if math.abs(yawResponse)<0.03 then
      error("Yaw response too small. Check horizontal thrusters and try again.",0)
    end
    cfg.yawActuatorPolarity=yawResponse>0 and 1 or -1
    -- Some Diagram builds report angular_velocity_y with the opposite sign to
    -- quaternion-derived heading. Learn the conversion instead of assuming it.
    if math.abs(yawDelta)>=0.01 and math.abs(yawRateDelta)>=0.01 then
      cfg.yawRatePolarity=yawDelta*yawRateDelta>=0 and 1 or -1
    else
      cfg.yawRatePolarity=1
    end
    local rateGain=math.abs(yawRateDelta)/(yawPulse*yawSeconds)
    local accelerationAngle=yawDelta-yawStartRate*cfg.yawRatePolarity*yawSeconds
    local angleGain=2*math.abs(accelerationAngle)/(yawPulse*yawSeconds*yawSeconds)
    cfg.yawAccelPerPower=clamp(rateGain>=20 and rateGain or angleGain,20,5000)
    save()
    print("Measurements saved; releasing all thrust to drop.")
    return {deltaX=deltaX,deltaZ=deltaZ,yawDelta=yawDelta,
      yawRateDelta=yawRateDelta}
  end,debug.traceback)
  allStop()
  if not ok then error(result,0) end
  print(string.format("X response: %.3f %.3f",result.deltaX.x,result.deltaX.z))
  print(string.format("Z response: %.3f %.3f",result.deltaZ.x,result.deltaZ.z))
  print(string.format("Yaw response: %.3f deg / %.3f deg/s | polarity %d",
    result.yawDelta,result.yawRateDelta,cfg.yawActuatorPolarity))
  print(string.format("Yaw acceleration: %.1f deg/s2 per power",cfg.yawAccelPerPower))
  print(string.format("Yaw-rate coordinate polarity: %d",cfg.yawRatePolarity))
  print(string.format("Control matrix: %.3f %.3f / %.3f %.3f",
    cfg.controlMatrix[1],cfg.controlMatrix[2],cfg.controlMatrix[3],cfg.controlMatrix[4]))
  print("Calibration saved. Thrusters are OFF and the ship is dropping.")
  print("After it lands, run: airship hold")
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

local function relayTelemetryLoop()
  while running do
    local sender,packet=rednet.receive(REMOTE_PROTOCOL,1.0)
    if sender and type(packet)=="table" and packet.type=="telemetry" and
        type(packet.relayId)=="string" and relaySenders[packet.relayId]==sender and
        type(packet.thrusters)=="table" then
      for _,sample in ipairs(packet.thrusters) do
        if type(sample)=="table" and type(sample.name)=="string" then
          local networkName="corner_"..packet.relayId.."_"..sample.name
          local device=thrusters[networkName]
          if device then
            local record=thrusterTelemetry[networkName] or {
              fullThrust=FALLBACK_FULL_THRUST[device.kind] or 1000,
            }
            local power=tonumber(sample.power)
            local thrust=tonumber(sample.thrust)
            if power and thrust and power>0.05 and thrust>0 then
              local observed=thrust/power
              if observed>10 and observed<10000000 then
                -- Follow increases immediately; decay gently for altitude,
                -- obstruction or energy loss without trusting startup ramp-up.
                record.fullThrust=math.max(observed,record.fullThrust*0.995)
              end
            end
            record.power=power
            record.thrust=thrust
            record.energy=tonumber(sample.energy)
            record.obstruction=tonumber(sample.obstruction)
            thrusterTelemetry[networkName]=record
          end
        end
      end
    end
  end
end

local function actuatorLoop()
  local wasActive=false
  while running do
    local demand=controlDemand
    if demand then
      setOutputs(demand.x,demand.vertical,demand.z,demand.yaw)
      wasActive=true
    elseif wasActive then
      allStop()
      wasActive=false
    end
    sleep(ACTUATOR_DT)
  end
end

local function controlLoop()
  local failures=0
  local headingAligned=false
  local headingStableFrames=0
  local requiredStableFrames=math.max(1,math.floor(cfg.yawStableSeconds/CONTROL_DT+0.5))
  while running do
    -- Graph reads can take long enough for a relay's safe binding lease to
    -- expire. Refresh ownership before reading; set packets can also reclaim it.
    relayHeartbeat()
    local p,yaw,controllerError=readControllerPose()
    if not p or not yaw then
      failures=failures+1
      controlDemand=nil
      allStop()
      message="CONTROLLER PHYSICS LOST"
      if failures>=cfg.sensorFailureLimit then
        phase="aborted"; save()
        error("Controller physics lost; all thrusters stopped: "..tostring(controllerError),0)
      end
      sleep(CONTROL_DT)
    else
      failures=0
      local yawError=wrapAngle(cfg.targetYaw-yaw)
      local headingYawRate=yawRate*(tonumber(cfg.yawRatePolarity) or 1)
      if headingAligned and math.abs(yawError)>=cfg.yawPauseAngle then
        headingAligned=false
        headingStableFrames=0
      end
      if not headingAligned then
        if math.abs(yawError)<=cfg.yawAlignedAngle and
            math.abs(headingYawRate)<=cfg.yawAlignedRate then
          headingStableFrames=headingStableFrames+1
          if headingStableFrames>=requiredStableFrames then headingAligned=true end
        else
          headingStableFrames=0
        end
      end

      local yawCommand,plannedYawRate=yawCommandFor(yawError,headingYawRate,headingAligned)
      local bx,bz,vertical=0,0,0

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
        controlDemand=nil
        allStop()
        break
      end
      if not headingAligned then
        bx,bz=0,0
        message=string.format("ALIGNING %.1f deg | rate %.1f -> %.1f",
          yawError,headingYawRate,plannedYawRate)
      elseif math.abs(yawError)>cfg.yawDeadband then
        message=string.format("FLYING | yaw %.1f | rate %.1f -> %.1f",
          yawError,headingYawRate,plannedYawRate)
      else
        message="HEADING LOCKED | translation active"
      end
      -- Publish one complete demand atomically. The 20 Hz actuator loop turns
      -- it into tick-sized PWM pulses independently of slower Diagram reads.
      controlDemand={x=bx,vertical=vertical,z=bz,yaw=yawCommand}
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
      controlDemand=nil
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
  local p,yaw,controllerError=readControllerPose()
  if not p or not yaw then error("Controller physics unavailable: "..tostring(controllerError),0) end
  print(string.format("Autopilot %s -> %.1f %.1f %.1f",VERSION,destination.x,destination.y,destination.z))
  print(string.format("Current %.1f %.1f %.1f | heading %.2f",p.x,p.y,p.z,yaw))
  print("Press X or Backspace for EMERGENCY STOP")
  controlDemand=nil
  local ok,err=xpcall(function()
    parallel.waitForAny(controlLoop,commandLoop,relayTelemetryLoop,actuatorLoop)
  end,debug.traceback)
  controlDemand=nil
  allStop()
  if not ok then phase="aborted"; save(); error(err,0) end
end

local function flyTo(x,y,z)
  if not controller then error("Advanced Contraption Controller not detected",0) end
  local p,yaw,controllerError=readControllerPose()
  if not p or not yaw then error("Controller physics unavailable: "..tostring(controllerError),0) end
  destination={x=x,y=y,z=z,startX=p.x,startZ=p.z}
  phase=math.abs(p.y-cfg.cruiseY)>cfg.altitudeTolerance and "climb" or "cruise"
  save()
  runController()
end

local function calibrateZero()
  if not controller then error("Advanced Contraption Controller not detected",0) end
  local _,_,controllerError,physics=readControllerPose()
  if not physics then error("Controller physics unavailable: "..tostring(controllerError),0) end
  cfg.controllerYawOffset=wrapAngle(-physics.rawYaw)
  save()
  local _,corrected=readControllerPose()
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
elseif cmd=="controller" or cmd=="probe" then
  probeContraptionController()
elseif cmd=="goto" then
  local x,y,z=tonumber(args[2]),tonumber(args[3]),tonumber(args[4])
  if not x or not y or not z then error("Usage: airship goto X Y Z",0) end
  flyTo(x,y,z)
elseif cmd=="zero" then
  calibrateZero()
elseif cmd=="calibrate" then
  calibrateActuators()
elseif cmd=="hold" then
  local p,yaw,controllerError=readControllerPose()
  if not p or not yaw then error("Controller physics unavailable: "..tostring(controllerError),0) end
  destination={x=p.x,y=p.y,z=p.z,startX=p.x,startZ=p.z}
  phase="hold"
  save()
  runController()
elseif cmd=="abort" then
  phase="aborted"; destination=nil; allStop(); save()
  print("All visible thrusters stopped.")
elseif cmd=="status" then
  print("Version: "..VERSION)
  print("Auto update: enabled (every boot and airship command)")
  print("Phase: "..phase)
  if destination then
    print(string.format("Target: %.1f %.1f %.1f",destination.x,destination.y,destination.z))
  end
  listPeripherals()
else
  print("Create Propulsion Airship Autopilot "..VERSION)
  print("  airship setup")
  print("  airship calibrate  (learn movement/yaw axes)")
  print("  airship zero")
  print("  airship goto X Y Z")
  print("  airship hold | abort | status | list")
  print("  airship controller  (safe controller probe)")
end
