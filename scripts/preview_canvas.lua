-- preview_canvas.lua —— 仅供离线预览的 canvas 打桩实现
--
-- 把 HoloCubic 暴露给 Lua 的那一小撮 canvas 接口（fill_bg / draw_rect /
-- draw_line / draw_arc / set_px_color）用纯 Lua 光栅化到一块 320x240 的内存
-- 位图上，用来在 PC 上离线检查真机画面。语义尽量贴近 LVGL：
--   * draw_rect 的 radius = LV_RADIUS_CIRCLE：按"像素中心在圆内"判断，不抗锯齿
--     （与 LVGL 的 radius mask 一致，所以球缘的锯齿能如实复现）
--   * draw_line 1px：横向线段按整数坐标逐点写入，不做抗锯齿
--   * draw_arc：按覆盖率做抗锯齿描边
-- 不实现：文字、图片、变换、blit。
--
-- 由 scripts/preview.mjs 加载；不要放进 package/。

local PV = {}
PREVIEW = PV

PV.W, PV.H = 320, 240
local W, H = PV.W, PV.H
local fb = {}
for i = 1, W * H do fb[i] = 0 end
PV.fb = fb

LV_RADIUS_CIRCLE = 0x7FFF
LV_IMG_CF_TRUE_COLOR = 0
LV_IMG_CF_TRUE_COLOR_ALPHA = 1
LV_IMG_CF_TRUE_COLOR_CHROMA_KEYED = 2

local function clamp01(v)
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end

local function put(x, y, color, opa)
  if x < 0 or y < 0 or x >= W or y >= H then return end
  local i = y * W + x + 1
  if opa and opa < 255 then
    local a = clamp01(opa / 255)
    local d = fb[i]
    local dr, dg, db = (d >> 16) & 0xFF, (d >> 8) & 0xFF, d & 0xFF
    local sr, sg, sb = (color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF
    local r = math.floor(dr + (sr - dr) * a + 0.5)
    local g = math.floor(dg + (sg - dg) * a + 0.5)
    local b = math.floor(db + (sb - db) * a + 0.5)
    fb[i] = r * 65536 + g * 256 + b
  else
    fb[i] = color
  end
end

local ids = 0

function lv_canvas_create(parent, w, h, fmt)
  ids = ids + 1
  return ids
end

function lv_canvas_frame_begin(cvs) end
function lv_canvas_frame_end(cvs) end
function lv_obj_invalidate(obj) end

function lv_canvas_fill_bg(cvs, color, opa)
  for i = 1, W * H do fb[i] = color end
end

function lv_canvas_draw_rect(cvs, x, y, w, h, dsc)
  if type(dsc) == "number" then dsc = { bg_color = dsc } end
  local color = dsc.bg_color or 0
  local opa = dsc.bg_opa or 255
  local r = dsc.radius or 0
  local x0, y0 = math.floor(x), math.floor(y)
  local x1, y1 = x0 + math.floor(w) - 1, y0 + math.floor(h) - 1
  local cx, cy = x0 + w / 2, y0 + h / 2
  local rx, ry = w / 2, h / 2
  local circ = (r == LV_RADIUS_CIRCLE)
  for py = y0, y1 do
    for px = x0, x1 do
      local inside = true
      if circ then
        local dx = (px + 0.5 - cx) / rx
        local dy = (py + 0.5 - cy) / ry
        if dx * dx + dy * dy > 1 then inside = false end
      end
      if inside then put(px, py, color, opa) end
    end
  end
end

local function line_1px(x1, y1, x2, y2, color, opa)
  x1, y1, x2, y2 = math.floor(x1 + 0.5), math.floor(y1 + 0.5), math.floor(x2 + 0.5), math.floor(y2 + 0.5)
  local dx, dy = x2 - x1, y2 - y1
  local steps = math.max(math.abs(dx), math.abs(dy))
  if steps == 0 then
    put(x1, y1, color, opa)
    return
  end
  local sx, sy = dx / steps, dy / steps
  local x, y = x1, y1
  for i = 0, steps do
    put(math.floor(x + 0.5), math.floor(y + 0.5), color, opa)
    x, y = x + sx, y + sy
  end
end

-- 支持两种调用形式：
--   lv_canvas_draw_line(cvs, x1, y1, x2, y2, color[, opa[, width]])
--   lv_canvas_draw_line(cvs, points, point_cnt[, dsc])
function lv_canvas_draw_line(cvs, a, b, c, d, e, f, g)
  if type(a) == "table" then
    local pts, dsc = a, c
    if type(b) == "number" then dsc = e end
    local color = (type(dsc) == "table" and dsc.color) or (type(dsc) == "number" and dsc) or 0xFFFFFF
    local opa = (type(dsc) == "table" and dsc.opa) or 255
    local n = #pts // 2
    for i = 1, n - 1 do
      line_1px(pts[i * 2 - 1], pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], color, opa)
    end
    return
  end
  line_1px(a, b, c, d, e, f or 255)
end

function lv_canvas_draw_arc(cvs, cx, cy, radius, a1, a2, color, opa, width)
  if type(color) == "table" then
    width = color.width or 1
    opa = color.opa or 255
    color = color.color or 0xFFFFFF
  end
  opa = opa or 255
  width = width or 1
  local r_out = radius + width / 2
  local r_in = radius - width / 2
  if r_in < 0 then r_in = 0 end
  local span = a2 - a1
  if span < 0 then span = span + 360 end
  if span <= 0 or span >= 359.5 then span = 360 end
  local x0 = math.floor(cx - r_out) - 1
  local x1 = math.ceil(cx + r_out) + 1
  local y0 = math.floor(cy - r_out) - 1
  local y1 = math.ceil(cy + r_out) + 1
  for py = y0, y1 do
    for px = x0, x1 do
      local dx, dy = px + 0.5 - cx, py + 0.5 - cy
      local dist = math.sqrt(dx * dx + dy * dy)
      -- 覆盖率：径向外沿、内沿各按 1px 过渡
      local cov = clamp01(r_out - dist + 0.5) * clamp01(dist - r_in + 0.5)
      if cov > 0.002 then
        if span < 360 then
          local ang = math.deg(math.atan(dy, dx))
          local rel = (ang - a1) % 360
          if rel > span then cov = 0 end
        end
        if cov > 0.002 then put(px, py, color, math.floor(opa * cov + 0.5)) end
      end
    end
  end
end

function lv_canvas_draw_text(cvs, x, y, maxw, text, dsc) end
function lv_canvas_draw_img(cvs, x, y, src, dsc) end
function lv_canvas_blit_rgb565(cvs, x, y, w, h, data, opts) end

function lv_canvas_set_px_color(cvs, x, y, color)
  x, y = math.floor(x), math.floor(y)
  put(x, y, color, 255)
end

function lv_canvas_set_px_opa(cvs, x, y, opa) end

-- 统计用：记录 set_px 调用次数
PV.px_calls = 0
local set_px_wrap = lv_canvas_set_px_color
function lv_canvas_set_px_color(cvs, x, y, color)
  PV.px_calls = PV.px_calls + 1
  set_px_wrap(cvs, x, y, color)
end

-- ---------------------------------------------------------------- 对象 / RTOS 打桩
--
-- 巡演模拟（scripts/tour_driver.lua）要跑真正的 main.lua，需要 canvas 之外的
-- 这些接口：label 上的文字变化正好就是 HUD 里显示的 "id n/32"。

PV.clock = 0                      -- 模拟毫秒时钟
PV.labels = {}                    -- 记录 label 上出现过的文字
LV_PART_MAIN = 0
LV_STATE_DEFAULT = 0
LV_OBJ_FLAG_SCROLLABLE = 1
LV_ALIGN_BOTTOM_MID = 0

function millis()
  return PV.clock
end

function lv_scr_act()
  return 0
end

function lv_obj_set_style_bg_color(obj, color, sel) end
function lv_obj_set_style_bg_opa(obj, opa, sel) end
function lv_obj_clear_flag(obj, flag) end
function lv_obj_set_pos(obj, x, y) end
function lv_obj_set_style_text_color(obj, color, sel) end
function lv_obj_align(obj, align, x, y) end

local label_id = 0
local labels = {}

function lv_label_create(parent)
  label_id = label_id + 1
  labels[label_id] = ""
  return label_id
end

function lv_label_set_text(obj, text)
  if obj and labels[obj] ~= nil then
    labels[obj] = text
    PV.labels[#PV.labels + 1] = text
  end
end

tmr = {
  ALARM_AUTO = 1,
  ALARM_SINGLE = 0,
  now = function() return PV.clock * 1000 end,
  create = function()
    local handle = { unregister = function() end }
    function handle:alarm(ms, mode, cb)
      PV.timer_cb = cb
      PV.timer_ms = ms
      return true
    end
    return handle
  end,
}

key = {
  SHORT = 1, LEFT = 1, RIGHT = 2, UP = 3, DOWN = 4, HOME = 5,
  on = function() end,
  off = function() end,
}

app = {
  exiting = function() return false end,
  exit = function() end,
}

file = {
  exists = function(path) return path == "/sd/apps/grok_bot/main.lua" end,
}

-- 导出 PPM（P6），交给 JS 侧落盘
function PREVIEW.dump_ppm()
  local rows = {}
  for y = 0, H - 1 do
    local row = {}
    local base = y * W
    for x = 0, W - 1 do
      local c = fb[base + x + 1]
      row[#row + 1] = string.char((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
    end
    rows[#rows + 1] = table.concat(row)
  end
  return "P6\n" .. W .. " " .. H .. "\n255\n" .. table.concat(rows)
end
