-- grok_ball.lua —— 绘制层：球体 + 球面投影眼睛 + 睡眠 zzz + 撒花
--
-- 与 grok-ball 的 SVG 渲染逐条对齐（ball.js setEye / applyPose）：
--   * 眼睛轮廓是 48 点闭合折线，先在“世界坐标”（viewBox 259x259，头部中心
--     HEAD_C，半径 HEAD_C）里做完仿射变换，再整体缩放到屏幕。
--   * 横向做经度换算 + 偏航 + 余弦压缩（模拟绕球面转动），纵向做球形拟合
--     缩放，眼睛越靠上下越扁。
--   * LVGL canvas 没有填充多边形图元，这里用扫描线算法把多边形拆成横向
--     线段（draw_line），48 点 / 每帧两条眼睛约 80 次调用。

local Ball = {}
Ball.__index = Ball

local floor, sqrt, sin, cos, abs = math.floor, math.sqrt, math.sin, math.cos, math.abs
local TAU = math.pi * 2
local RING_POINTS = 48

local lv_canvas_frame_begin = rawget(_G, "lv_canvas_frame_begin") or rawget(_G, "lv_canvas_begin")
local lv_canvas_frame_end = rawget(_G, "lv_canvas_frame_end") or rawget(_G, "lv_canvas_end")
local lv_canvas_fill_bg = rawget(_G, "lv_canvas_fill_bg") or rawget(_G, "lv_canvas_fill")
local lv_canvas_draw_rect = rawget(_G, "lv_canvas_draw_rect")
local lv_canvas_draw_line = rawget(_G, "lv_canvas_draw_line")
local lv_canvas_draw_arc = rawget(_G, "lv_canvas_draw_arc")
local lv_canvas_draw_text = rawget(_G, "lv_canvas_draw_text")
local lv_obj_invalidate = rawget(_G, "lv_obj_invalidate")
local LV_RADIUS_CIRCLE = rawget(_G, "LV_RADIUS_CIRCLE") or 0x7FFF

local CONFETTI_COLORS = { 0xF9705C, 0x5B95F0, 0x3FBE86, 0xF5B13F, 0x9A72EE, 0x35C3BD }

local raw_tmr = rawget(_G, "tmr")
local tmr_now = raw_tmr and raw_tmr.now

-- 微秒计时（tmr.now 返回 us），用于分阶段性能统计
local function now_us()
  if tmr_now then
    local ok, v = pcall(tmr_now)
    if ok and type(v) == "number" then return v end
  end
  return 0
end

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function rnd(a, b)
  return a + math.random() * (b - a)
end

-- ---------------------------------------------------------------- 颜色

local color_cache = {}

local function parse_hex(hex)
  local h = tostring(hex or "#FFFFFF"):gsub("#", "")
  if #h == 3 then
    h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2)
  end
  local n = tonumber(h, 16) or 0xFFFFFF
  return floor(n / 65536) % 256, floor(n / 256) % 256, n % 256
end

local function shade_channel(v, amt)
  local target = amt < 0 and 0 or 255
  local a = abs(amt)
  return floor(v + (target - v) * a + 0.5) % 256
end

-- 返回 {base, light, rim, stroke} 四个整型色值，按 hex 缓存
local function color_set(hex)
  local set = color_cache[hex]
  if set then return set end
  local r, g, b = parse_hex(hex)
  local function pack(rr, gg, bb)
    return rr * 65536 + gg * 256 + bb
  end
  -- 5 级高光：叠画同心圆近似径向渐变，色差控制在 1~2 个色阶，看不出分层
  local tints = {}
  for i = 1, 5 do
    local amt = i * 0.042
    tints[i] = pack(shade_channel(r, amt), shade_channel(g, amt), shade_channel(b, amt))
  end
  set = {
    base = pack(r, g, b),
    tints = tints,
    rim = pack(shade_channel(r, -0.05), shade_channel(g, -0.05), shade_channel(b, -0.05)),
    stroke = pack(shade_channel(r, -0.6), shade_channel(g, -0.6), shade_channel(b, -0.6)),
  }
  color_cache[hex] = set
  return set
end

-- ---------------------------------------------------------------- 多边形填充

-- 扫描线填充：把闭合折线 (xs, ys) 按行拆成水平线段
local function fill_poly(cvs, xs, ys, n, color, cross)
  local ymin, ymax = ys[1], ys[1]
  for i = 2, n do
    local y = ys[i]
    if y < ymin then ymin = y elseif y > ymax then ymax = y end
  end
  local y0 = floor(ymin + 0.5)
  local y1 = floor(ymax + 0.5)
  if y1 < y0 then return end

  for y = y0, y1 do
    local yy = y + 0.5
    local cnt = 0
    local j = n
    for i = 1, n do
      local ya, yb = ys[j], ys[i]
      if (ya <= yy and yb > yy) or (yb <= yy and ya > yy) then
        cnt = cnt + 1
        cross[cnt] = xs[j] + (yy - ya) * (xs[i] - xs[j]) / (yb - ya)
      end
      j = i
    end
    if cnt >= 2 then
      -- 插入排序，交点通常只有 2~4 个
      for i = 2, cnt do
        local v, k = cross[i], i - 1
        while k >= 1 and cross[k] > v do
          cross[k + 1] = cross[k]
          k = k - 1
        end
        cross[k + 1] = v
      end
      for i = 1, cnt - 1, 2 do
        local xa = floor(cross[i] + 0.5)
        local xb = floor(cross[i + 1] + 0.5)
        if xb >= xa then
          lv_canvas_draw_line(cvs, xa, y, xb, y, color, 255, 1)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- Ball

function Ball.new(cvs, D, opts)
  opts = opts or {}
  local self = setmetatable({}, Ball)

  self.cvs = cvs
  self.D = D
  self.C = D.HEAD_C
  self.HALF = D.EYE_HALF
  self.RW = D.HEAD_C
  self.face = D.FACE
  self.cx = opts.cx or 160
  self.cy = opts.cy or 126
  self.scale = (opts.radius or 84) / D.HEAD_C
  self.bg = opts.bg or 0x0B0C10

  -- 复用缓冲：每帧只写值，不新建表
  self.xs = { {}, {} }
  self.ys = { {}, {} }
  for e = 1, 2 do
    for i = 1, RING_POINTS do
      self.xs[e][i] = 0
      self.ys[e][i] = 0
    end
  end
  self.cross = {}
  self.confetti = {}
  self.text_dsc = { color = 0xA8A296, opa = 255, font_size = 14 }
  self.rect_dsc = { bg_color = 0, bg_opa = 255, radius = LV_RADIUS_CIRCLE, border_width = 0 }
  self.prof = { bg = 0, body = 0, eye = 0, fx = 0, n = 0 }

  return self
end

-- 分阶段耗时统计（毫秒/帧），读取后清零
function Ball:take_prof()
  local p = self.prof
  if p.n == 0 then return nil end
  local n = p.n
  local out = {
    bg = p.bg / n / 1000,
    body = p.body / n / 1000,
    eye = p.eye / n / 1000,
    fx = p.fx / n / 1000,
    frames = n,
  }
  p.bg, p.body, p.eye, p.fx, p.n = 0, 0, 0, 0, 0
  return out
end

-- 眼睛：世界坐标仿射 → 屏幕坐标写入 self.xs[e]/ys[e]，返回是否可见
function Ball:project_eye(pe, ring, body, yaw, e)
  local C, face, s = self.C, self.face, self.scale
  local n = RING_POINTS

  -- 当前环的质心（形变中每帧变化）
  local sumx, sumy = 0, 0
  for i = 1, n * 2, 2 do
    sumx = sumx + ring[i]
    sumy = sumy + ring[i + 1]
  end
  local basex, basey = sumx / n, sumy / n

  local eye_sy = clamp(pe.scaleY * pe.open * face.eye, 0.02, 2.4)
  local eye_sx = pe.scaleX * face.eye

  -- 纵向：脸部拟合 + 轮廓钳制
  local halfH = self.HALF * eye_sy + 2
  local ey0 = C + face.y + (basey - C) * face.sy + pe.y + pe.lookY
  ey0 = clamp(ey0, (C - self.RW) + halfH, (C + self.RW) - halfH)

  -- 横向：经度换算 + 自旋偏航 + 余弦压缩
  local dy = ey0 - C
  local hw0 = self.RW * self.RW - dy * dy
  if hw0 < 0 then hw0 = 0 end
  hw0 = sqrt(hw0)
  local hw = hw0
  if hw < 12 then hw = 12 end

  local ox = face.x + (basex - C) * face.sx + pe.x + pe.lookX
  local theta = clamp(ox / hw, -1.15, 1.15)
  local total = theta + yaw
  local cn = cos(total)
  if cn <= 0.02 then return false end

  local ex = C + hw * sin(total) * 0.985
  local dyn = dy / 130
  local fy = 1 - dyn * dyn * 0.22
  if fy < 0 then fy = 0 end
  fy = sqrt(fy)

  local SX = eye_sx * cn
  local SY = eye_sy * fy

  -- 合成矩阵：screen = O + K * (p - base)
  --   K = A * R(body.rotate + eye.rotate) * diag(SX, SY)
  --   O = W + A * R(body.rotate) * (E - C)
  local brot = body.rotate
  local A = body.scale * s
  local ang = brot + pe.rotate
  local ca, sa = cos(ang), sin(ang)
  local k11 = A * ca * SX
  local k12 = -A * sa * SY
  local k21 = A * sa * SX
  local k22 = A * ca * SY

  local cb, sb = cos(brot), sin(brot)
  local ecx, ecy = ex - C, ey0 - C
  local wx = self.cx + body.x * s
  local wy = self.cy + body.y * s
  local ox2 = wx + A * (cb * ecx - sb * ecy)
  local oy2 = wy + A * (sb * ecx + cb * ecy)

  local xs, ys = self.xs[e], self.ys[e]
  local k = 1
  for i = 1, n * 2, 2 do
    local ux = ring[i] - basex
    local uy = ring[i + 1] - basey
    xs[k] = ox2 + k11 * ux + k12 * uy
    ys[k] = oy2 + k21 * ux + k22 * uy
    k = k + 1
  end
  return true
end

-- 睡眠 zzz：三枚字母错峰沿右上漂浮，先淡入后淡出
function Ball:draw_zzz(amount, now)
  local C, s = self.C, self.scale
  local dsc = self.text_dsc
  for z = 0, 2 do
    local zp = (now * 0.00033 + z / 3) % 1
    local zo
    if zp < 0.18 then
      zo = zp / 0.18
    else
      zo = 1 - (zp - 0.18) / 0.82
    end
    zo = zo * 0.8 * amount
    if zo > 0.03 then
      local wx = 180 + zp * 34 + 4 * sin(zp * 9)
      local wy = 48 - zp * 42
      dsc.opa = floor(clamp(zo, 0, 1) * 255)
      dsc.font_size = floor(12 + zp * 11)
      lv_canvas_draw_text(self.cvs, floor(self.cx + (wx - C) * s), floor(self.cy + (wy - C) * s),
        24, "z", dsc)
    end
  end
end

-- ---------------------------------------------------------------- 撒花

function Ball:burst(count)
  local n = count or 20
  for _ = 1, n do
    local a = rnd(0, TAU)
    local speed = rnd(60, 200)
    self.confetti[#self.confetti + 1] = {
      x = rnd(-24, 24),
      y = rnd(-24, 24),
      vx = cos(a) * speed,
      vy = sin(a) * speed - 60,
      rot = rnd(0, TAU),
      vr = rnd(-6, 6),
      r = rnd(3.5, 8),
      stretch = 1.9,
      life = 0,
      max = rnd(1.1, 1.8),
      color = CONFETTI_COLORS[math.random(#CONFETTI_COLORS)],
    }
  end
end

function Ball:update_confetti(dt)
  local list = self.confetti
  if #list == 0 then return end
  local s, C = self.scale, self.C
  local drag = 0.94 ^ (60 * dt)
  local i = 1
  while i <= #list do
    local p = list[i]
    p.life = p.life + dt
    if p.life >= p.max then
      list[i] = list[#list]
      list[#list] = nil
    else
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      p.vx = p.vx * drag
      p.vy = p.vy * drag + 40 * dt
      p.rot = p.rot + p.vr * dt
      local u = p.life / p.max
      local opa
      if u < 0.1 then
        opa = u / 0.1
      else
        local base = 1 - (u - 0.1) / 0.9
        if base < 0 then base = 0 end
        opa = base ^ 1.7
      end
      local size = p.r * (1 - 0.4 * u)
      if size < 0.5 then size = 0.5 end
      local ca, sa = cos(p.rot), sin(p.rot)
      local px = self.cx + (p.x - C) * s
      local py = self.cy + (p.y - C) * s
      local dx = ca * size * s
      local dy = sa * size * s * p.stretch
      lv_canvas_draw_line(self.cvs, floor(px - dx), floor(py - dy), floor(px + dx), floor(py + dy),
        p.color, floor(clamp(opa, 0, 1) * 255), 2)
      i = i + 1
    end
  end
end

-- ---------------------------------------------------------------- 主渲染

function Ball:render(pose, now, dt)
  local cvs = self.cvs
  if not cvs or not lv_canvas_draw_rect then return end

  local t0 = now_us()

  if lv_canvas_frame_begin then lv_canvas_frame_begin(cvs) end
  if lv_canvas_fill_bg then lv_canvas_fill_bg(cvs, self.bg, 255) end
  local t1 = now_us()

  local b = pose.body
  local s = self.scale
  local rad = self.RW * b.scale * s
  local bcx = self.cx + b.x * s
  local bcy = self.cy + b.y * s
  local col = color_set(b.color)

  -- 身体：外圈稍暗 + 主体 + 左上高光，近似原 SVG 的三段径向渐变
  local dsc = self.rect_dsc

  dsc.bg_color = col.rim
  lv_canvas_draw_rect(cvs, floor(bcx - rad + 0.5), floor(bcy - rad + 0.5),
    floor(rad * 2 + 0.5), floor(rad * 2 + 0.5), dsc)

  local r2 = rad * 0.985
  dsc.bg_color = col.base
  lv_canvas_draw_rect(cvs, floor(bcx - r2 + 0.5), floor(bcy - r2 + 0.5),
    floor(r2 * 2 + 0.5), floor(r2 * 2 + 0.5), dsc)

  -- 高光：自 0.87r 向内叠 5 层，圆心随半径缩小向左上偏移
  local tints = col.tints
  for i = 1, 5 do
    local f = 1 - i * 0.13
    local rr = rad * f
    local off = 1 - f
    dsc.bg_color = tints[i]
    lv_canvas_draw_rect(cvs,
      floor(bcx - rad * 0.24 * off - rr + 0.5),
      floor(bcy - rad * 0.36 * off - rr + 0.5),
      floor(rr * 2 + 0.5), floor(rr * 2 + 0.5), dsc)
  end
  local t2 = now_us()

  -- 眼睛
  local yaw = b.yaw or 0
  if pose.ringL and self:project_eye(pose.left, pose.ringL, b, yaw, 1) then
    fill_poly(cvs, self.xs[1], self.ys[1], RING_POINTS, color_set(pose.left.color).base, self.cross)
  end
  if pose.ringR and self:project_eye(pose.right, pose.ringR, b, yaw, 2) then
    fill_poly(cvs, self.xs[2], self.ys[2], RING_POINTS, color_set(pose.right.color).base, self.cross)
  end
  local t3 = now_us()

  if b.zzz and b.zzz > 0 and lv_canvas_draw_text then
    self:draw_zzz(b.zzz, now)
  end

  self:update_confetti(dt or 0.04)

  if lv_canvas_frame_end then
    lv_canvas_frame_end(cvs)
  elseif lv_obj_invalidate then
    lv_obj_invalidate(cvs)
  end
  local t4 = now_us()

  local p = self.prof
  p.bg = p.bg + (t1 - t0)
  p.body = p.body + (t2 - t1)
  p.eye = p.eye + (t3 - t2)
  p.fx = p.fx + (t4 - t3)
  p.n = p.n + 1
end

Ball.color_set = color_set

return Ball
