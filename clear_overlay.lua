-- Clears overlay objects left behind by stopped Smart Glasses programs.
if type(smartglasses)~="table" or type(smartglasses.modules)~="table" then
  error("Run this inside the worn Smart Glasses computer",0)
end

local overlay=smartglasses.modules["advancedperipherals:overlay"]
if not overlay then error("Overlay Module is not equipped",0) end

local ok,reason=pcall(overlay.clear)
if not ok then error("Could not clear overlay: "..tostring(reason),0) end
pcall(overlay.update)
print("All stored glasses overlay objects cleared.")
