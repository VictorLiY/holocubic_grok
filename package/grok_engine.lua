-- grok_engine.lua —— 驱动层：姿态合成、弹簧形变、眨眼、表情池轮换、序列、过渡
--
-- 对应 grok-ball 的 engine.js，逐段移植并针对 MCU 做了内存优化：
--   热路径（每帧）不分配新表，眼环插值写入预分配缓冲，avoid GC 抖动。
--
-- 姿态结构：
--   pose.body  {x,y,scale,rotate,color,breathe,zzz,yaw}
--   pose.left  {x,y,scaleX,scaleY,rotate,open,color,lookX,lookY}
--   pose.right 同上
--   pose.ringL / pose.ringR  当前眼环（扁平 x,y，96 个数）

local Engine = {}
Engine.__index = Engine

local floor, sin, cos, sqrt, exp, abs, pi = math.floor, math.sin, math.cos, math.sqrt, math.exp, math.abs, math.pi
local huge = math.huge
local TAU = pi * 2

-- 弹跳：4 段递减抛物线（高度 / 时长）
local BOUNCE_SEGS = { { h = 48, d = 0.5 }, { h = 28, d = 0.382 }, { h = 14, d = 0.27 }, { h = 6, d = 0.177 } }
local BOUNCE_TOTAL = 0
for i = 1, #BOUNCE_SEGS do BOUNCE_TOTAL = BOUNCE_TOTAL + BOUNCE_SEGS[i].d end

local DEFAULT_BODY = {
  x = 0, y = 0, scale = 1, rotate = 0, color = "#F3F0EA", breathe = 0.01,
  zzz = 0, orbit = 0, yaw = 0,
}
local DEFAULT_EYE = {
  x = 0, y = 0, scaleX = 1, scaleY = 1, rotate = 0, open = 1,
  color = "#1A1A1A", lookX = 0, lookY = 0,
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function rnd(a, b)
  return a + math.random() * (b - a)
end

local function ease_in_out_cubic(t)
  if t < 0.5 then return 4 * t * t * t end
  local u = -2 * t + 2
  return 1 - u * u * u / 2
end

local function tanh(x)
  if x > 20 then return 1 end
  if x < -20 then return -1 end
  local e = exp(2 * x)
  return (e - 1) / (e + 1)
end

-- ---------------------------------------------------------------- 姿态工具

local function new_pose()
  local pose = {
    body = {},
    left = {},
    right = {},
  }
  for k, v in pairs(DEFAULT_BODY) do pose.body[k] = v end
  for k, v in pairs(DEFAULT_EYE) do
    pose.left[k] = v
    pose.right[k] = v
  end
  return pose
end

local function copy_part(dst, src)
  for k, v in pairs(src) do dst[k] = v end
end

local function copy_pose(dst, src)
  copy_part(dst.body, src.body)
  copy_part(dst.left, src.left)
  copy_part(dst.right, src.right)
  return dst
end

local function hex_rgb(hex)
  local h = tostring(hex or "#FFFFFF"):gsub("#", "")
  if #h == 3 then
    h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2)
  end
  local n = tonumber(h, 16) or 0xFFFFFF
  return floor(n / 65536) % 256, floor(n / 256) % 256, n % 256
end

local function lerp_color(a, b, t)
  if a == b then return b end
  local ar, ag, ab = hex_rgb(a)
  local br, bg, bb = hex_rgb(b)
  return string.format("#%02X%02X%02X",
    floor(ar + (br - ar) * t + 0.5),
    floor(ag + (bg - ag) * t + 0.5),
    floor(ab + (bb - ab) * t + 0.5))
end

-- 把 b 的每个字段按 t 插值写进 dst（dst 可以与 b 同一张表）
local function lerp_pose_into(dst, a, b, t)
  local function part(dp, ap, bp)
    for k, vb in pairs(bp) do
      if type(vb) == "number" then
        local va = ap[k]
        if va == nil then va = vb end
        dp[k] = va + (vb - va) * t
      elseif k == "color" then
        dp[k] = lerp_color(ap[k] or vb, vb, t)
      else
        dp[k] = vb
      end
    end
  end
  part(dst.body, a.body, b.body)
  part(dst.left, a.left, b.left)
  part(dst.right, a.right, b.right)
  return dst
end

local function lerp_ring_into(dst, a, b, t)
  for i = 1, #a do
    dst[i] = a[i] + (b[i] - a[i]) * t
  end
  return dst
end

-- ---------------------------------------------------------------- 动画原语

local tg_buf = { nil, nil }

local ANIM = {}

function ANIM.sine(a, t)
  return a.amp * sin(TAU * t / (a.period or 2000) + (a.phase or 0))
end

function ANIM.pulse(a, t)
  return a.amp * 0.5 * (1 - cos(TAU * t / (a.period or 1000) + (a.phase or 0)))
end

function ANIM.jitter(a, t, eng)
  local s = t / 1000 * (a.speed or 8)
  local seed = eng.seed
  local v = (sin(s * 3.1 + seed) + sin(s * 5.7 + seed * 2.3) + sin(s * 9.3 + seed * 4.1)) / 3 * a.amp
  if a.decay then v = v * clamp(1 - t / a.decay, 0, 1) end
  return v
end

function ANIM.scan(a, t)
  local per = a.period or 800
  local p = ((t + (a.phaseMs or 0)) % per) / per
  local tri
  if p < 0.5 then tri = p * 4 - 1 else tri = 3 - p * 4 end
  return a.amp * tri
end

function ANIM.glance(a, t)
  local per = a.period or 3600
  local ph = TAU * (((t + (a.phaseMs or 0)) % per) / per) + (a.phase or 0)
  return a.amp * tanh(2.8 * sin(ph))
end

function ANIM.blink(a, t, eng)
  local interval = a.interval or 3800
  local dur = a.dur or 200
  local p = (t + (a.phaseMs or 0) + (eng and eng.seed * 97 or 0)) % interval
  if p >= dur then return 0 end
  local depth = a.depth
  if depth == nil then depth = 1 end
  return -depth * sin(pi * (p / dur))
end

local function apply_anim(pose, a, t, eng)
  local fn = ANIM[a.type]
  if not fn then return end
  local v = fn(a, t, eng)
  local target = a.target
  local n = 0
  if target == "eyes" then
    tg_buf[1] = pose.left
    tg_buf[2] = pose.right
    n = 2
  elseif target == "body" then
    tg_buf[1] = pose.body
    n = 1
  elseif target == "left" then
    tg_buf[1] = pose.left
    n = 1
  elseif target == "right" then
    tg_buf[1] = pose.right
    n = 1
  else
    return
  end

  local prop = a.prop
  for i = 1, n do
    local tg = tg_buf[i]
    if prop == "scale" then
      if tg == pose.body then
        tg.scale = tg.scale + v
      else
        tg.scaleX = tg.scaleX + v
        tg.scaleY = tg.scaleY + v
      end
    elseif tg[prop] ~= nil then
      tg[prop] = tg[prop] + v
    end
  end
end

-- ---------------------------------------------------------------- 配置归一化

local function apply_spec(body, left, right, spec)
  if spec.body then
    for k, v in pairs(spec.body) do body[k] = v end
  end
  local e = spec.eyes
  if e then
    if e.both then
      for k, v in pairs(e.both) do
        left[k] = v
        right[k] = v
      end
    end
    if e.left then
      for k, v in pairs(e.left) do left[k] = v end
    end
    if e.right then
      for k, v in pairs(e.right) do right[k] = v end
    end
  end
end

local function normalize(raw, ring_count)
  local def = {
    id = raw.id,
    name = raw.name,
    group = raw.group,
    gaze = raw.gaze ~= false,
    transition = raw.transition or 500,
    poolMs = raw.poolMs or { 9000, 16000 },
    poolSpeed = raw.poolSpeed or 6,
    blinkMs = raw.blinkMs,
    openness = raw.openness or 1,
    antics = raw.antics and true or false,
    anims = raw.anims or {},
  }

  local pool = {}
  for _, idx in ipairs(raw.pool or { 1, 9 }) do
    if idx >= 1 and idx <= ring_count then
      pool[#pool + 1] = idx
    end
  end
  if #pool == 0 then pool[1] = 1 end
  def.pool = pool

  local base = new_pose()
  apply_spec(base.body, base.left, base.right, raw)
  def.base = base

  if raw.sequence and raw.sequence.frames then
    local frames = {}
    for _, f in ipairs(raw.sequence.frames) do
      local frame = copy_pose(new_pose(), base)
      frame.at = f.at or 0
      apply_spec(frame.body, frame.left, frame.right, f)
      frames[#frames + 1] = frame
    end
    table.sort(frames, function(x, y) return x.at < y.at end)
    def.sequence = { frames = frames, settle = raw.sequence.settle or "base" }
  end

  return def
end

-- ---------------------------------------------------------------- Engine

function Engine.new(D, opts)
  opts = opts or {}
  local self = setmetatable({}, Engine)

  self.D = D
  self.rings = D.RINGS
  self.seed = opts.seed or (math.random() * 100)
  self.on_change = opts.on_change
  self.pending_burst = 0
  self.now = 0

  self.list = {}
  self.by_id = {}
  for _, raw in ipairs(D.EMOTIONS) do
    local def = normalize(raw, #D.RINGS)
    self.list[#self.list + 1] = def
    self.by_id[def.id] = def
  end

  self.fallback = opts.fallback or "02"
  if not self.by_id[self.fallback] then self.fallback = self.list[1].id end

  self._pose = new_pose()
  self._prev = new_pose()
  self._scratch = new_pose()
  self._hasPrev = false

  self._ringCur = { {}, {} }
  self._ringSrc = { self.rings[1][1], self.rings[1][2] }
  self._ringDst = { self.rings[1][1], self.rings[1][2] }
  self._exprIdx = 1
  self._ringSpring = { x = 1, v = 0, t = 1 }
  self._ringSpeed = 7

  -- 弹跳高度系数：球放大后按屏幕余量收缩，避免跳出画布
  local bs = opts.bounce_scale
  if bs and bs ~= 1 then
    local segs, total = {}, 0
    for i = 1, #BOUNCE_SEGS do
      segs[i] = { h = BOUNCE_SEGS[i].h * bs, d = BOUNCE_SEGS[i].d }
      total = total + segs[i].d
    end
    self._bounceSegs, self._bounceTotal = segs, total
  else
    self._bounceSegs, self._bounceTotal = BOUNCE_SEGS, BOUNCE_TOTAL
  end

  self._open = { x = 1, v = 0, t = 1 }
  self._blinkQ = {}
  self._blinkNext = huge

  self._spin = nil
  self._bounceAt = -1
  self._anticNext = 0
  self._gaze = { x = 0, y = 0, tx = 0, ty = 0 }

  self._poolPos = 1
  self._poolNext = 0
  self._seq = nil
  self._emoStart = 0
  self._transStart = 0
  self._transDur = 0

  -- 序列表情的 settle={next=...} 是否自动切下一个表情。
  -- 巡演（main.lua 的顺序轮播）会把它关掉，否则 01/07 收尾跳到 02 会把巡演打回开头。
  self.follow_settle = opts.follow_settle ~= false

  self._dt = 1 / 60
  self._lastTick = 0

  self:set_emotion(opts.emotion or self.fallback, true)
  return self
end

function Engine:emotion()
  return self._def
end

function Engine:emotion_id()
  return self._def and self._def.id
end

function Engine:set_gaze(nx, ny)
  self._gaze.tx = clamp(nx, -1, 1) * 24
  self._gaze.ty = clamp(ny, -1, 1) * 15
end

-- 自旋：弹簧追整数圈，眼环横向投影会跟着甩动
function Engine:spin(turns)
  if self._spin then return end
  local d
  if math.random() < 0.5 then d = -1 else d = 1 end
  local t = math.max(1, floor((turns or 1) + 0.5))
  self._spin = { x = 0, v = 0, t = t * TAU * d }
end

function Engine:bounce()
  if self._bounceAt < 0 then self._bounceAt = self.now end
end

function Engine:take_burst()
  local n = self.pending_burst
  self.pending_burst = 0
  return n
end

function Engine:_blink_now(now)
  local q = self._blinkQ
  q[#q + 1] = { at = now, v = 0.05 }
  q[#q + 1] = { at = now + 70, v = 0.05 }
  q[#q + 1] = { at = now + 150, v = 1.08 }
  q[#q + 1] = { at = now + 300, v = 1 }
  if math.random() < 0.14 then
    q[#q + 1] = { at = now + 370, v = 0.05 }
    q[#q + 1] = { at = now + 480, v = 1 }
  end
end

function Engine:_set_expr(idx, speed)
  if idx == self._exprIdx and self._ringSpring.x >= 0.999 then return end
  local s = clamp(self._ringSpring.x, 0, 1)
  self._ringSrc = {
    lerp_ring_into({}, self._ringSrc[1], self._ringDst[1], s),
    lerp_ring_into({}, self._ringSrc[2], self._ringDst[2], s),
  }
  local pair = self.rings[idx] or self.rings[1]
  self._ringDst = { pair[1], pair[2] }
  self._ringSpring.x = 0
  self._ringSpring.v = 0
  self._ringSpring.t = 1
  self._ringSpeed = speed or 7
  self._exprIdx = idx
end

function Engine:set_emotion(id, auto)
  local def = self.by_id[id]
  if not def then def = self.by_id[self.fallback] end
  if not def then return false end

  local now = self.now
  local prev_id = self._def and self._def.id

  if self._def then
    copy_pose(self._prev, self._pose)
    self._hasPrev = true
  end

  self._def = def
  self._emoStart = now
  self._transStart = now
  self._transDur = self._hasPrev and (def.transition or 500) or 0
  self._seq = def.sequence
    and { frames = def.sequence.frames, settle = def.sequence.settle, done = false }
    or nil

  self._poolPos = 1
  self:_set_expr(def.pool[1], (def.poolSpeed >= 10) and 10 or 8)
  self._poolNext = now + rnd(def.poolMs[1], def.poolMs[2])

  if prev_id and prev_id ~= def.id and def.blinkMs then
    self:_blink_now(now)
  end
  if def.blinkMs then
    self._blinkNext = now + rnd(def.blinkMs[1], def.blinkMs[2])
  else
    self._blinkNext = huge
  end
  self._anticNext = now + rnd(2500, 5000)

  -- 进入表情时的一次性特效
  local fx = def.base.body
  if fx.confetti and fx.confetti > 0 then
    self.pending_burst = self.pending_burst + 20
  end

  if self.on_change then self.on_change(def) end
  return true
end

function Engine:_seq_pose(t, now)
  local seq = self._seq
  local frames = seq.frames
  local last = frames[#frames]

  if t >= last.at then
    if not seq.done then
      seq.done = true
      local settle = seq.settle
      if settle == "base" then
        copy_pose(self._prev, self._pose)
        self._hasPrev = true
        self._transStart = now
        self._transDur = self._def.transition or 500
        self._seq = nil
        return nil
      elseif type(settle) == "table" and settle.next and self.follow_settle then
        self:set_emotion(settle.next, true)
        return "switch"
      end
      -- follow_settle = false（巡演中）时按 "hold" 处理：停在末帧，等巡演自己往下走
    end
    return last
  end

  local first = frames[1]
  if t <= first.at then return first end

  for i = 1, #frames - 1 do
    local a, b = frames[i], frames[i + 1]
    if t >= a.at and t < b.at then
      local k = ease_in_out_cubic((t - a.at) / (b.at - a.at))
      return lerp_pose_into(self._scratch, a, b, k)
    end
  end
  return last
end

function Engine:tick(now)
  local dt
  if self._lastTick ~= 0 then
    dt = (now - self._lastTick) / 1000
    if dt < 0.001 then dt = 0.001 elseif dt > 0.05 then dt = 0.05 end
  else
    dt = 1 / 60
  end
  self._lastTick = now
  self._dt = dt
  self.now = now

  local pose = self:_compose(now)
  return pose
end

function Engine:_compose(now, depth)
  depth = depth or 0
  local def = self._def
  local pose = self._pose
  local t = now - self._emoStart

  if self._seq then
    local res = self:_seq_pose(t, now)
    if res == "switch" then
      -- 序列 settle.next：已切到新表情，整帧重新合成
      if depth >= 4 then return pose end
      return self:_compose(now, depth + 1)
    end
    if res then
      copy_pose(pose, res)
    else
      copy_pose(pose, def.base)
    end
  else
    copy_pose(pose, def.base)
  end

  local body, left, right = pose.body, pose.left, pose.right

  -- 内置呼吸（相位用绝对时间，切换表情不跳变）
  local br = body.breathe or 0
  if br ~= 0 then
    local ph = TAU * now / 3600
    body.scale = body.scale + br * sin(ph)
    body.y = body.y + br * 55 * sin(ph + 0.6)
  end

  local anims = def.anims
  for i = 1, #anims do
    apply_anim(pose, anims[i], t, self)
  end

  -- 表情池轮换：间隔到点后随机跳到池内另一个眼环
  if now >= self._poolNext then
    local count = #def.pool
    if count > 1 then
      local p0 = self._poolPos - 1
      p0 = (p0 + 1 + floor(rnd(0, count - 1))) % count
      self._poolPos = p0 + 1
      self:_set_expr(def.pool[self._poolPos], def.poolSpeed)
    end
    self._poolNext = now + rnd(def.poolMs[1], def.poolMs[2])
  end

  -- 眨眼调度
  if def.blinkMs and now >= self._blinkNext then
    self:_blink_now(now)
    self._blinkNext = now + rnd(def.blinkMs[1], def.blinkMs[2])
  end
  local q = self._blinkQ
  local open_key = nil
  while #q > 0 and now >= q[1].at do
    open_key = q[1].v
    table.remove(q, 1)
  end
  if open_key then
    self._open.t = open_key
  elseif #q == 0 then
    self._open.t = def.openness
  end

  -- 待机小动作：9~18s 随机自旋 / 弹跳 / 连眨
  if def.antics and now >= self._anticNext then
    if not self._spin and self._bounceAt < 0 then
      local pick = math.random()
      if pick < 0.45 then
        self:spin(1)
      elseif pick < 0.8 then
        self:bounce()
      else
        self:_blink_now(now)
      end
    end
    self._anticNext = now + rnd(9000, 18000)
  end

  -- 弹簧整步（子步 1/120 保稳定）
  local dt = self._dt
  local steps = floor(dt / (1 / 120)) + 1
  local j = dt / steps
  local ring, open, spin = self._ringSpring, self._open, self._spin
  for _ = 1, steps do
    local jj = j
    ring.v = ring.v + (-2 * 1 * self._ringSpeed * ring.v - self._ringSpeed * self._ringSpeed * (ring.x - ring.t)) * jj
    ring.x = ring.x + ring.v * jj

    open.v = open.v + (-2 * 26 * open.v - 26 * 26 * (open.x - open.t)) * jj
    open.x = open.x + open.v * jj

    if spin then
      spin.v = spin.v + (-2 * 6.2 * spin.v - 6.2 * 6.2 * (spin.x - spin.t)) * jj
      spin.x = spin.x + spin.v * jj
    end
  end
  if spin and abs(spin.t - spin.x) < 0.01 and abs(spin.v) < 0.05 then
    self._spin = nil
  end
  body.yaw = self._spin and self._spin.x or 0

  -- 弹跳：4 段递减抛物线
  if self._bounceAt >= 0 then
    local be = (now - self._bounceAt) / 1000
    local segs = self._bounceSegs
    if be >= self._bounceTotal then
      self._bounceAt = -1
    else
      local acc, bi = 0, 1
      while bi < #segs and be >= acc + segs[bi].d do
        acc = acc + segs[bi].d
        bi = bi + 1
      end
      local seg = segs[bi]
      local bn = (be - acc) / seg.d
      body.y = body.y - 4 * seg.h * bn * (1 - bn)
    end
  end

  -- 当前眼环：形变中逐点插值，静止后直接用目标环
  if ring.x < 0.999 or ring.v > 0.001 or ring.v < -0.001 then
    local rs = clamp(ring.x, 0, 1.35)
    lerp_ring_into(self._ringCur[1], self._ringSrc[1], self._ringDst[1], rs)
    lerp_ring_into(self._ringCur[2], self._ringSrc[2], self._ringDst[2], rs)
    pose.ringL = self._ringCur[1]
    pose.ringR = self._ringCur[2]
  else
    pose.ringL = self._ringDst[1]
    pose.ringR = self._ringDst[2]
  end

  -- 注视平滑 + 常驻眼神微漂移
  local dtg = self._dt
  local kk = 1 - exp(-5.66 * dtg)
  local gaze = self._gaze
  local gx = def.gaze and gaze.tx or 0
  local gy = def.gaze and gaze.ty or 0
  gaze.x = gaze.x + (gx - gaze.x) * kk
  gaze.y = gaze.y + (gy - gaze.y) * kk
  left.lookX = left.lookX + gaze.x
  right.lookX = right.lookX + gaze.x
  left.lookY = left.lookY + gaze.y
  right.lookY = right.lookY + gaze.y

  if def.gaze then
    local w = now / 1000
    left.lookX = left.lookX + 1.4 * sin(0.42 * w) + 0.5 * sin(1.0 * w)
    right.lookX = right.lookX + 1.4 * sin(0.42 * w + 1) + 0.5 * sin(1.0 * w + 2)
    left.lookY = left.lookY + 0.9 * sin(0.58 * w)
    right.lookY = right.lookY + 0.9 * sin(0.58 * w + 1)
  end

  -- 开合度 = 配置基础值 × 眨眼弹簧（弹簧可过冲到 1.08）
  local open_s = clamp(open.x, 0.02, 1.5)
  left.open = clamp(left.open, 0, 1.3) * open_s
  right.open = clamp(right.open, 0, 1.3) * open_s
  if left.scaleX < 0.05 then left.scaleX = 0.05 end
  if left.scaleY < 0.05 then left.scaleY = 0.05 end
  if right.scaleX < 0.05 then right.scaleX = 0.05 end
  if right.scaleY < 0.05 then right.scaleY = 0.05 end

  -- 情绪切换过渡
  local tt = now - self._transStart
  if self._transDur > 0 and tt < self._transDur and self._hasPrev then
    lerp_pose_into(pose, self._prev, pose, ease_in_out_cubic(tt / self._transDur))
  end

  return pose
end

return Engine
