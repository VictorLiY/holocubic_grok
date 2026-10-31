-- tour_driver.lua —— 巡演模拟：跑真正的 main.lua，检查表情遍历顺序
--
-- 由 scripts/preview.mjs --tour=<秒> 加载。canvas 绘制接口在加载前已被摘掉
-- （Ball:render 会直接返回），所以这里只验证调度：定时器 → frame() → 换表情。
-- 结果写进 PREVIEW.tour_log：按出现顺序记录 HUD 上显示过的表情 id。

local PKG = PREVIEW_ARGS.pkg or "/sd/apps/grok_bot"

-- main.lua 用 dofile(APP_DIR .. "/xxx.lua") 加载同目录模块，这里映射到已加载的副本
local modules = {
  ["grok_data.lua"] = GROK_DATA,
  ["grok_ball.lua"] = GROK_BALL,
  ["grok_engine.lua"] = GROK_ENGINE,
  ["config.lua"] = GROK_CONFIG,
  ["wb_status.lua"] = WB_STATUS,
}

function dofile(path)
  local name = tostring(path):match("([^/]+)$")
  local mod = modules[name]
  if mod == nil then error("unexpected dofile: " .. tostring(path)) end
  return mod
end

local src = PREVIEW_ARGS.main_source
assert(load(src, "main.lua"))()

local tick = PREVIEW.timer_cb
assert(tick, "main.lua 没有注册定时器")

local now = 0
local frames = math.floor((PREVIEW_ARGS.seconds or 200) * 1000 / (PREVIEW.timer_ms or 33))
local last = nil
local order = {}
for _ = 1, frames do
  now = now + PREVIEW.timer_ms
  PREVIEW.clock = now
  tick()
  local shown = _G.__grok_bot and _G.__grok_bot.shown_id
  if shown and shown ~= last then
    last = shown
    order[#order + 1] = string.format("%s@%.1fs", shown, now / 1000)
  end
end

PREVIEW.tour_log = table.concat(order, " ")
PREVIEW.tour_count = #order
