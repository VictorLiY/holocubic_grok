-- Grok Bot —— HoloCubic 上的 Grok Ball 表情动画
--
-- 数据与算法移植自 grok-ball（MIT）：25 组 48 点眼环逐点弹簧形变，
-- 眼睛按球面投影贴合球体，配合眨眼 / 呼吸 / 自旋 / 待机张望产生生命感。
-- 32 套表情见 package/grok_data.lua（由 scripts/gen_data.mjs 生成）。
--
-- 按键：← → 切换表情，↑ 自旋一圈，↓ 弹跳，HOME 退出
-- 无操作 15 秒后自动巡演全部表情（每 5.2 秒一个）

local APP_DIR = "/sd/apps/grok_bot"

if file and file.exists and not file.exists(APP_DIR .. "/main.lua") then
  for _, dir in ipairs({ "grok_bot/package", "grok_bot" }) do
    if file.exists(dir .. "/main.lua") then
      APP_DIR = dir
      break
    end
  end
end

-- 热重载时先停掉上一份实例
if _G.__grok_bot and _G.__grok_bot.stop then
  pcall(_G.__grok_bot.stop)
end

local function write_text(path, text)
  if io and io.open then
    local ok, fd = pcall(io.open, path, "w")
    if ok and fd then
      pcall(fd.write, fd, text)
      pcall(fd.close, fd)
      return true
    end
  end
  if file and file.open then
    local fd = file.open(path, "w")
    if fd then
      pcall(fd.write, fd, text)
      pcall(fd.close, fd)
      return true
    end
  end
  return false
end

local ok_data, D = pcall(dofile, APP_DIR .. "/grok_data.lua")
if not ok_data or type(D) ~= "table" then
  write_text(APP_DIR .. "/error.txt", "grok_data.lua: " .. tostring(D) .. "\n")
  return
end

local Ball = dofile(APP_DIR .. "/grok_ball.lua")
local Engine = dofile(APP_DIR .. "/grok_engine.lua")

local ok_cfg, config = pcall(dofile, APP_DIR .. "/config.lua")
if not ok_cfg or type(config) ~= "table" then
  config = {}
end

local SCREEN_W = 320
local SCREEN_H = 240
local MAIN_STYLE = (LV_PART_MAIN or 0) | (LV_STATE_DEFAULT or 0)

local APP = {
  stopped = false,
  last_input = 0,
  tour_next = 0,
  shown_id = nil,
}
_G.__grok_bot = APP

local engine, ball, timer, hint, start_ms

local function millis_now()
  return millis()
end

local tmr_now_fn = tmr and tmr.now

local function now_us()
  local ok, v = pcall(tmr_now_fn)
  if ok and type(v) == "number" then return v end
  return 0
end

local function set_hint(text, color)
  if not hint then return end
  pcall(lv_label_set_text, hint, text)
  if color then pcall(lv_obj_set_style_text_color, hint, color, MAIN_STYLE) end
end

local function index_of(id)
  local list = engine.list
  for i = 1, #list do
    if list[i].id == id then return i end
  end
  return 1
end

local function switch_to(id, touch)
  if not engine then return end
  engine:set_emotion(id)
  if touch then
    APP.last_input = millis_now()
    APP.tour_next = APP.last_input + (config.tour_delay or 15000) + (config.tour_step or 5200)
  end
end

local function step(delta, touch)
  if not engine then return end
  local list = engine.list
  local i = index_of(engine:emotion_id())
  i = (i - 1 + delta) % #list + 1
  switch_to(list[i].id, touch)
end

function APP.stop(reason)
  if APP.stopped then return end
  APP.stopped = true
  if timer then
    pcall(function() timer:unregister() end)
    timer = nil
  end
  if key and key.off then pcall(key.off) end
  if ball then ball.confetti = {} end
  engine = nil
  ball = nil
  if reason == "exit" and app and app.exit then pcall(app.exit) end
end

-- 性能统计：累计 N 帧后写一行到 perf.txt（仅 config.perf_log 打开时）
local function perf_record(cost_ms, wall_ms, eng_ms)
  local pf = APP.perf
  pf.n = pf.n + 1
  pf.cost = pf.cost + cost_ms
  pf.eng = pf.eng + eng_ms
  if pf.n >= (config.perf_frames or 200) then
    local line = string.format("frames=%d fps=%.1f cost=%.1fms engine=%.1fms\n",
      pf.n, pf.n * 1000 / math.max(1, wall_ms), pf.cost / pf.n, pf.eng / pf.n)
    if ball then
      local bp = ball:take_prof()
      if bp then
        line = line .. string.format("canvas bg=%.1f body=%.1f eye=%.1f fx=%.1f\n",
          bp.bg, bp.body, bp.eye, bp.fx)
      end
    end
    if lv_lvgl_monitor_get then
      local ok, rc, ts, pxs = pcall(lv_lvgl_monitor_get)
      if ok then
        line = line .. string.format("lvgl render_cnt=%s time_sum=%s px=%s\n",
          tostring(rc), tostring(ts), tostring(pxs))
      end
    end
    write_text(APP_DIR .. "/perf.txt", line)
    pf.n, pf.cost, pf.eng, pf.wall = 0, 0, 0, now_us() / 1000
  end
end

local function frame()
  local now = millis_now()
  local frame_us = now_us()
  local tour_delay = config.tour_delay or 15000

  -- 自动巡演：久无操作时轮流展示全部表情
  if now - APP.last_input >= tour_delay and now >= APP.tour_next then
    step(1, false)
    APP.tour_next = now + (config.tour_step or 5200)
  end

  local t_a = now_us()
  local pose = engine:tick(now)
  local t_b = now_us()

  local burst = engine:take_burst()
  if burst > 0 then ball:burst(burst) end

  ball:render(pose, now, engine._dt)

  -- HUD：前几秒显示操作提示，之后显示当前序号
  if hint then
    local def = engine:emotion()
    if now - start_ms >= 4500 and APP.shown_id ~= def.id then
      APP.shown_id = def.id
      set_hint(string.format("%s / %d", def.id, #engine.list), 0x4A4C52)
    end
  end

  -- 调试：延时导出屏幕截图到 APP_DIR/shot.png
  if config.snapshot_ms and not APP.snapshot_done and now - start_ms >= config.snapshot_ms then
    APP.snapshot_done = true
    local ok, err = pcall(function()
      local snap = lv_snapshot_take(lv_scr_act(), LV_IMG_CF_TRUE_COLOR)
      if snap then
        lv_snapshot_save_to_png(snap, APP_DIR .. "/shot.png")
        lv_snapshot_free(snap)
      end
    end)
    if not ok then write_text(APP_DIR .. "/error.txt", "snapshot: " .. tostring(err) .. "\n") end
  end

  if config.perf_log then
    local t_end = now_us()
    perf_record((t_end - frame_us) / 1000, t_end / 1000 - APP.perf.wall, (t_b - t_a) / 1000)
  end
end

local function tick()
  if APP.stopped or not engine then return end
  if app and app.exiting and app.exiting() then
    APP.stop()
    return
  end

  local ok, err = pcall(frame)
  if not ok then
    write_text(APP_DIR .. "/error.txt", tostring(err) .. "\n")
    APP.stop()
  end
end

local function start()
  local root = lv_scr_act()
  pcall(lv_obj_set_style_bg_color, root, config.bg or 0x0B0C10, MAIN_STYLE)
  pcall(lv_obj_set_style_bg_opa, root, 255, MAIN_STYLE)
  if lv_obj_clear_flag and LV_OBJ_FLAG_SCROLLABLE then
    pcall(lv_obj_clear_flag, root, LV_OBJ_FLAG_SCROLLABLE)
  end

  local canvas = lv_canvas_create(root, SCREEN_W, SCREEN_H, LV_IMG_CF_TRUE_COLOR or 0)
  if not canvas then
    write_text(APP_DIR .. "/error.txt", "lv_canvas_create failed\n")
    return
  end
  pcall(lv_obj_set_pos, canvas, 0, 0)

  hint = lv_label_create(root)
  set_hint(config.hint or "<> switch   ^ spin   v bounce", 0x6E7076)
  pcall(lv_obj_align, hint, LV_ALIGN_BOTTOM_MID or 0, 0, -5)

  ball = Ball.new(canvas, D, {
    cx = config.cx or 160,
    cy = config.cy or 124,
    radius = config.radius or 84,
    bg = config.bg or 0x0B0C10,
  })

  engine = Engine.new(D, {
    emotion = config.start_emotion or "02",
    fallback = config.fallback_emotion or "02",
    seed = (millis() % 1000) / 10,
  })

  start_ms = millis_now()
  APP.last_input = start_ms
  APP.tour_next = start_ms + (config.tour_delay or 15000) + (config.tour_step or 5200)
  APP.perf = { n = 0, cost = 0, eng = 0, wall = now_us() / 1000 }

  if key and key.on then
    pcall(key.on, key.LEFT, function(evt)
      if evt == key.SHORT then step(-1, true) end
    end)
    pcall(key.on, key.RIGHT, function(evt)
      if evt == key.SHORT then step(1, true) end
    end)
    pcall(key.on, key.UP, function(evt)
      if evt == key.SHORT and engine then
        engine:spin(1)
        APP.last_input = millis_now()
      end
    end)
    pcall(key.on, key.DOWN, function(evt)
      if evt == key.SHORT and engine then
        engine:bounce()
        APP.last_input = millis_now()
      end
    end)
    pcall(key.on, key.HOME, function(evt)
      if evt == key.SHORT then APP.stop("exit") end
    end)
  end

  timer = tmr.create()
  timer:alarm(config.interval or 40, tmr.ALARM_AUTO, tick)
end

pcall(math.randomseed, millis() % 100000)
start()
