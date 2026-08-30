-- Smart Glasses Player Tracker
-- Advanced Peripherals 0.8 / CC:Tweaked / Minecraft 1.21.1
--
-- Controls (configure the Smart Glasses hotkey in Minecraft key binds):
--   tap  (< 500 ms): highlight next player
--   hold (>= 500 ms): track highlighted player; hold again to clear

local CONFIG = {
  OWNER_NAME = "Krreeee",   -- Exact wearer username; avoids auto-detection ambiguity.
  UI_SCALE = 0.80,           -- Overall HUD size: 1.0 normal, 0.8 smaller, 1.2 larger.
  HOLD_MS = 500,
  REFRESH_SECONDS = 0.05,    -- 20 target/HUD updates per second.
  OWNER_REFRESH_SECONDS = 0.10, -- 10 Hz: smoother than target polling without overloading AP.
  DETECTOR_REFRESH_SECONDS = 0.20, -- 5 Hz avoids saturating Player Detector calls.
  KEYBOARD_STATE_SECONDS = 0.10, -- Poll fallback for missed keyboard_close events.
  ROSTER_SECONDS = 1.00,     -- Full online-player scan (the expensive part).
  TRACKED_OFFLINE_GRACE_SECONDS = 6.0, -- Ignore brief detector lookup failures.
  ENVIRONMENT_SECONDS = 1.00,
  SPEED_SAMPLE_SECONDS = 0.10,
  BLOCK_TARGET_RANGE = 64,   -- Requested ray length; server config may clamp it.
  BLOCK_TARGET_BUTTON = 3,   -- 1 attack, 2 use, 3 pick-block (middle mouse).
  CHAT_COMMAND = "$target", -- Hidden chat: $target X Y Z [dimension], or $target clear.
  STATE_FILE = "/player_tracker.settings", -- Persistent target across deaths/relogs.
  SAFE_MARGIN = 8,
  ENV_LEFT_Y_RATIO = 0.33,  -- Places Environment below the minimap/party cluster.
  ENV_WIDTH_FACTOR = 0.85,  -- Matches the narrower minimap width.
  SABLE_PROTOCOL = "sable_hud_v1",
  SABLE_SENDER_ID = nil,    -- Set a computer ID to reject telemetry from all others.
  SABLE_X_RATIO = 0.145,    -- Just to the right of the minimap in the current layout.
  SABLE_WIDTH_RATIO = 0.19,
  SABLE_MAX_LINES = 7,
  SABLE_STALE_SECONDS = 5,
  PANEL_OPACITY = 0.82,
  MAX_ROWS = 16,
  COLORS = {
    panel = 0x07121C,
    border = 0x1C4A63,
    selection = 0x15384A,
    title = 0x67DDF5,
    normal = 0xE8F1F5,
    muted = 0x8CA4AF,
    highlight = 0xFFFFFF,
    tracked = 0x65E6A4,
    danger = 0xFF6B78,
    arrow = 0xFFC857,
  },
}

local function fail(message)
  error("Player Tracker: " .. message, 0)
end

if type(smartglasses) ~= "table" or type(smartglasses.modules) ~= "table" then
  fail("run this program inside worn Smart Glasses (smartglasses.modules is missing)")
end

local overlay = smartglasses.modules["advancedperipherals:overlay"]
local hotkey = smartglasses.modules["advancedperipherals:hotkey"]
local keyboard = smartglasses.modules["advancedperipherals:keyboard"]
if not overlay then fail("Overlay Module is not equipped") end
if not hotkey and not keyboard then
  fail("equip either a Hotkey Module or Keyboard Module for controls")
end

local detector = peripheral.find("player_detector")
local distanceDetector = peripheral.find("distance_detector")
local chatBox = peripheral.find("chat_box")
local environmentDetector = peripheral.find("environment_detector")
if not detector then
  fail("Player Detector is not equipped; run 'peripherals' to check its name")
end
if type(detector.getOnlinePlayers) ~= "function" or type(detector.getPlayer) ~= "function" then
  fail("the equipped Player Detector does not expose the Advanced Peripherals 0.8 API")
end

local ownedIds = {}
local ui = {}
local objectCache = {}
local uiDirty = false
local openedRednetNames = {}
local state = {
  players = {},
  details = {},
  selected = 0,
  selectedName = nil,
  trackedName = nil,
  blockTarget = nil,
  ownerName = CONFIG.OWNER_NAME,
  owner = nil,
  page = 1,
  layoutKey = nil,
  warning = nil,
  eye = nil,
  keyboardOpen = false,
  currentDimension = nil,
  environment = {},
  speed = 0,
  lastSpeedPos = nil,
  lastSpeedTime = nil,
  sable = {title="SABLE TELEMETRY",lines={},sender=nil,lastAt=nil},
  hud = {players=true,target=true,compass=true,environment=true,movement=true,
    sable=true,keyHelp=true},
  hudMenuOpen = false,
  hudMenuSelected = 1,
  trackedLastSeen = nil,
  lastOwnerYaw = nil,
  detailCursor = 0,
}
local HUD_MENU_ITEMS={
  {key="players",label="Player list"},
  {key="target",label="Target details"},
  {key="compass",label="Target compass"},
  {key="environment",label="Environment"},
  {key="movement",label="Movement / ETA"},
  {key="sable",label="Sable telemetry"},
  {key="keyHelp",label="Keyboard help"},
}

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function round(v)
  if v >= 0 then return math.floor(v + 0.5) end
  return math.ceil(v - 0.5)
end

local function normalizeAngle(degrees)
  return (degrees + 180) % 360 - 180
end

local function normalizeDimension(value)
  if type(value)~="string" or value=="" then return nil end
  value=value:lower()
  if not value:find(":",1,true) then value="minecraft:"..value end
  return value
end

local function distance(a, b)
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function safeCall(fn, ...)
  local result = table.pack(pcall(fn, ...))
  if not result[1] then return nil, result[2] end
  return table.unpack(result, 2, result.n)
end

local function saveTarget()
  local saved=nil
  if state.blockTarget then
    saved={type="block",x=state.blockTarget.x,y=state.blockTarget.y,z=state.blockTarget.z,
      dimension=state.blockTarget.dimension}
  elseif state.trackedName then
    saved={type="player",name=state.trackedName}
  end
  if saved then settings.set("player_tracker.target",saved)
  else settings.unset("player_tracker.target") end
  local ok,err=pcall(settings.save,CONFIG.STATE_FILE)
  if not ok then state.warning="Target save failed: "..tostring(err):sub(1,18) end
end

local function saveHudSettings()
  settings.set("player_tracker.hud",state.hud)
  local ok,err=pcall(settings.save,CONFIG.STATE_FILE)
  if not ok then state.warning="HUD save failed: "..tostring(err):sub(1,18) end
end

local function loadTarget()
  pcall(settings.load,CONFIG.STATE_FILE)
  local savedHud=settings.get("player_tracker.hud")
  if type(savedHud)=="table" then
    for key,default in pairs(state.hud) do
      if type(savedHud[key])=="boolean" then state.hud[key]=savedHud[key] end
    end
  end
  local saved=settings.get("player_tracker.target")
  if type(saved)~="table" then return end
  if saved.type=="player" and type(saved.name)=="string" and saved.name~="" then
    if saved.name:lower()==CONFIG.OWNER_NAME:lower() then
      settings.unset("player_tracker.target")
      pcall(settings.save,CONFIG.STATE_FILE)
    else
      state.trackedName=saved.name
    end
  elseif saved.type=="block" and tonumber(saved.x) and tonumber(saved.y) and
         tonumber(saved.z) and type(saved.dimension)=="string" then
    state.blockTarget={x=math.floor(saved.x),y=math.floor(saved.y),z=math.floor(saved.z),
      dimension=saved.dimension}
  end
end

local function remember(object)
  ownedIds[#ownedIds + 1] = object.getId()
  uiDirty = true
  return object
end

local function removeOwned()
  for _, id in ipairs(ownedIds) do pcall(overlay.removeObject, id) end
  if #ownedIds > 0 then uiDirty = true end
  ownedIds, ui, objectCache = {}, {}, {}
end

local function createText(props)
  props.shadow = props.shadow ~= false
  return remember(overlay.createText(props))
end

local function createRect(props)
  return remember(overlay.createRectangle(props))
end

local function createLine(props)
  return remember(overlay.createLine(props))
end

local function createCircle(props)
  return remember(overlay.createCircle(props))
end

local function setEnabled(obj, enabled)
  if not obj then return end
  local id=obj.getId()
  local cache=objectCache[id] or {}
  objectCache[id]=cache
  if cache.enabled~=enabled then
    obj.setEnabled(enabled)
    cache.enabled=enabled
    uiDirty=true
  end
end

local function setText(obj, content, color)
  local id=obj.getId()
  local cache=objectCache[id] or {}
  objectCache[id]=cache
  content=content or ""
  if cache.content~=content then
    obj.setContent(content)
    cache.content=content
    uiDirty=true
  end
  if color and cache.color~=color then
    obj.setColor(color)
    cache.color=color
    uiDirty=true
  end
end

local function setObjectPos(obj,x,y,z)
  local id=obj.getId()
  local cache=objectCache[id] or {}
  objectCache[id]=cache
  if cache.posX~=x or cache.posY~=y or cache.posZ~=z then
    obj.setPos(x,y,z)
    cache.posX,cache.posY,cache.posZ=x,y,z
    uiDirty=true
  end
end

local function setLineGeometry(obj,x1,y1,x2,y2)
  local id=obj.getId()
  local cache=objectCache[id] or {}
  objectCache[id]=cache
  -- Sub-pixel noise in player rotation should not create a new network update.
  x1,y1,x2,y2=round(x1*10)/10,round(y1*10)/10,round(x2*10)/10,round(y2*10)/10
  if cache.x1~=x1 or cache.y1~=y1 or cache.x2~=x2 or cache.y2~=y2 then
    obj.setPos(x1,y1,3)
    obj.setEndPos(x2,y2)
    cache.x1,cache.y1,cache.x2,cache.y2=x1,y1,x2,y2
    uiDirty=true
  end
end

local function getLayout()
  local rawW, rawH, guiScale = safeCall(overlay.getGuiSize)
  rawW, rawH, guiScale = tonumber(rawW), tonumber(rawH), tonumber(guiScale) or 1
  if not rawW or not rawH or rawW <= 0 or rawH <= 0 then
    rawW, rawH, guiScale = 320, 180, 1
  end

  -- AP reports client pixels plus Minecraft's GUI scale. Overlay 2D coordinates
  -- use logical GUI units, so divide by the scale.
  local w = math.max(160, rawW / math.max(1, guiScale))
  local h = math.max(90, rawH / math.max(1, guiScale))
  local short = math.min(w, h)
  local overallScale = clamp(tonumber(CONFIG.UI_SCALE) or 1, 0.5, 1.5)
  local baseFont = clamp(short / 180, 0.65, 1.15)
  local baseLineH = clamp(10 * baseFont, 7, 12)
  local baseMargin = clamp(CONFIG.SAFE_MARGIN * baseFont, 4, 12)
  local basePanelW = clamp(w * 0.29, 105, 190)
  if w < 270 then
    -- The panels are stacked, so narrow windows can devote more horizontal
    -- space to readable names without covering the whole view.
    basePanelW = clamp(w * 0.55, 86, math.max(86, w - baseMargin * 2))
  end
  local font = baseFont * overallScale
  local lineH = baseLineH * overallScale
  local margin = baseMargin * overallScale
  local panelW = basePanelW * overallScale
  -- Reserve space below the list for the seven-line target panel.
  -- Row count uses the unscaled layout so UI_SCALE changes physical HUD size
  -- instead of silently filling the saved space with additional rows.
  local availableH = h - baseMargin * 2 - baseLineH * 10 - 18
  local rows = clamp(math.floor(availableH / baseLineH), 2, CONFIG.MAX_ROWS)
  return {
    w = w, h = h, scale = guiScale, font = font, lineH = lineH,
    margin = margin, panelW = panelW, rows = rows,
    key = table.concat({round(w), round(h), guiScale, rows, overallScale}, ":"),
  }
end

local function rebuildUI(layout)
  removeOwned()
  local m, lh, pw, f = layout.margin, layout.lineH, layout.panelW, layout.font
  local pad, gap = 5*f, 4*f
  local listH = lh * (layout.rows + 2) + 6*f
  local rightX = layout.w - m - pw

  -- Both panels form one top-right column: player list first, target below.
  ui.listBg = createRect({x=rightX, y=m, z=0, sizeX=pw, sizeY=listH,
    color=CONFIG.COLORS.panel, opacity=CONFIG.PANEL_OPACITY})
  ui.listAccent = createRect({x=rightX, y=m, z=0.4, sizeX=pw, sizeY=1.5*f,
    color=CONFIG.COLORS.title, opacity=0.95})
  ui.listTitle = createText({x=rightX+pad, y=m+4*f, z=1, content="PLAYERS", fontSize=f,
    color=CONFIG.COLORS.title})
  ui.rowHighlight=createRect({x=rightX+2*f,y=m,z=0.5,sizeX=pw-4*f,sizeY=lh,
    color=CONFIG.COLORS.selection,opacity=0.92,enabled=false})
  ui.rows = {}
  for i = 1, layout.rows do
    ui.rows[i] = createText({x=rightX+pad, y=m+4*f+lh*(i+1), z=1, content="",
      fontSize=f, color=CONFIG.COLORS.normal})
  end
  ui.pageText = createText({x=rightX+pad, y=m+4*f+lh*(layout.rows+1), z=1,
    content="", fontSize=f*0.82, color=CONFIG.COLORS.muted})
  local targetY = m + listH + gap
  ui.targetBg = createRect({x=rightX, y=targetY, z=0, sizeX=pw, sizeY=lh*7+8*f,
    color=CONFIG.COLORS.panel, opacity=CONFIG.PANEL_OPACITY})
  ui.targetAccent=createRect({x=rightX,y=targetY,z=0.4,sizeX=pw,sizeY=1.5*f,
    color=CONFIG.COLORS.arrow,opacity=0.95})
  ui.targetLines = {}
  for i = 1, 7 do
    ui.targetLines[i] = createText({x=rightX+pad, y=targetY+4*f+lh*(i-1), z=1,
      content="", fontSize=(i == 1 and f or f*0.88),
      color=(i == 1 and CONFIG.COLORS.title or CONFIG.COLORS.normal)})
  end

  -- Three dynamically positioned lines form a direction arrow.
  ui.arrowShaft = createLine({x=0,y=0,z=3,endX=0,endY=0,width=clamp(2*f,1,4),
    color=CONFIG.COLORS.arrow, pixelated=false, enabled=false})
  ui.arrowHead1 = createLine({x=0,y=0,z=3,endX=0,endY=0,width=clamp(2*f,1,4),
    color=CONFIG.COLORS.arrow, pixelated=false, enabled=false})
  ui.arrowHead2 = createLine({x=0,y=0,z=3,endX=0,endY=0,width=clamp(2*f,1,4),
    color=CONFIG.COLORS.arrow, pixelated=false, enabled=false})
  -- Compact compass bezel around the direction arrow.
  ui.arrowCenterX = rightX + pw - 18*f
  ui.arrowCenterY = targetY + 22*f
  local cx,cy,r=ui.arrowCenterX,ui.arrowCenterY,14*f
  ui.compassRing=createCircle({x=cx,y=cy,z=2,radius=r,filled=false,
    borderWidth=clamp(1.2*f,1,3),segments=40,pixelated=false,
    color=CONFIG.COLORS.border,opacity=0.95,enabled=false})
  ui.compassTicks={
    createLine({x=cx,y=cy-r-1*f,z=2.5,endX=cx,endY=cy-r+3*f,
      width=clamp(1.3*f,1,3),color=CONFIG.COLORS.title,pixelated=false,enabled=false}),
    createLine({x=cx+r-3*f,y=cy,z=2.5,endX=cx+r+1*f,endY=cy,
      width=clamp(1.3*f,1,3),color=CONFIG.COLORS.title,pixelated=false,enabled=false}),
    createLine({x=cx,y=cy+r-3*f,z=2.5,endX=cx,endY=cy+r+1*f,
      width=clamp(1.3*f,1,3),color=CONFIG.COLORS.title,pixelated=false,enabled=false}),
    createLine({x=cx-r-1*f,y=cy,z=2.5,endX=cx-r+3*f,endY=cy,
      width=clamp(1.3*f,1,3),color=CONFIG.COLORS.title,pixelated=false,enabled=false}),
  }

  -- Generic ship telemetry panel, positioned immediately right of the minimap.
  local sableW=clamp(layout.w*CONFIG.SABLE_WIDTH_RATIO,120*f,210*f)
  local sableX=clamp(layout.w*CONFIG.SABLE_X_RATIO,m,layout.w-m-sableW-pw-gap)
  local sableH=lh*(CONFIG.SABLE_MAX_LINES+2)+8*f
  ui.sableBg=createRect({x=sableX,y=m,z=0,sizeX=sableW,sizeY=sableH,
    color=CONFIG.COLORS.panel,opacity=CONFIG.PANEL_OPACITY})
  ui.sableAccent=createRect({x=sableX,y=m,z=0.4,sizeX=sableW,sizeY=1.5*f,
    color=CONFIG.COLORS.arrow,opacity=0.95})
  ui.sableTitle=createText({x=sableX+pad,y=m+4*f,z=1,content="SABLE TELEMETRY",
    fontSize=f,color=CONFIG.COLORS.title})
  ui.sableStatus=createText({x=sableX+pad,y=m+4*f+lh,z=1,content="Waiting for link...",
    fontSize=f*0.76,color=CONFIG.COLORS.muted})
  ui.sableLines={}
  for i=1,CONFIG.SABLE_MAX_LINES do
    ui.sableLines[i]=createText({x=sableX+pad,y=m+4*f+lh*(i+1),z=1,content="",
      fontSize=f*0.80,color=CONFIG.COLORS.normal})
  end
  ui.sableWidth=sableW

  -- Movement stays bottom-right; Environment sits below the upper-left minimap.
  local moveH=lh*4+8*f
  local moveY=layout.h-m-moveH
  local envW=pw*CONFIG.ENV_WIDTH_FACTOR
  local envX=m
  local envH=lh*4+8*f
  local envY=clamp(layout.h*CONFIG.ENV_LEFT_Y_RATIO,m,layout.h-m-envH)
  ui.envBg=createRect({x=envX,y=envY,z=0,sizeX=envW,sizeY=envH,
    color=CONFIG.COLORS.panel,opacity=CONFIG.PANEL_OPACITY})
  ui.envAccent=createRect({x=envX,y=envY,z=0.4,sizeX=envW,sizeY=1.5*f,
    color=CONFIG.COLORS.tracked,opacity=0.95})
  ui.envLines={}
  for i=1,4 do
    ui.envLines[i]=createText({x=envX+pad,y=envY+4*f+lh*(i-1),z=1,content="",
      fontSize=(i==1 and f or f*0.80),color=(i==1 and CONFIG.COLORS.title or CONFIG.COLORS.normal)})
  end

  -- Movement/ETA stays in the otherwise unused bottom-right corner.
  ui.moveBg=createRect({x=rightX,y=moveY,z=0,sizeX=pw,sizeY=moveH,
    color=CONFIG.COLORS.panel,opacity=CONFIG.PANEL_OPACITY})
  ui.moveAccent=createRect({x=rightX,y=moveY,z=0.4,sizeX=pw,sizeY=1.5*f,
    color=CONFIG.COLORS.tracked,opacity=0.95})
  ui.moveLines={}
  for i=1,4 do
    ui.moveLines[i]=createText({x=rightX+pad,y=moveY+4*f+lh*(i-1),z=1,content="",
      fontSize=(i==1 and f or f*0.84),color=(i==1 and CONFIG.COLORS.title or CONFIG.COLORS.normal)})
  end

  -- Keyboard help stacks above movement so both remain readable.
  local keyLines={
    "KEYBOARD CONTROLS",
    "Arrows / Tab: select",
    "Enter / Space: track",
    "B: select looked block",
    "Backspace: clear target",
    "Home / End: first / last",
    "M: HUD settings",
  }
  local keyH=lh*#keyLines+8*f
  local keyY=moveY-gap-keyH
  ui.keysBg=createRect({x=rightX,y=keyY,z=4,sizeX=pw,sizeY=keyH,
    color=CONFIG.COLORS.panel,opacity=CONFIG.PANEL_OPACITY,enabled=false})
  ui.keysAccent=createRect({x=rightX,y=keyY,z=4.4,sizeX=pw,sizeY=1.5*f,
    color=CONFIG.COLORS.title,opacity=0.95,enabled=false})
  ui.keyLines={}
  for i,line in ipairs(keyLines) do
    ui.keyLines[i]=createText({x=rightX+pad,y=keyY+4*f+lh*(i-1),z=5,
      content=line,fontSize=(i==1 and f or f*0.78),
      color=(i==1 and CONFIG.COLORS.title or CONFIG.COLORS.normal),enabled=false})
  end


  -- Modal HUD visibility menu, available only while Keyboard Mode is open.
  local menuRows=7
  local menuW=clamp(layout.w*0.30,145*f,225*f)
  local menuH=lh*(menuRows+3)+10*f
  local menuX=(layout.w-menuW)/2
  local menuY=(layout.h-menuH)/2
  ui.hudMenuBg=createRect({x=menuX,y=menuY,z=20,sizeX=menuW,sizeY=menuH,
    color=CONFIG.COLORS.panel,opacity=0.96,enabled=false})
  ui.hudMenuAccent=createRect({x=menuX,y=menuY,z=20.4,sizeX=menuW,sizeY=1.8*f,
    color=CONFIG.COLORS.title,opacity=1,enabled=false})
  ui.hudMenuTitle=createText({x=menuX+pad,y=menuY+5*f,z=21,content="HUD SETTINGS",
    fontSize=f,color=CONFIG.COLORS.title,enabled=false})
  ui.hudMenuHint=createText({x=menuX+pad,y=menuY+5*f+lh,z=21,
    content="Arrows select | Enter toggle | M close",fontSize=f*0.72,
    color=CONFIG.COLORS.muted,enabled=false})
  ui.hudMenuRows={}
  for i=1,menuRows do
    ui.hudMenuRows[i]=createText({x=menuX+pad,y=menuY+5*f+lh*(i+1),z=21,
      content="",fontSize=f*0.88,color=CONFIG.COLORS.normal,enabled=false})
  end
  state.layoutKey = layout.key
end

local function abbreviate(text, maxChars)
  text = tostring(text or "")
  if #text <= maxChars then return text end
  if maxChars <= 3 then return text:sub(1, maxChars) end
  return text:sub(1, maxChars - 3) .. "..."
end

local function compactValue(value)
  if type(value)=="table" then value=textutils.serialize(value,{compact=true}) end
  return tostring(value):gsub("[%c]+"," ")
end

local function handleSableTelemetry(sender,message,protocol)
  if protocol~=CONFIG.SABLE_PROTOCOL then return end
  if CONFIG.SABLE_SENDER_ID and sender~=CONFIG.SABLE_SENDER_ID then return end
  local title="SABLE TELEMETRY"
  local lines={}
  if type(message)=="string" then
    for line in message:gmatch("[^\r\n]+") do lines[#lines+1]=line end
  elseif type(message)=="table" then
    if message.clear==true then
      state.sable={title=title,lines={},sender=sender,lastAt=os.epoch("utc")/1000,
        modemAvailable=state.sable.modemAvailable}
      return
    end
    if type(message.title)=="string" then title=message.title end
    if type(message.lines)=="table" then
      for _,line in ipairs(message.lines) do lines[#lines+1]=compactValue(line) end
    elseif type(message.text)=="string" then
      for line in message.text:gmatch("[^\r\n]+") do lines[#lines+1]=line end
    else
      local keys={}
      for key,_ in pairs(message) do
        if key~="title" and key~="clear" then keys[#keys+1]=key end
      end
      table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
      for _,key in ipairs(keys) do
        lines[#lines+1]=tostring(key)..": "..compactValue(message[key])
      end
    end
  else
    lines[1]=compactValue(message)
  end
  while #lines>CONFIG.SABLE_MAX_LINES do table.remove(lines) end
  state.sable={title=title,lines=lines,sender=sender,lastAt=os.epoch("utc")/1000,
    modemAvailable=state.sable.modemAvailable}
end

local function inferOwner(details, eyeX, eyeY, eyeZ)
  if CONFIG.OWNER_NAME and details[CONFIG.OWNER_NAME] then return CONFIG.OWNER_NAME end
  local bestName, bestDistance = nil, math.huge
  for name, p in pairs(details) do
    if p and p.x and p.y and p.z then
      local d = distance({x=eyeX,y=eyeY,z=eyeZ}, p)
      if d < bestDistance then bestName, bestDistance = name, d end
    end
  end
  -- Eye position should be inside the wearer's player hitbox. Avoid guessing
  -- when every returned player is far away.
  if bestDistance <= 3.0 then return bestName end
  return CONFIG.OWNER_NAME
end

local function refreshPlayers()
  local online, err = safeCall(detector.getOnlinePlayers)
  if type(online) ~= "table" then
    state.warning = "Detector error: " .. abbreviate(err or "no player list", 32)
    return
  end

  local details = {}
  local onlineNames={}
  for _,name in pairs(online) do
    if type(name)=="string" then onlineNames[name:lower()]=true end
  end
  local now=os.epoch("utc")/1000

  -- Target and wearer details have their own staggered refresh paths. Reuse
  -- them here so the roster tick itself performs no redundant detail calls.
  if state.trackedName and type(state.details[state.trackedName])=="table" then
    local trackedOnline=onlineNames[state.trackedName:lower()]==true
    local trackedFresh=state.trackedLastSeen and
      now-state.trackedLastSeen<=CONFIG.TRACKED_OFFLINE_GRACE_SECONDS
    if trackedOnline or trackedFresh then
      details[state.trackedName]=state.details[state.trackedName]
      if trackedOnline then state.trackedLastSeen=now end
    end
  end
  if CONFIG.OWNER_NAME and type(state.owner)=="table" then
    details[CONFIG.OWNER_NAME]=state.owner
  end
  -- Do not fetch every player's details here. That burst used to block the HUD
  -- once per roster refresh. Reuse cached entries and refresh them round-robin.
  for _,name in pairs(online) do
    if type(name)=="string" and not details[name] and
       type(state.details[name])=="table" then
      details[name]=state.details[name]
    end
  end

  -- Some AP 0.8 builds omit the glasses wearer from getOnlinePlayers() even
  -- though getPlayer(name) can still resolve them. Fetch the configured wearer
  -- explicitly so a chat-only self target is not marked offline on roster tick.
  if CONFIG.OWNER_NAME and not details[CONFIG.OWNER_NAME] then
    local wearer=safeCall(detector.getPlayer,CONFIG.OWNER_NAME)
    if type(wearer)=="table" then details[CONFIG.OWNER_NAME]=wearer end
  end

  -- Player Detector lookups can fail for a single polling cycle even while the
  -- wearer is present. Keep the last valid wearer record (especially yaw), or
  -- the compass disappears until a later successful lookup.
  if state.ownerName and not details[state.ownerName] and
     type(state.owner)=="table" then
    details[state.ownerName]=state.owner
  end

  if state.trackedName and not details[state.trackedName] and
     type(state.details[state.trackedName])=="table" then
    local confirmedOnline=onlineNames[state.trackedName:lower()]==true
    local withinGrace=state.trackedLastSeen and
      now-state.trackedLastSeen<=CONFIG.TRACKED_OFFLINE_GRACE_SECONDS
    if confirmedOnline or withinGrace then
      details[state.trackedName]=state.details[state.trackedName]
      if confirmedOnline then state.trackedLastSeen=now end
    end
  end

  local eyeX, eyeY, eyeZ = safeCall(overlay.getEyePosition)
  if tonumber(eyeX) and tonumber(eyeY) and tonumber(eyeZ) then
    state.eye = {x=eyeX,y=eyeY,z=eyeZ}
    state.ownerName = inferOwner(details, eyeX, eyeY, eyeZ)
  end
  local refreshedOwner=state.ownerName and details[state.ownerName] or nil
  if type(refreshedOwner)=="table" then
    state.owner=refreshedOwner
    state.lastOwnerYaw=tonumber(refreshedOwner.yaw) or state.lastOwnerYaw
  end
  state.currentDimension=state.owner and normalizeDimension(state.owner.dimension) or nil
  if not state.currentDimension and environmentDetector then
    local dim
    if type(environmentDetector.getDimensionPaN)=="function" then
      dim=safeCall(environmentDetector.getDimensionPaN)
    end
    if not dim and type(environmentDetector.getDimension)=="function" then
      dim=safeCall(environmentDetector.getDimension)
    end
    state.currentDimension=normalizeDimension(dim)
  end

  local players = {}
  for _, name in pairs(online) do
    if type(name) == "string" and name ~= state.ownerName then
      players[#players + 1] = name
    end
  end
  table.sort(players, function(a,b) return a:lower() < b:lower() end)

  local wanted = state.selectedName
  state.players, state.details = players, details
  state.selected = 0
  for i, name in ipairs(players) do
    if name == wanted then state.selected = i break end
  end
  if state.selected == 0 and #players > 0 then state.selected = 1 end
  state.selectedName = state.players[state.selected]
  if state.trackedName and not details[state.trackedName] then
    for name,_ in pairs(details) do
      if name:lower()==state.trackedName:lower() then
        state.trackedName=name
        saveTarget()
        break
      end
    end
  end
  if state.trackedName and not details[state.trackedName] then
    -- Keep its name visible as offline until the next explicit selection.
    state.warning = state.trackedName .. " is offline or unavailable"
  else
    state.warning = nil
  end
end

local function refreshOwnerData()
  local eyeX,eyeY,eyeZ=safeCall(overlay.getEyePosition)
  if tonumber(eyeX) and tonumber(eyeY) and tonumber(eyeZ) then
    state.eye={x=eyeX,y=eyeY,z=eyeZ}
  end
  if state.ownerName then
    local owner=safeCall(detector.getPlayer,state.ownerName)
    if type(owner)=="table" then
      state.owner=owner
      state.lastOwnerYaw=tonumber(owner.yaw) or state.lastOwnerYaw
      state.details[state.ownerName]=owner
    end
  end
end

local function refreshTrackingData()
  if state.trackedName and state.trackedName~=state.ownerName then
    local target=safeCall(detector.getPlayer,state.trackedName)
    if type(target)=="table" then
      state.details[state.trackedName]=target
      state.trackedLastSeen=os.epoch("utc")/1000
    end
  end
  -- Refresh at most one ordinary roster entry per tick. This keeps distance
  -- labels reasonably current without a large synchronous getPlayer burst.
  if #state.players>0 then
    state.detailCursor=(state.detailCursor%#state.players)+1
    local name=state.players[state.detailCursor]
    if name and name~=state.trackedName then
      local info=safeCall(detector.getPlayer,name)
      if type(info)=="table" then state.details[name]=info end
    end
  else
    state.detailCursor=0
  end
end

local function refreshEnvironment()
  if not environmentDetector then
    state.environment={available=false}
    return
  end
  local e={available=true}
  e.biome=safeCall(environmentDetector.getBiome)
  e.dimension=state.currentDimension
  if type(environmentDetector.getDimensionPaN)=="function" then
    e.dimension=normalizeDimension(safeCall(environmentDetector.getDimensionPaN)) or e.dimension
  elseif type(environmentDetector.getDimension)=="function" then
    e.dimension=normalizeDimension(safeCall(environmentDetector.getDimension)) or e.dimension
  end
  e.time=tonumber(safeCall(environmentDetector.getTime))
  e.blockLight=tonumber(safeCall(environmentDetector.getBlockLightLevel))
  e.skyLight=tonumber(safeCall(environmentDetector.getSkyLightLevel))
  if safeCall(environmentDetector.isThunder)==true then e.weather="Thunder"
  elseif safeCall(environmentDetector.isRaining)==true then e.weather="Rain"
  else e.weather="Clear" end
  state.currentDimension=e.dimension or state.currentDimension
  state.environment=e
end

local function updateSpeed(now)
  local p=state.owner
  if not p or not tonumber(p.x) or not tonumber(p.y) or not tonumber(p.z) then return end
  if not state.lastSpeedPos then
    state.lastSpeedPos={x=p.x,y=p.y,z=p.z}
    state.lastSpeedTime=now
    return
  end
  local dt=now-(state.lastSpeedTime or now)
  if dt<CONFIG.SPEED_SAMPLE_SECONDS then return end
  local raw=distance(state.lastSpeedPos,p)/math.max(dt,0.001)
  if raw>1000 then raw=0 end -- Ignore teleports/dimension transitions.
  state.speed=state.speed*0.65+raw*0.35
  if state.speed<0.02 then state.speed=0 end
  state.lastSpeedPos={x=p.x,y=p.y,z=p.z}
  state.lastSpeedTime=now
end

local function formatClock(ticks)
  if not ticks then return "Time --:--" end
  local hours=((ticks%24000)/1000+6)%24
  local h=math.floor(hours)
  local m=math.floor((hours-h)*60)
  return string.format("Time %02d:%02d",h,m)
end

local function formatETA(seconds)
  if not seconds or seconds~=seconds or seconds==math.huge then return "--" end
  seconds=math.max(0,math.floor(seconds+0.5))
  if seconds>=3600 then return string.format("%dh %02dm",math.floor(seconds/3600),math.floor(seconds%3600/60)) end
  return string.format("%02d:%02d",math.floor(seconds/60),seconds%60)
end

local function cycleSelection()
  if #state.players == 0 then return end
  state.selected = state.selected % #state.players + 1
  state.selectedName = state.players[state.selected]
end

local function previousSelection()
  if #state.players == 0 then return end
  state.selected = ((state.selected - 2) % #state.players) + 1
  state.selectedName = state.players[state.selected]
end

local function toggleTracking()
  if not state.selectedName then return end
  -- Choosing a player always replaces a previously selected block target.
  state.blockTarget = nil
  if state.trackedName == state.selectedName then
    state.trackedName = nil
  else
    state.trackedName = state.selectedName
    state.trackedLastSeen=os.epoch("utc")/1000
  end
  saveTarget()
end

local function parseCoordinate(token, origin)
  if type(token) ~= "string" then return nil end
  if token:sub(1, 1) == "~" then
    local offset = token:sub(2)
    if offset == "" then return origin end
    offset = tonumber(offset)
    if not offset then return nil end
    return origin + offset
  end
  return tonumber(token)
end

local function handleChatCommand(sender, message)
  if type(sender) ~= "string" or sender:lower() ~= CONFIG.OWNER_NAME:lower() or
     type(message) ~= "string" then return end

  local words = {}
  for word in message:gmatch("%S+") do words[#words + 1] = word end
  local command = (words[1] or ""):lower()
  -- Depending on the server/chat integration, the hidden-message marker may
  -- be present in the event text or already removed. Accept either form.
  local configured = CONFIG.CHAT_COMMAND:lower()
  if command ~= configured and command ~= configured:gsub("^%$", "") then return end

  if (words[2] or ""):lower() == "clear" then
    state.blockTarget = nil
    state.trackedName = nil
    state.warning = nil
    saveTarget()
    return
  end

  -- A single argument is a player name: $target Username
  if words[2] and not words[3] then
    local requested=words[2]
    if requested:lower()==CONFIG.OWNER_NAME:lower() then
      state.warning="Cannot target the glasses wearer"
      return
    end
    -- Refresh and resolve through the exact same roster used by the keyboard
    -- selection menu. Never use a name field returned inside getPlayer data as
    -- the persistent identifier: some AP builds return a display/entity name.
    refreshPlayers()
    local rosterIndex=nil
    for i,name in ipairs(state.players) do
      if name:lower()==requested:lower() then rosterIndex=i break end
    end
    if rosterIndex then
      state.selected=rosterIndex
      state.selectedName=state.players[rosterIndex]
      state.blockTarget=nil
      state.trackedName=state.selectedName
      state.warning=nil
      state.trackedLastSeen=os.epoch("utc")/1000
    else
      -- Preserve an unavailable name instead of rejecting it. The regular
      -- detector refresh will attach live data automatically when they join.
      state.blockTarget=nil
      state.trackedName=requested
      state.warning=requested.." is offline; target saved"
      state.trackedLastSeen=nil
    end
    saveTarget()
    return
  end

  local origin = state.owner or state.eye
  if not origin then
    state.warning = "Cannot resolve relative coordinates"
    return
  end
  local x = parseCoordinate(words[2], origin.x)
  local y = parseCoordinate(words[3], origin.y)
  local z = parseCoordinate(words[4], origin.z)
  if not x or not y or not z then
    state.warning = "Use: $target X Y Z"
    return
  end

  local dimension = words[5] or (state.owner and state.owner.dimension) or state.currentDimension
  if not dimension and environmentDetector and
     type(environmentDetector.getDimensionPaN) == "function" then
    dimension = safeCall(environmentDetector.getDimensionPaN)
  end
  if not dimension and environmentDetector and
     type(environmentDetector.getDimension) == "function" then
    dimension = safeCall(environmentDetector.getDimension)
  end
  dimension=normalizeDimension(dimension)
  if not dimension then
    state.warning = "Add dimension, e.g. minecraft:overworld"
    return
  end
  state.blockTarget = {
    x = math.floor(x), y = math.floor(y), z = math.floor(z),
    dimension = dimension,
  }
  state.trackedName = nil
  state.warning = nil
  saveTarget()
end

local function calculateLookTarget(blockState)
  if not distanceDetector then return nil end
  local hitDistance = tonumber(safeCall(distanceDetector.calculateDistance))
  if not hitDistance or hitDistance < 0 then return nil end

  local owner = state.ownerName and safeCall(detector.getPlayer, state.ownerName) or state.owner
  if type(owner) ~= "table" or not owner.yaw or not owner.pitch then return nil end
  state.owner = owner
  local eyeX, eyeY, eyeZ = safeCall(overlay.getEyePosition)
  if not tonumber(eyeX) then
    eyeX, eyeY, eyeZ = owner.x, owner.y + (owner.eyeHeight or 1.62), owner.z
  end
  state.eye = {x=eyeX, y=eyeY, z=eyeZ}

  local yaw, pitch = math.rad(owner.yaw), math.rad(owner.pitch)
  local dirX = -math.sin(yaw) * math.cos(pitch)
  local dirY = -math.sin(pitch)
  local dirZ =  math.cos(yaw) * math.cos(pitch)
  local inside = hitDistance + 0.02
  local result = {
    x=math.floor(eyeX + dirX * inside),
    y=math.floor(eyeY + dirY * inside),
    z=math.floor(eyeZ + dirZ * inside),
    dimension=owner.dimension,
    measuredDistance=hitDistance,
    selectable=hitDistance <= CONFIG.BLOCK_TARGET_RANGE,
  }
  if type(blockState) == "table" then
    result.name = blockState.name or blockState.id or blockState.Name
  end
  return result
end

local function selectLookedAtBlock(blockState)
  if not distanceDetector then
    state.warning="Distance Detector is not equipped"
    return
  end

  local looked = calculateLookTarget(blockState)
  if not looked then
    state.warning="No block in detector range"
    return
  end
  state.blockTarget = looked
  state.trackedName=nil
  state.warning=nil
  saveTarget()
end

local function rowStatus(name)
  local p, owner = state.details[name], state.owner
  if not p then return " ?" end
  if owner and p.dimension == owner.dimension then
    return string.format(" %.0fm", distance(owner, p))
  end
  if p.dimension then
    local dim = tostring(p.dimension):match("[^:]+$") or tostring(p.dimension)
    return " [" .. abbreviate(dim, 8) .. "]"
  end
  return " [?]"
end

local function hideArrow()
  setEnabled(ui.arrowShaft, false)
  setEnabled(ui.arrowHead1, false)
  setEnabled(ui.arrowHead2, false)
  setEnabled(ui.compassRing,false)
  for _,tick in ipairs(ui.compassTicks or {}) do setEnabled(tick,false) end
end

local function drawArrow(layout, owner, target)
  -- Keep the bezel visible whenever a target exists. Directional data may be
  -- briefly unavailable during an AP detector miss, but that should not make
  -- the entire compass blink out.
  local hasTarget=type(target)=="table"
  setEnabled(ui.compassRing,hasTarget)
  for _,tick in ipairs(ui.compassTicks or {}) do setEnabled(tick,hasTarget) end
  local yaw=tonumber(owner and owner.yaw) or state.lastOwnerYaw
  local eye=state.eye or owner
  local tx,tz=tonumber(target and target.x),tonumber(target and target.z)
  local ex,ez=tonumber(eye and eye.x),tonumber(eye and eye.z)
  if not target or not yaw or not tx or not tz or not ex or not ez then
    setEnabled(ui.arrowShaft,false)
    setEnabled(ui.arrowHead1,false)
    setEnabled(ui.arrowHead2,false)
    return
  end
  state.lastOwnerYaw=yaw
  local dx,dz=tx-ex,tz-ez
  local atan2=math.atan2 or function(y,x) return math.atan(y,x) end
  local targetYaw=math.deg(atan2(-dx,dz))
  local yawError=normalizeAngle(targetYaw-yaw)

  -- Rotate through 360 degrees using horizontal bearing only. Zero error points
  -- upward, positive error rotates clockwise, and elevation is ignored.
  local angle=math.rad(yawError)
  local vx,vy=math.sin(angle),-math.cos(angle)
  local px,py=-vy,vx
  local centerX,centerY=ui.arrowCenterX,ui.arrowCenterY
  local arrowLen,head=14*layout.font,5*layout.font
  local tipX=centerX+vx*arrowLen/2
  local tipY=centerY+vy*arrowLen/2
  local baseX=centerX-vx*arrowLen/2
  local baseY=centerY-vy*arrowLen/2
  setLineGeometry(ui.arrowShaft,baseX,baseY,tipX,tipY)
  setLineGeometry(ui.arrowHead1,tipX,tipY,
    tipX-vx*head+px*head*0.65,tipY-vy*head+py*head*0.65)
  setLineGeometry(ui.arrowHead2,tipX,tipY,
    tipX-vx*head-px*head*0.65,tipY-vy*head-py*head*0.65)
  setEnabled(ui.arrowShaft,true); setEnabled(ui.arrowHead1,true); setEnabled(ui.arrowHead2,true)
end

local function render(layout)
  local maxChars = math.max(8, math.floor((layout.panelW-10)/(6*layout.font)))
  local showPlayers=state.hud.players
  setEnabled(ui.listBg,showPlayers); setEnabled(ui.listAccent,showPlayers)
  setEnabled(ui.listTitle,showPlayers); setEnabled(ui.pageText,showPlayers)
  local pages = math.max(1, math.ceil(#state.players/layout.rows))
  state.page = state.selected > 0 and math.floor((state.selected-1)/layout.rows)+1 or 1
  state.page = clamp(state.page,1,pages)
  local first = (state.page-1)*layout.rows+1
  local selectedRow=state.selected-first+1
  if showPlayers and selectedRow>=1 and selectedRow<=layout.rows then
    local rowY=layout.margin+4*layout.font+layout.lineH*(selectedRow+1)-1
    setObjectPos(ui.rowHighlight,layout.w-layout.margin-layout.panelW+2*layout.font,rowY,0.5)
    setEnabled(ui.rowHighlight,true)
  else
    setEnabled(ui.rowHighlight,false)
  end
  for row=1,layout.rows do
    local index, obj = first+row-1, ui.rows[row]
    local name = state.players[index]
    if name then
      local prefix, color = "  ", CONFIG.COLORS.normal
      if state.trackedName == name then prefix, color = "* ", CONFIG.COLORS.tracked end
      if state.selected == index then prefix, color = "> ", CONFIG.COLORS.highlight end
      local status = rowStatus(name)
      local allowed = math.max(3,maxChars-#prefix-#status)
      setText(obj,prefix..abbreviate(name,allowed)..status,color)
      setEnabled(obj,showPlayers)
    else setEnabled(obj,false) end
  end
  setText(ui.pageText,string.format("%d online | page %d/%d",#state.players,state.page,pages),CONFIG.COLORS.muted)

  local sable=state.sable or {}
  local showSable=state.hud.sable
  setEnabled(ui.sableBg,showSable); setEnabled(ui.sableAccent,showSable)
  setEnabled(ui.sableTitle,showSable); setEnabled(ui.sableStatus,showSable)
  local now=os.epoch("utc")/1000
  local age=sable.lastAt and math.max(0,now-sable.lastAt) or nil
  local stale=age and age>CONFIG.SABLE_STALE_SECONDS
  local sableChars=math.max(10,math.floor((ui.sableWidth-10)/(5*layout.font)))
  setText(ui.sableTitle,abbreviate(sable.title or "SABLE TELEMETRY",sableChars),CONFIG.COLORS.title)
  local linkStatus
  if sable.modemAvailable==false then linkStatus="Wireless modem unavailable"
  elseif not age then linkStatus="Waiting on "..CONFIG.SABLE_PROTOCOL
  elseif stale then linkStatus=string.format("Link #%s | stale %.0fs",sable.sender or "?",age)
  else linkStatus=string.format("Link #%s | live",sable.sender or "?") end
  setText(ui.sableStatus,abbreviate(linkStatus,sableChars),stale and CONFIG.COLORS.danger or
    (age and CONFIG.COLORS.tracked or CONFIG.COLORS.muted))
  for i,obj in ipairs(ui.sableLines or {}) do
    local line=sable.lines and sable.lines[i]
    setText(obj,line and abbreviate(line,sableChars) or "",CONFIG.COLORS.normal)
    setEnabled(obj,showSable and line~=nil)
  end

  local e=state.environment or {}
  local showEnvironment=state.hud.environment
  setEnabled(ui.envBg,showEnvironment); setEnabled(ui.envAccent,showEnvironment)
  local dim=(e.dimension and (tostring(e.dimension):match("[^:]+$") or tostring(e.dimension))) or "unknown"
  local biome=(e.biome and (tostring(e.biome):match("[^:]+$") or tostring(e.biome))) or "unknown"
  local envLines
  if e.available==false then
    envLines={"ENVIRONMENT","Detector unavailable","",""}
  else
    envLines={"ENVIRONMENT",abbreviate(dim,14).." | "..abbreviate(biome,16),
      formatClock(e.time).." | "..tostring(e.weather or "--"),
      string.format("Light: block %s | sky %s",e.blockLight or "--",e.skyLight or "--")}
  end
  for i,obj in ipairs(ui.envLines or {}) do
    setText(obj,envLines[i] or "",i==1 and CONFIG.COLORS.title or CONFIG.COLORS.normal)
    setEnabled(obj,showEnvironment)
  end

  local t = state.blockTarget or (state.trackedName and state.details[state.trackedName] or nil)
  local targetDistance=nil
  local ownerDim=normalizeDimension(state.owner and state.owner.dimension) or state.currentDimension
  if t and state.owner and ownerDim==normalizeDimension(t.dimension) then
    local targetPos=t
    if state.blockTarget then targetPos={x=t.x+0.5,y=t.y+0.5,z=t.z+0.5} end
    targetDistance=distance(state.owner,targetPos)
  end
  local eta=(targetDistance and state.speed>=0.10) and targetDistance/state.speed or nil
  local moveLines={"MOVEMENT",string.format("Speed: %.1f m/s",state.speed or 0),
    targetDistance and string.format("Target: %.1f m",targetDistance) or "Target: unavailable",
    "ETA: "..formatETA(eta)}
  for i,obj in ipairs(ui.moveLines or {}) do
    setText(obj,moveLines[i],i==1 and CONFIG.COLORS.title or
      (i==4 and eta and CONFIG.COLORS.tracked or CONFIG.COLORS.normal))
    setEnabled(obj,state.hud.movement)
  end
  setEnabled(ui.moveBg,state.hud.movement); setEnabled(ui.moveAccent,state.hud.movement)

  local showKeys=state.keyboardOpen and state.hud.keyHelp and not state.hudMenuOpen
  setEnabled(ui.keysBg,showKeys)
  setEnabled(ui.keysAccent,showKeys)
  for _,obj in ipairs(ui.keyLines or {}) do setEnabled(obj,showKeys) end
  local lines = {}
  if state.blockTarget then
    local b=state.blockTarget
    local dim=tostring(b.dimension or "unknown"):match("[^:]+$") or tostring(b.dimension or "unknown")
    local from=state.eye or state.owner
    local liveDistance=from and distance(from,{x=b.x+0.5,y=b.y+0.5,z=b.z+0.5}) or b.measuredDistance
      lines={"BLOCK TARGET",
      string.format("XYZ: %d, %d, %d",b.x,b.y,b.z),
      "Dimension: "..dim,
      liveDistance and string.format("Distance: %.1f m",liveDistance) or "Distance: unavailable",
      "Chat $target: replace",
      "Enter: target player",
      state.warning or ""}
  elseif not state.trackedName then
    if keyboard then
      lines={"NO TARGET","Arrows: select","Enter: track","Middle-click/B: block","Backspace: clear","",state.warning or ""}
    else
      lines={"NO TARGET","Tap: select","Hold: track","","","",state.warning or ""}
    end
  elseif not t then
    lines={"TARGET: "..state.trackedName,"Unavailable / offline","","","","",state.warning or ""}
  else
    local dim=tostring(t.dimension or "unknown"):match("[^:]+$") or tostring(t.dimension or "unknown")
    local same=state.owner and
      (normalizeDimension(state.owner.dimension) or state.currentDimension)==normalizeDimension(t.dimension)
    lines={"TARGET: "..state.trackedName,
      string.format("XYZ: %d, %d, %d",round(t.x),round(t.y),round(t.z)),
      "Dimension: "..dim,
      same and string.format("Distance: %.1f m",distance(state.owner,t)) or "Distance: different dimension",
      t.health and string.format("Health: %.1f / %.1f",t.health,t.maxHealth or t.health) or "Health: unavailable",
      same and "Direction: horizontal" or "Direction: unavailable",
      state.warning or ""}
  end
  for i,obj in ipairs(ui.targetLines) do
    local color=i==1 and CONFIG.COLORS.title or (i==7 and CONFIG.COLORS.danger or CONFIG.COLORS.normal)
    setText(obj,abbreviate(lines[i] or "",maxChars),color)
    setEnabled(obj,state.hud.target)
  end
  setEnabled(ui.targetBg,state.hud.target); setEnabled(ui.targetAccent,state.hud.target)
  if state.hud.compass then drawArrow(layout,state.owner,t) else hideArrow() end

  local showMenu=state.hudMenuOpen
  setEnabled(ui.hudMenuBg,showMenu); setEnabled(ui.hudMenuAccent,showMenu)
  setEnabled(ui.hudMenuTitle,showMenu); setEnabled(ui.hudMenuHint,showMenu)
  for i,obj in ipairs(ui.hudMenuRows or {}) do
    local item=HUD_MENU_ITEMS[i]
    local selected=i==state.hudMenuSelected
    local mark=state.hud[item.key] and "[ON]  " or "[OFF] "
    setText(obj,(selected and "> " or "  ")..mark..item.label,
      selected and CONFIG.COLORS.highlight or
      (state.hud[item.key] and CONFIG.COLORS.tracked or CONFIG.COLORS.muted))
    setEnabled(obj,showMenu)
  end
end

local function updateLoop()
  local lastRoster=0
  local lastOwnerRefresh=0
  local lastDetectorRefresh=0
  local lastKeyboardCheck=0
  local lastEnvironment=0
  while true do
    local layout=getLayout()
    if layout.key~=state.layoutKey then rebuildUI(layout) end
    local now=os.epoch("utc")/1000
    local targetHudActive=state.hud.target or state.hud.compass or state.hud.movement
    local ownerDataNeeded=state.hud.players or targetHudActive
    local rosterNeeded=state.hud.players or (state.trackedName and targetHudActive)
    local targetDataNeeded=state.trackedName and targetHudActive

    if ownerDataNeeded and
       (lastOwnerRefresh==0 or now-lastOwnerRefresh>=CONFIG.OWNER_REFRESH_SECONDS) then
      refreshOwnerData()
      lastOwnerRefresh=now
    end
    if rosterNeeded and (lastRoster==0 or now-lastRoster>=CONFIG.ROSTER_SECONDS) then
      refreshPlayers()
      lastRoster=now
      lastOwnerRefresh=now
      lastDetectorRefresh=now
    elseif (targetDataNeeded or state.hud.players) and
       (lastDetectorRefresh==0 or now-lastDetectorRefresh>=CONFIG.DETECTOR_REFRESH_SECONDS) then
      refreshTrackingData()
      lastDetectorRefresh=now
    end
    if state.hud.movement then updateSpeed(now)
    else
      state.lastSpeedPos=nil
      state.lastSpeedTime=nil
    end
    if state.hud.environment and
       (lastEnvironment==0 or now-lastEnvironment>=CONFIG.ENVIRONMENT_SECONDS) then
      refreshEnvironment()
      lastEnvironment=now
    end
    if keyboard and (lastKeyboardCheck==0 or
       now-lastKeyboardCheck>=CONFIG.KEYBOARD_STATE_SECONDS) then
      local open=safeCall(keyboard.isCapturingKeys)
      if open~=nil then
        if open==true then state.keyboardOpen=true
        elseif not state.hudMenuOpen then state.keyboardOpen=false end
      end
      lastKeyboardCheck=now
    end
    render(layout)
    if uiDirty then
      overlay.update()
      uiDirty=false
    end
    sleep(CONFIG.REFRESH_SECONDS)
  end
end

local function inputLoop()
  while true do
    local event,a,b,c=os.pullEvent()
    if event=="rednet_message" and state.hud.sable then
      handleSableTelemetry(a,b,c)
    end
    if event=="chat" and chatBox then
      -- AP chat event: UUID, player name, message, hidden, encoded message.
      handleChatCommand(b,c)
    end
    if keyboard then
      -- The shared Smart Glasses hotkey opens the Keyboard Module. Ignore the
      -- simultaneous glasses_key_pressed event so opening it never changes the
      -- selection. Standard CC key events arrive while its screen is open.
      if event=="keyboard_open" then
        state.keyboardOpen=true
      elseif event=="keyboard_close" then
        state.keyboardOpen=false
        state.hudMenuOpen=false
      elseif event=="glasses_key_pressed" and state.hudMenuOpen then
        -- The shared glasses hotkey is also how Keyboard Mode is left.
        state.hudMenuOpen=false
      elseif event=="char" and type(a)=="string" and a:lower()=="m" then
        state.keyboardOpen=true
        state.hudMenuOpen=not state.hudMenuOpen
      elseif event=="key" then
        state.keyboardOpen=true
        local code=a
        if state.hudMenuOpen then
          if code==keys.escape then
            state.hudMenuOpen=false
          elseif code==keys.up then
            state.hudMenuSelected=((state.hudMenuSelected-2)%#HUD_MENU_ITEMS)+1
          elseif code==keys.down or code==keys.tab then
            state.hudMenuSelected=(state.hudMenuSelected%#HUD_MENU_ITEMS)+1
          elseif code==keys.enter or code==keys.numPadEnter or code==keys.space or
                 code==keys.left or code==keys.right then
            local item=HUD_MENU_ITEMS[state.hudMenuSelected]
            state.hud[item.key]=not state.hud[item.key]
            saveHudSettings()
          end
        elseif code==keys.up or code==keys.left then
          previousSelection()
        elseif code==keys.down or code==keys.right or code==keys.tab then
          cycleSelection()
        elseif code==keys.enter or code==keys.numPadEnter or code==keys.space then
          toggleTracking()
        elseif code==keys.b then
          -- Keyboard Mode freezes normal world interaction, so B performs the
          -- long-range ray using the direction held when the screen was opened.
          selectLookedAtBlock()
        elseif code==keys.backspace or code==keys.delete then
          state.trackedName=nil
          state.blockTarget=nil
          saveTarget()
        elseif code==keys.home and #state.players>0 then
          state.selected=1
          state.selectedName=state.players[1]
        elseif code==keys['end'] and #state.players>0 then
          state.selected=#state.players
          state.selectedName=state.players[state.selected]
        end
      elseif event=="player_interaction" and a==CONFIG.BLOCK_TARGET_BUTTON then
        -- World interaction events fire during normal gameplay, not while a
        -- container GUI such as Keyboard Mode is open.
        selectLookedAtBlock(b)
      end
    elseif event=="glasses_key_pressed" then
      local duration=tonumber(b) or 0
      if duration>=CONFIG.HOLD_MS then toggleTracking() else cycleSelection() end
    end
  end
end

local function main()
  local autoWasOn=safeCall(overlay.isAutoUpdating)
  -- Overlay objects can survive a forced stop or glasses-computer reboot. Clear
  -- those orphaned objects once before rebuilding this script's current HUD.
  pcall(overlay.clear)
  pcall(overlay.update)
  local laserWasVisible
  local modemFound=false
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name,"modem") then
      local modem=peripheral.wrap(name)
      if safeCall(modem.isWireless)==true then
        modemFound=true
        if not rednet.isOpen(name) then
          local opened=pcall(rednet.open,name)
          if opened and rednet.isOpen(name) then openedRednetNames[#openedRednetNames+1]=name end
        end
      end
    end
  end
  state.sable.modemAvailable=modemFound
  loadTarget()
  if keyboard then state.keyboardOpen=safeCall(keyboard.isCapturingKeys)==true end
  if distanceDetector then
    -- Block-only mode ensures entities do not stop the targeting ray.
    pcall(distanceDetector.setDetectionMode,"BLOCK")
    pcall(distanceDetector.setIgnoreTransparency,false)
    pcall(distanceDetector.setMaxRange,CONFIG.BLOCK_TARGET_RANGE)
    -- Older tracker versions enabled persistent periodic rays. That setting is
    -- stored by the peripheral and can survive a Ctrl+T termination, producing
    -- block-dependent flashing even after live look checks were removed.
    -- B uses calculateDistance directly, so periodic calculation must stay off.
    pcall(distanceDetector.setCalculatePeriodically,false)
    laserWasVisible=safeCall(distanceDetector.laserVisibility)
    -- Dwell scanning is synchronous and one-shot; keep its physical laser
    -- hidden so a completed check does not flash in the world.
    pcall(distanceDetector.setLaserVisibility,false)
  end
  if keyboard and distanceDetector then
    -- Configure this before opening the Keyboard container. Changing module
    -- data from inside keyboard_open can make AP 0.8 close that container.
    pcall(keyboard.setHandlingInteraction,CONFIG.BLOCK_TARGET_BUTTON,true)
  end
  -- Batch all setters into one synchronization packet per frame. Leaving auto
  -- update enabled here causes dozens of packets and visible stutter.
  overlay.setAutoUpdate(false)
  local ok,err=pcall(function() parallel.waitForAny(updateLoop,inputLoop) end)
  if keyboard and distanceDetector then
    pcall(keyboard.setHandlingInteraction,CONFIG.BLOCK_TARGET_BUTTON,false)
  end
  if distanceDetector then
    if laserWasVisible~=nil then pcall(distanceDetector.setLaserVisibility,laserWasVisible) end
  end
  for _,name in ipairs(openedRednetNames) do pcall(rednet.close,name) end
  removeOwned()
  pcall(overlay.update)
  if autoWasOn==true then pcall(overlay.setAutoUpdate,true) end
  if not ok then error(err,0) end
end

main()
