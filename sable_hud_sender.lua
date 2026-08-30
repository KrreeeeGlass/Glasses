-- Generic Sable contraption -> Smart Glasses telemetry sender

local PROTOCOL = "sable_hud_v1"
local RECEIVER_ID = nil -- Glasses computer ID; nil broadcasts to every matching HUD.
local SEND_SECONDS = 0.25

local modemName
for _,name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name,"modem") then
    local modem=peripheral.wrap(name)
    local ok,wireless=pcall(modem.isWireless)
    if ok and wireless then modemName=name break end
  end
end
assert(modemName,"A wireless/Ender Modem is required")
if not rednet.isOpen(modemName) then rednet.open(modemName) end

-- Replace this function with readings from your Sable peripherals. You may
-- return {title="...", lines={...}} for exact ordering, a multiline string,
-- or any flat key/value table; the glasses will format arbitrary keys.
local function readTelemetry()
  return {
    title = "SABLE SHIP",
    lines = {
      "Telemetry link ready",
      "Replace readTelemetry()",
      "with ship peripheral data",
    },
  }
end

while true do
  local payload=readTelemetry()
  if RECEIVER_ID then rednet.send(RECEIVER_ID,payload,PROTOCOL)
  else rednet.broadcast(payload,PROTOCOL) end
  sleep(SEND_SECONDS)
end
