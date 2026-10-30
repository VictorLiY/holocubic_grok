-- grok_ball.lua —— 绘制层：球体 + 球面投影眼睛 + 睡眠 zzz + 撒花
--
-- 与 grok-ball 的 SVG 渲染逐条对齐（ball.js setEye / applyPose）：
--   * 眼睛轮廓是 48 点闭合折线，先在“世界坐标”（viewBox 259x259，头部中心
--     HEAD_C，半径 HEAD_C）里做完仿射变换，再整体缩放到屏幕。
--   * 横向做经度换算 + 偏航 + 余弦压缩（模拟绕球面转动），纵向做球形拟合
--     缩放，眼睛越靠上下越扁。
--   * LVGL canvas 没有填充多边形图元，这里用扫描线算法把多边形拆成横向
--     线段（draw_line），48 点 / 每帧两条眼睛约 80 次调用。
--
-- 精细度（config.antialias）：
--   * 球体用 16 级径向渐变分层叠画，色阶差 ≤1，取代原来 5 层的大色带；
--   * 球缘逐行做覆盖率混色（set_px_color），消除 1px 台阶；
--   * 眼缘左右各有 1 个像素按覆盖率与球面底色混色，顶末行再叠纵向覆盖率。

local Ball = {}
Ball.__index = Ball

local floor, ceil, sqrt, sin, cos, abs = math.floor, math.ceil, math.sqrt, math.sin, math.cos, math.abs
local TAU = math.pi * 2
local RING_POINTS = 48

-- 高光方向（球半径为单位，屏幕 y 向下）：左上
local HL_X, HL_Y = -0.30, -0.42
-- 径向渐变的色阶数（越大越平滑，代价是每帧多画几层圆）
local GRAD_STEPS = 16
-- 高光最亮处的提亮幅度（朝白色靠拢的比例）
local HL_AMT = 0.26
-- 覆盖率量化级数（抗锯齿混色查表用，越大边缘过渡越细）
local COV_LEVELS = 16

local lv_canvas_frame_begin = rawget(_G, "lv_canvas_frame_begin") or rawget(_G, "lv_canvas_begin")
local lv_canvas_frame_end = rawget(_G, "lv_canvas_frame_end") or rawget(_G, "lv_canvas_end")
local lv_canvas_fill_bg = rawget(_G, "lv_canvas_fill_bg") or rawget(_G, "lv_canvas_fill")
local lv_canvas_draw_rect = rawget(_G, "lv_canvas_draw_rect")
local lv_canvas_draw_line = rawget(_G, "lv_canvas_draw_line")
local lv_canvas_draw_arc = rawget(_G, "lv_canvas_draw_arc")
local lv_canvas_draw_text = rawget(_G, "lv_canvas_draw_text")
local lv_canvas_set_px_color = rawget(_G, "lv_canvas_set_px_color")
local lv_obj_invalidate = rawget(_G, "lv_obj_invalidate")
local LV_RADIUS_CIRCLE = rawget(_G, "LV_RADIUS_CIRCLE") or 0x7FFF
-- 没有 set_px_color 就没有抗锯齿（退回逐行线段填充）
local HAS_PX = lv_canvas_set_px_color ~= nil

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

-- 返回 {base, rim, pal[0..GRAD_STEPS], pal_r/g/b, rim_r/g/b} ，按 hex 缓存
--   pal[i]  径向渐变第 i 层（0 = 球缘底色，GRAD_STEPS = 高光最亮处）
local function color_set(hex)
  local set = color_cache[hex]
  if set then return set end
  local r, g, b = parse_hex(hex)
  local function pack(rr, gg, bb)
    return rr * 65536 + gg * 256 + bb
  end
  -- 径向渐变：提亮幅度按 t^1.35 分布，越靠高光中心越亮
  local pal, pr, pg, pb = {}, {}, {}, {}
  for i = 0, GRAD_STEPS do
    local t = i / GRAD_STEPS
    local amt = HL_AMT * t ^ 1.35
    local rr = shade_channel(r, amt)
    local gg = shade_channel(g, amt)
    local bb = shade_channel(b, amt)
    pal[i] = pack(rr, gg, bb)
    pr[i], pg[i], pb[i] = rr, gg, bb
  end
  local rim_r = shade_channel(r, -0.06)
  local rim_g = shade_channel(g, -0.06)
  local rim_b = shade_channel(b, -0.06)
  set = {
    base = pack(r, g, b),
    base_r = r, base_g = g, base_b = b,
    pal = pal,
    pal_r = pr, pal_g = pg, pal_b = pb,
    rim = pack(rim_r, rim_g, rim_b),
    rim_r = rim_r, rim_g = rim_g, rim_b = rim_b,
    stroke = pack(shade_channel(r, -0.6), shade_channel(g, -0.6), shade_channel(b, -0.6)),
  }
  color_cache[hex] = set
  return set
end

-- 混色：把 src 以 a 的覆盖率覆盖到 dst 上，返回整型色值
local function mix_pack(dr, dg, db, sr, sg, sb, a)
  if a <= 0 then return dr * 65536 + dg * 256 + db end
  if a >= 1 then return sr * 65536 + sg * 256 + sb end
  local ia = 1 - a
  return floor(dr * ia + sr * a + 0.5) * 65536
    + floor(dg * ia + sg * a + 0.5) * 256
    + floor(db * ia + sb * a + 0.5)
end

-- 覆盖率量化查表：cov ∈ [0,1] → lut[0..COV_LEVELS]
local function build_cov_lut(lut, dr, dg, db, sr, sg, sb)
  for k = 0, COV_LEVELS do
    lut[k] = mix_pack(dr, dg, db, sr, sg, sb, k / COV_LEVELS)
  end
end

local function cov_index(c)
  local k = floor(c * COV_LEVELS + 0.5)
  if k < 0 then return 0 elseif k > COV_LEVELS then return COV_LEVELS end
  return k
end

-- ---------------------------------------------------------------- 多边形填充

-- 扫描线填充：把闭合折线 (xs, ys) 按行拆成水平线段
--   lut 为 nil 时用整数端点直接画（旧行为，无抗锯齿）；
--   否则左右各 1 个边界像素按覆盖率查 lut 混色，首末行再叠一次纵向覆盖率。
local function fill_poly(cvs, xs, ys, n, color, cross, lut)
  local ymin, ymax = ys[1], ys[1]
  for i = 2, n do
    local y = ys[i]
    if y < ymin then ymin = y elseif y > ymax then ymax = y end
  end
  local ya = floor(ymin)
  local yb = ceil(ymax) - 1
  if yb < ya then return end
  local set_px = (lut and HAS_PX) and lv_canvas_set_px_color or nil

  for y = ya, yb do
    -- 纵向覆盖率：只有首末两行小于 1
    local ylo = y > ymin and y or ymin
    local yhi = (y + 1) < ymax and (y + 1) or ymax
    local vcov = yhi - ylo
    if vcov > 0.02 then
      if vcov > 1 then vcov = 1 end
      local yy = y + 0.5
      if yy < ymin then yy = ymin + 0.001 elseif yy > ymax then yy = ymax - 0.001 end

      local cnt = 0
      local j = n
      for i = 1, n do
        local ya2, yb2 = ys[j], ys[i]
        if (ya2 <= yy and yb2 > yy) or (yb2 <= yy and ya2 > yy) then
          cnt = cnt + 1
          cross[cnt] = xs[j] + (yy - ya2) * (xs[i] - xs[j]) / (yb2 - ya2)
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
          local xa, xb = cross[i], cross[i + 1]
          if set_px then
            local pl, pr = floor(xa), floor(xb)
            if pr <= pl then
              local k = cov_index((xb - xa) * vcov)
              if k > 0 then set_px(cvs, pl, y, lut[k]) end
            else
              set_px(cvs, pl, y, lut[cov_index((pl + 1 - xa) * vcov)])
              if pr - 1 > pl then
                lv_canvas_draw_line(cvs, pl + 1, y, pr - 1, y, color, floor(vcov * 255 + 0.5), 1)
              end
              set_px(cvs, pr, y, lut[cov_index((xb - pr) * vcov)])
            end
          else
            local sa = floor(xa + 0.5)
            local sb = floor(xb + 0.5)
            if sb >= sa then
              lv_canvas_draw_line(cvs, sa, y, sb, y, color, 255, 1)
            end
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- Ball

-- 弹跳幅度系数：球心到屏幕顶的余量决定能跳多高，球放大后自动收敛，避免出画布
-- max_h 是引擎里最大弹跳高度（世界坐标，见 grok_engine 的 BOUNCE_SEGS）
function Ball.bounce_scale(D, radius, cy, max_h)
  local s = radius / (D.HEAD_C or 114.271)
  local headroom = cy - radius - 2
  local v = headroom / ((max_h or 48) * s)
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end

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
  self.cy = opts.cy or 116
  self.scale = (opts.radius or 96) / D.HEAD_C
  self.bg = opts.bg or 0x0B0C10
  self.bg_r = floor(self.bg / 65536) % 256
  self.bg_g = floor(self.bg / 256) % 256
  self.bg_b = self.bg % 256
  self.aa = (opts.antialias ~= false) and HAS_PX

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
  self.lut = {}          -- 眼睛边缘混色表
  self.rim_lut = {}      -- 球缘混色表
  self.rim_col = nil
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

-- ---------------------------------------------------------------- 球体

-- 叠一层半径 rr、圆心 (x,y) 的实心圆（radius = LV_RADIUS_CIRCLE）
local function fill_disc(cvs, dsc, x, y, rr, color)
  dsc.bg_color = color
  local d = floor(rr * 2 + 0.5)
  lv_canvas_draw_rect(cvs, floor(x - rr + 0.5), floor(y - rr + 0.5), d, d, dsc)
end

-- 球体：外圈暗边 + 主体 + GRAD_STEPS 级径向渐变（高光在左上）
-- 各层都是内接圆：圆心随层号向高光中心移动、半径同步缩小，所以永远不越界。
-- 返回 LVGL 量化后的外接圆心与半径：AA 边缘必须用同一套几何，否则会差半像素
-- 而在球缘留下孤立的亮像素。
function Ball:draw_body(cvs, bcx, bcy, rad, col)
  local dsc = self.rect_dsc
  local dd = floor(rad * 2 + 0.5)
  local ox = floor(bcx - rad + 0.5)
  local oy = floor(bcy - rad + 0.5)

  dsc.bg_color = col.rim
  lv_canvas_draw_rect(cvs, ox, oy, dd, dd, dsc)

  fill_disc(cvs, dsc, bcx, bcy, rad * 0.985, col.base)

  local pal = col.pal
  for i = 1, GRAD_STEPS do
    local t = i / GRAD_STEPS
    fill_disc(cvs, dsc, bcx + HL_X * rad * t, bcy + HL_Y * rad * t, rad * (1 - t), pal[i])
  end
  return ox + dd * 0.5, oy + dd * 0.5, dd * 0.5
end

-- 球缘抗锯齿：逐行按覆盖率把边缘像素与背景混色
function Ball:aa_rim(bcx, bcy, rad, col)
  local lut = self.rim_lut
  if self.rim_col ~= col then
    self.rim_col = col
    build_cov_lut(lut, self.bg_r, self.bg_g, self.bg_b, col.rim_r, col.rim_g, col.rim_b)
  end
  local set_px = lv_canvas_set_px_color
  local ytop, ybot = bcy - rad, bcy + rad
  for y = floor(ytop), floor(ybot) do
    local dyc = y + 0.5 - bcy
    if abs(dyc) < rad then
      local hw = sqrt(rad * rad - dyc * dyc)
      local xl, xr = bcx - hw, bcx + hw
      local vcov = 1
      if y < ytop then vcov = y + 1 - ytop end
      if y + 1 > ybot then vcov = ybot - y end
      if vcov > 0.02 then
        if vcov > 1 then vcov = 1 end
        local pl, pr = floor(xl), floor(xr)
        if vcov >= 0.999 then
          set_px(self.cvs, pl, y, lut[cov_index(pl + 1 - xl)])
          set_px(self.cvs, pr, y, lut[cov_index(xr - pr)])
        else
          -- 顶部/底部的行：整行按纵向覆盖率混色
          for x = pl, pr do
            local cov = vcov
            if x == pl then cov = cov * (pl + 1 - xl) end
            if x == pr then cov = cov * (xr - pr) end
            if cov > 0.02 then set_px(self.cvs, x, y, lut[cov_index(cov)]) end
          end
        end
      end
    end
  end
end

-- 球面某点的底色 RGB：自最内层向外找它落在哪一级渐变里（每帧两次，可忽略）
function Ball:shade_rgb(px, py, bcx, bcy, rad, col)
  local pal_r, pal_g, pal_b = col.pal_r, col.pal_g, col.pal_b
  for i = GRAD_STEPS, 1, -1 do
    local t = i / GRAD_STEPS
    local cx = bcx + HL_X * rad * t
    local cy = bcy + HL_Y * rad * t
    local rr = rad * (1 - t)
    local dx, dy = px - cx, py - cy
    if dx * dx + dy * dy <= rr * rr then
      return pal_r[i], pal_g[i], pal_b[i]
    end
  end
  return pal_r[0], pal_g[0], pal_b[0]
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

  local ex, ey, er = self:draw_body(cvs, bcx, bcy, rad, col)
  if self.aa then self:aa_rim(ex, ey, er, col) end
  local t2 = now_us()

  -- 眼睛
  local yaw = b.yaw or 0
  local lut = self.lut
  for e = 1, 2 do
    local pe = e == 1 and pose.left or pose.right
    local ring = e == 1 and pose.ringL or pose.ringR
    if ring and self:project_eye(pe, ring, b, yaw, e) then
      local xs, ys = self.xs[e], self.ys[e]
      local ec = color_set(pe.color)
      if self.aa then
        -- 眼缘像素的混色目标是球面底色：取眼睛中点的采样即可
        local sumx, sumy = 0, 0
        for i = 1, RING_POINTS do
          sumx = sumx + xs[i]
          sumy = sumy + ys[i]
        end
        local nr, ng, nb = self:shade_rgb(sumx / RING_POINTS, sumy / RING_POINTS, bcx, bcy, rad, col)
        build_cov_lut(lut, nr, ng, nb, ec.base_r, ec.base_g, ec.base_b)
        fill_poly(cvs, xs, ys, RING_POINTS, ec.base, self.cross, lut)
      else
        fill_poly(cvs, xs, ys, RING_POINTS, ec.base, self.cross)
      end
    end
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
